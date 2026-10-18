#Requires -Version 5.1
<#
.SYNOPSIS
    Claude for Firefox — Windows Installer
.DESCRIPTION
    Installs the Claude browser extension for Firefox on Windows.
    Sets up native messaging hosts, injects OAuth tokens from Claude Code,
    and creates launcher scripts.
.PARAMETER Uninstall
    Remove all installed components.
.EXAMPLE
    .\install.ps1
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────
$ExtId             = 'claude-for-firefox@shibeeee.github.io'
$ChromeExtId       = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'
$NmhNameBrowser    = 'com.anthropic.claude_browser_extension'
$NmhNameCode       = 'com.anthropic.claude_code_browser_extension'
$InstallDir        = Join-Path $env:USERPROFILE '.claude\firefox'
$ExtDir            = Join-Path $InstallDir 'extension'
$NmhDir            = Join-Path $InstallDir 'nmh'

# ── Helpers ─────────────────────────────────────────────────────────────────
function Write-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Banner { param([string]$Msg) Write-Host "`n── $Msg ──`n" -ForegroundColor White }

function Exit-Fatal {
    param([string]$Msg)
    Write-Err $Msg
    exit 1
}

# Create an empty file, restrict its ACL to the current user only (inheritance
# removed), then write the content, so secrets are never readable by others.
function Set-PrivateContent {
    param([string]$Path, [string]$Value)
    New-Item -ItemType File -Path $Path -Force | Out-Null
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}

# ── Find Claude Code ────────────────────────────────────────────────────────
function Find-Claude {
    # 1. Env var override
    if ($env:CLAUDE_CODE_BIN -and (Test-Path $env:CLAUDE_CODE_BIN)) {
        Write-Info "Using CLAUDE_CODE_BIN override: $($env:CLAUDE_CODE_BIN)"
        return $env:CLAUDE_CODE_BIN
    }

    # 2. PATH
    $inPath = Get-Command claude -ErrorAction SilentlyContinue
    if ($inPath) {
        Write-Info "Found claude in PATH: $($inPath.Source)"
        return $inPath.Source
    }
    $inPathExe = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($inPathExe) {
        Write-Info "Found claude.exe in PATH: $($inPathExe.Source)"
        return $inPathExe.Source
    }

    # 3. Standard install locations
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\claude-code\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude-code\resources\claude.exe')
    )

    # Versioned installs
    $versionsDir = Join-Path $env:LOCALAPPDATA 'claude\versions'
    if (Test-Path $versionsDir) {
        Get-ChildItem $versionsDir -Directory | Sort-Object Name -Descending | ForEach-Object {
            $candidates += Join-Path $_.FullName 'claude.exe'
        }
    }

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Info "Found Claude Code at: $c"
            return $c
        }
    }

    Exit-Fatal "Claude Code not found. Install it first or set CLAUDE_CODE_BIN env var."
}

# ── Find Firefox ────────────────────────────────────────────────────────────
function Find-Firefox {
    # Standard paths
    $candidates = @(
        "${env:ProgramFiles}\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Info "Found Firefox at: $c"
            return $c
        }
    }

    # Registry
    try {
        $regPaths = @(
            'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
            'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox'
        )
        foreach ($rp in $regPaths) {
            if (Test-Path $rp) {
                $ver = (Get-ChildItem $rp | Sort-Object Name -Descending | Select-Object -First 1).Name
                $mainKey = Join-Path $rp "$ver\Main"
                if (Test-Path "Registry::$mainKey") {
                    $ffPath = (Get-ItemProperty "Registry::$mainKey" -ErrorAction SilentlyContinue).PathToExe
                    if ($ffPath -and (Test-Path $ffPath)) {
                        Write-Info "Found Firefox via registry: $ffPath"
                        return $ffPath
                    }
                }
            }
        }
    } catch {
        # Registry lookup failed, continue
    }

    # PATH
    $inPath = Get-Command firefox -ErrorAction SilentlyContinue
    if ($inPath) {
        Write-Info "Found Firefox in PATH: $($inPath.Source)"
        return $inPath.Source
    }
    $inPathExe = Get-Command firefox.exe -ErrorAction SilentlyContinue
    if ($inPathExe) {
        Write-Info "Found Firefox in PATH: $($inPathExe.Source)"
        return $inPathExe.Source
    }

    Exit-Fatal "Firefox not found. Install Firefox first."
}

