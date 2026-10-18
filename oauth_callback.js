(function () {
  'use strict';

  var statusEl = document.getElementById('status');

  function showSuccess() {
    statusEl.className = 'card success';
    statusEl.innerHTML =
      '<div class="icon">&#10003;</div>' +
      '<h1>Authentication successful</h1>' +
      '<p>You can close this tab and return to the extension.</p>';
  }

  function showError(msg) {
    statusEl.className = 'card error';
    statusEl.innerHTML =
      '<div class="icon">&#10007;</div>' +
      '<h1>Authentication failed</h1>' +
      '<p></p>';
    // msg can come from the URL (error_description), so never parse it as HTML
    statusEl.querySelector('p').textContent = msg || 'An unknown error occurred.';
  }

  try {
    var params = new URLSearchParams(window.location.search);
    var code = params.get('code');
    var state = params.get('state');
    var error = params.get('error');
    var errorDesc = params.get('error_description');

    if (error) {
      showError(errorDesc || error);
      return;
    }

    if (!code) {
      showError('No authorization code received.');
      return;
    }

    var message = {
      type: 'EXTERNAL_oauth_redirect',
      // The service worker parses code/state out of redirect_uri
      redirect_uri: window.location.href,
      code: code,
      state: state || '',
    };

    if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
      chrome.runtime.sendMessage(message, function (response) {
        var lastErr = chrome.runtime.lastError;
        if (lastErr) {
          showError('Could not reach extension: ' + lastErr.message);
        } else if (response && response.success) {
          showSuccess();
        } else {
          showError((response && response.error) || 'Unexpected response from extension.');
        }
      });
    } else {
      showError('Extension API not available. Please re-open this page from the extension.');
    }
  } catch (e) {
    showError('Unexpected error: ' + e.message);
  }
})();
