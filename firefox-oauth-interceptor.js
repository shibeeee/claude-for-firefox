// Firefox OAuth interceptor — redirects navigations targeting
// chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/* to the equivalent
// moz-extension:// URL so OAuth callbacks and deep-links work.

(function () {
  'use strict';

  var CHROME_EXT_ORIGIN = 'chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn';
  var MOZ_EXT_ORIGIN = (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.getURL)
    ? chrome.runtime.getURL('').replace(/\/$/, '')
    : '';

  if (!MOZ_EXT_ORIGIN) {
    console.warn('[firefox-oauth-interceptor] Cannot determine own extension origin');
    return;
  }

  if (typeof chrome === 'undefined' || !chrome.webNavigation ||
      !chrome.webNavigation.onBeforeNavigate) {
    // webNavigation API unavailable — nothing to intercept
    return;
  }

  function redirect(tabId, url) {
    var suffix = url.slice(CHROME_EXT_ORIGIN.length);
    var redirectUrl = MOZ_EXT_ORIGIN + suffix;

    chrome.tabs.update(tabId, { url: redirectUrl }).catch(function (err) {
      console.warn('[firefox-oauth-interceptor] Redirect failed:', err.message);
    });
  }

  chrome.webNavigation.onBeforeNavigate.addListener(function (details) {
    if (!details || !details.url) return;

    if (details.url.indexOf(CHROME_EXT_ORIGIN) !== 0) return;

    redirect(details.tabId, details.url);
  });

  // An HTTP redirect (3xx) to chrome-extension:// never reaches
  // onBeforeNavigate: Firefox drops it as an unknown protocol. Catch it from
  // the redirect response instead.
  if (chrome.webRequest && chrome.webRequest.onBeforeRedirect) {
    chrome.webRequest.onBeforeRedirect.addListener(function (details) {
      if (!details.redirectUrl || details.redirectUrl.indexOf(CHROME_EXT_ORIGIN) !== 0) return;
      redirect(details.tabId, details.redirectUrl);
    }, { urls: ['<all_urls>'], types: ['main_frame'] });
  }
})();
