// Apply the saved theme before the app loads (moved out of the pages' inline
// <script>, which the extension CSP blocks).
try {
  const theme = localStorage.getItem("theme");
  if (theme) {
    document.documentElement.setAttribute("data-theme", theme);
  }
} catch (e) {}