# ── Inject OAuth Tokens ────────────────────────────────────────────────────
function Inject-Tokens {
    Write-Banner 'Injecting OAuth Tokens'

    $tokenFile = Join-Path $ExtDir 'firefox-injected-tokens.json'
    $rawCreds = $null

    # Try CredentialManager module first
    try {
        if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
            Import-Module CredentialManager -ErrorAction Stop
            $cred = Get-StoredCredential -Target 'Claude Code-credentials' -ErrorAction SilentlyContinue
            if ($cred) {
                $rawCreds = $cred.GetNetworkCredential().Password
            }
        }
    } catch {
        # Module not available or failed
    }

    # Fallback: cmdkey + PowerShell credential vault
    if (-not $rawCreds) {
        try {
            # Try reading via vaultcmd / direct API
            Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
            $cmdkeyOutput = & cmdkey /list 2>$null | Out-String
            if ($cmdkeyOutput -match 'Claude Code-credentials') {
                Write-Info "Found Claude Code credentials in Credential Manager."
                # cmdkey cannot read passwords directly; try .NET CredentialManager
                try {
                    $code = @'
using System;
using System.Runtime.InteropServices;
public class CredHelper {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr buffer);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type;
        public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize;
        public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    public static string Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        try {
            var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            if (cred.CredentialBlobSize > 0)
                return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
            return null;
        } finally { CredFree(ptr); }
    }
}
'@
                    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
                    $rawCreds = [CredHelper]::Read('Claude Code-credentials')
                } catch {
                    Write-Warn "Could not read credential blob via .NET interop: $_"
                }
            }
        } catch {
            # cmdkey approach failed
        }
    }

    # Claude Code can also keep credentials in a plaintext file (its Credential
    # Manager backend falls back to it), so use that when the Credential
    # Manager entry is missing or has no usable token.
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $credsFile = Join-Path $configDir '.credentials.json'
    $hasToken = $false
    try { $hasToken = [bool](($rawCreds | ConvertFrom-Json).claudeAiOauth.accessToken) } catch {}
    if (-not $hasToken -and (Test-Path -LiteralPath $credsFile)) {
        $rawCreds = Get-Content -LiteralPath $credsFile -Raw
    }

    if (-not $rawCreds) {
        Write-Warn "Could not read Claude Code credentials from Windows Credential Manager or $credsFile."
        Write-Warn "Run 'claude' at least once to log in, then re-run this installer."
        return
    }

    try {
        $parsed = $rawCreds | ConvertFrom-Json
        $oauth = $parsed.claudeAiOauth

        if (-not $oauth.accessToken) {
            Write-Warn "No access token found in credentials. Run refresh-tokens after login."
            return
        }

        $tokenObj = @{
            accessToken  = $oauth.accessToken
            refreshToken = $oauth.refreshToken
            expiresAt    = $oauth.expiresAt
        }
        Set-PrivateContent -Path $tokenFile -Value ($tokenObj | ConvertTo-Json)
        Write-Ok "OAuth tokens injected."
    } catch {
        Write-Warn "Failed to parse OAuth tokens: $_"
    }
}

# ── Create Native Host Wrapper ──────────────────────────────────────────────
function Create-NmhWrapper {
    Write-Banner 'Creating Native Host Wrapper'

    $wrapperPath = Join-Path $InstallDir 'firefox-native-host.bat'
    $wrapperContent = @'
@echo off
REM Native messaging host wrapper for Claude for Firefox.
REM Delegates to Claude Code's built-in native messaging handler.

if defined CLAUDE_CODE_BIN (
    if exist "%CLAUDE_CODE_BIN%" (
        "%CLAUDE_CODE_BIN%" --chrome-native-host
        exit /b %ERRORLEVEL%
    )
)

where claude.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    claude.exe --chrome-native-host
    exit /b %ERRORLEVEL%
)

