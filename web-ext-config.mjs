// Settings for `web-ext build` and `web-ext lint`, run from the repo root.
// web-ext already skips dotfiles (.git etc.), node_modules and *.zip/*.xpi.
export default {
  ignoreFiles: [
    'install.sh',
    'install.ps1',
    'README.md',
    'web-ext-config.mjs',
    // Never ship OAuth tokens in a package.
    'firefox-injected-tokens.json',
  ],
  build: {
    filename: 'claude-for-firefox-unofficial-{version}.zip',
  },
};