set "CANDIDATE=%LOCALAPPDATA%\Programs\claude-code\claude.exe"
if exist "%CANDIDATE%" (
    "%CANDIDATE%" --chrome-native-host
    exit /b %ERRORLEVEL%
)

echo {"error":"claude binary not found"} >&2
exit /b 1
'@
    Set-Content -Path $wrapperPath -Value $wrapperContent -Encoding ASCII
    Write-Ok "Native host wrapper created at $wrapperPath"
    return $wrapperPath
}

# ── Install NMH Manifests ──────────────────────────────────────────────────
function Install-NmhManifests {
    param([string]$WrapperPath)

    Write-Banner 'Installing Native Messaging Host Manifests'

    New-Item -ItemType Directory -Force -Path $NmhDir | Out-Null

    foreach ($nmhName in @($NmhNameBrowser, $NmhNameCode)) {
        $manifestPath = Join-Path $NmhDir "$nmhName.json"
        $manifest = @{
            name               = $nmhName
            description        = 'Claude native messaging host for Firefox'
            path               = $WrapperPath
            type               = 'stdio'
            allowed_extensions = @($ExtId)
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Ok "NMH manifest written: $manifestPath"

        # Create registry key pointing to the manifest
        $regPath = "HKCU:\Software\Mozilla\NativeMessagingHosts\$nmhName"
        New-Item -Path $regPath -Force | Out-Null
        Set-ItemProperty -Path $regPath -Name '(Default)' -Value $manifestPath
        Write-Ok "Registry key set: $regPath"
    }
}

# ── Create Launcher Scripts ────────────────────────────────────────────────
function Create-Launchers {
    param([string]$FirefoxPath)

    Write-Banner 'Creating Launcher Scripts'

    # .bat launcher
    $batPath = Join-Path $InstallDir 'launch.bat'
    $batContent = @"
@echo off
REM Launch Firefox with Claude extension, in a dedicated persistent profile.
set "EXT_DIR=%USERPROFILE%\.claude\firefox\extension"
set "PROFILE_DIR=%USERPROFILE%\.claude\firefox\profile"
if not exist "%EXT_DIR%" (
    echo Error: Extension not installed at %EXT_DIR%. Run install.ps1 first. >&2
    exit /b 1
)
if not exist "%PROFILE_DIR%" mkdir "%PROFILE_DIR%"
REM Temporary add-ons are uninstalled on exit; keep their storage and UUID.
if not exist "%PROFILE_DIR%\user.js" (
    echo user_pref("extensions.webextensions.keepStorageOnUninstall", true^);>  "%PROFILE_DIR%\user.js"
    echo user_pref("extensions.webextensions.keepUuidOnUninstall", true^);>> "%PROFILE_DIR%\user.js"
)
where web-ext >nul 2>&1
if errorlevel 1 goto manual
echo Launching Firefox with Claude extension via web-ext...
call web-ext run --source-dir "%EXT_DIR%" --firefox "$FirefoxPath" --firefox-profile "%PROFILE_DIR%" --keep-profile-changes
exit /b
:manual
echo web-ext not found (install with: npm install -g web-ext).
echo Opening Firefox with the Claude profile. Load the extension manually:
echo   1. In about:debugging#/runtime/this-firefox, click 'Load Temporary Add-on...'
echo   2. Select %EXT_DIR%\manifest.json
echo   Temporary add-ons must be reloaded each time Firefox starts.
start "" "$FirefoxPath" --new-instance --profile "%PROFILE_DIR%" "about:debugging#/runtime/this-firefox"
"@
    Set-Content -Path $batPath -Value $batContent -Encoding ASCII
    Write-Ok "Launcher .bat created at $batPath"

    # .ps1 launcher
    $ps1Path = Join-Path $InstallDir 'launch.ps1'
    $ps1Content = @"
# Launch Firefox with Claude extension, in a dedicated persistent profile.
`$extDir = Join-Path `$env:USERPROFILE '.claude\firefox\extension'
`$profileDir = Join-Path `$env:USERPROFILE '.claude\firefox\profile'
if (-not (Test-Path `$extDir)) {
    Write-Error "Extension not installed at `$extDir. Run install.ps1 first."
    exit 1
}
New-Item -ItemType Directory -Force -Path `$profileDir | Out-Null
# Temporary add-ons are uninstalled on exit; keep their storage and UUID.
`$userJs = Join-Path `$profileDir 'user.js'
if (-not (Test-Path `$userJs)) {
    Set-Content -Path `$userJs -Encoding ASCII -Value @(
        'user_pref("extensions.webextensions.keepStorageOnUninstall", true);',
        'user_pref("extensions.webextensions.keepUuidOnUninstall", true);'
    )
}
if (Get-Command web-ext -ErrorAction SilentlyContinue) {
    Write-Host 'Launching Firefox with Claude extension via web-ext...'
    & web-ext run --source-dir `$extDir --firefox '$FirefoxPath' --firefox-profile `$profileDir --keep-profile-changes
} else {
    Write-Host 'web-ext not found (install with: npm install -g web-ext).'
    Write-Host 'Opening Firefox with the Claude profile. Load the extension manually:'
    Write-Host "  1. In about:debugging#/runtime/this-firefox, click 'Load Temporary Add-on...'"
    Write-Host "  2. Select `$extDir\manifest.json"
    Write-Host '  Temporary add-ons must be reloaded each time Firefox starts.'
    Start-Process '$FirefoxPath' -ArgumentList @('--new-instance', '--profile', ('"' + `$profileDir + '"'), 'about:debugging#/runtime/this-firefox')
}
"@
    Set-Content -Path $ps1Path -Value $ps1Content -Encoding UTF8
    Write-Ok "Launcher .ps1 created at $ps1Path"

    # Token refresh script
    $refreshPath = Join-Path $InstallDir 'refresh-tokens.ps1'
    $refreshContent = @'
# Refresh OAuth tokens from Claude Code's Credential Manager into the Firefox extension.
$ErrorActionPreference = 'Stop'

$tokenFile = Join-Path $env:USERPROFILE '.claude\firefox\extension\firefox-injected-tokens.json'
$rawCreds = $null

# Try CredentialManager module
try {
    if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
        Import-Module CredentialManager
        $cred = Get-StoredCredential -Target 'Claude Code-credentials' -ErrorAction SilentlyContinue
        if ($cred) { $rawCreds = $cred.GetNetworkCredential().Password }
    }
} catch {}

# Fallback: .NET interop
if (-not $rawCreds) {
    try {
        $code = @"
using System; using System.Runtime.InteropServices;
public class CredHelper2 {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr buffer);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    public static string Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            if (c.CredentialBlobSize > 0) return Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2);
            return null;
        } finally { CredFree(ptr); }
    }
}
"@
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        $rawCreds = [CredHelper2]::Read('Claude Code-credentials')
    } catch {
        Write-Warning "Could not read Credential Manager: $_"
    }
}

# Claude Code can also keep credentials in a plaintext file (its Credential
# Manager backend falls back to it), so use that when the Credential Manager
# entry is missing or has no usable token.
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$credsFile = Join-Path $configDir '.credentials.json'
$hasToken = $false
try { $hasToken = [bool](($rawCreds | ConvertFrom-Json).claudeAiOauth.accessToken) } catch {}
if (-not $hasToken -and (Test-Path -LiteralPath $credsFile)) {
    $rawCreds = Get-Content -LiteralPath $credsFile -Raw
}

if (-not $rawCreds) {
    Write-Error "No Claude Code credentials found. Log in with 'claude' first."
    exit 1
}

$parsed = $rawCreds | ConvertFrom-Json
$oauth = $parsed.claudeAiOauth
if (-not $oauth.accessToken) {
    Write-Error "No access token in credentials."
    exit 1
}

$tokenDir = Split-Path $tokenFile
if (-not (Test-Path $tokenDir)) { New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null }

# Create the file, restrict its ACL to the current user only (inheritance
# removed), then write the tokens.
New-Item -ItemType File -Path $tokenFile -Force | Out-Null
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'FullControl', 'Allow')))
Set-Acl -LiteralPath $tokenFile -AclObject $acl

@{ accessToken = $oauth.accessToken; refreshToken = $oauth.refreshToken; expiresAt = $oauth.expiresAt } |
    ConvertTo-Json | Set-Content -LiteralPath $tokenFile -Encoding UTF8

Write-Host 'Tokens refreshed successfully.'
'@
    Set-Content -Path $refreshPath -Value $refreshContent -Encoding UTF8
    Write-Ok "Token refresh script created at $refreshPath"
}

# ── Uninstall ───────────────────────────────────────────────────────────────
function Do-Uninstall {
    Write-Banner 'Uninstalling Claude for Firefox'

    # Remove registry keys
    foreach ($nmhName in @($NmhNameBrowser, $NmhNameCode)) {
        $regPath = "HKCU:\Software\Mozilla\NativeMessagingHosts\$nmhName"
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Force -Recurse
            Write-Ok "Removed registry key: $regPath"
        }
    }

    # Clean up parent key if empty
    $parentKey = 'HKCU:\Software\Mozilla\NativeMessagingHosts'
    if ((Test-Path $parentKey) -and -not (Get-ChildItem $parentKey -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $parentKey -Force -ErrorAction SilentlyContinue
    }

    # Remove install directory
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Ok "Removed install directory: $InstallDir"
    }

    Write-Ok 'Uninstall complete.'
    exit 0
}

# ── Main ────────────────────────────────────────────────────────────────────
function Main {
    Write-Banner 'Claude for Firefox — Windows Installer'

    if ($Uninstall) {
        Do-Uninstall
        return
    }

    $claudeBin  = Find-Claude
    $firefoxBin = Find-Firefox

    # Create directories
    New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null
    Write-Ok "Extension directory: $ExtDir"

    # Copy extension files if available (same logic as install.sh)
    $scriptDir = $PSScriptRoot
    $srcExtDir = Join-Path $scriptDir 'extension'
    if (Test-Path (Join-Path $scriptDir 'manifest.json')) {
        # Installer is inside the extension directory: copy everything except install scripts
        $exclude = @('install.sh', 'install.ps1', '.git', '.DS_Store', 'node_modules', 'web-ext-artifacts', 'firefox-injected-tokens.json')
        Get-ChildItem -LiteralPath $scriptDir -Force |
            Where-Object { $exclude -notcontains $_.Name } |
            Copy-Item -Destination $ExtDir -Recurse -Force
        Write-Ok "Extension files copied to $ExtDir"
    } elseif (Test-Path $srcExtDir) {
        Copy-Item -Path "$srcExtDir\*" -Destination $ExtDir -Recurse -Force
        Write-Ok "Extension files copied to $ExtDir"
    } else {
        Write-Warn "No extension files found. Skipping extension file copy."
        Write-Warn "Place extension source files in $ExtDir manually."
    }

    $wrapperPath = Create-NmhWrapper
    Install-NmhManifests -WrapperPath $wrapperPath
    Inject-Tokens
    Create-Launchers -FirefoxPath $firefoxBin

    # ── Summary ─────────────────────────────────────────────────────────
    Write-Banner 'Installation Complete'

    Write-Host 'Claude for Firefox has been installed!' -ForegroundColor Green
    Write-Host ''
    Write-Host "Extension dir:  $ExtDir"
    Write-Host "NMH manifests:  $NmhDir"
    Write-Host "Claude binary:  $claudeBin"
    Write-Host "Firefox binary: $firefoxBin"
    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Yellow
    Write-Host "  1. Open Firefox and go to about:debugging#/runtime/this-firefox"
    Write-Host "  2. Click 'Load Temporary Add-on...'"
    Write-Host "  3. Navigate to $ExtDir and select manifest.json"
    Write-Host ''
    Write-Host '  Or use the launcher:'
    Write-Host "    $InstallDir\launch.bat"
    Write-Host "    $InstallDir\launch.ps1"
    Write-Host ''
    Write-Host '  To refresh tokens from Claude Code:'
    Write-Host "    $InstallDir\refresh-tokens.ps1"
    Write-Host ''
}

Main
