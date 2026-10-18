// Firefox claude.ai bridge — replaces Chrome's externally_connectable.
// Listens for window.postMessage from the page, forwards to the extension
// background via chrome.runtime.sendMessage, and sends responses back.
// Also injects a small page-context script that exposes the messaging API.

(function () {
  'use strict';

  // Mirror onMessageExternal in the service worker: only https://claude.ai
  // is trusted (the manifest also matches *.claude.ai subdomains).
  if (location.origin !== 'https://claude.ai') return;

  var EXTENSION_ID = chrome.runtime.id;
  var MSG_PREFIX = '__claude_firefox_ext_';
  var MSG_REQUEST = MSG_PREFIX + 'request';
  var MSG_RESPONSE = MSG_PREFIX + 'response';
  var MSG_EVENT = MSG_PREFIX + 'event';

  // ------------------------------------------------------------------
  // 1. Inject page-context script that the claude.ai page can call
  // ------------------------------------------------------------------
  function injectPageScript() {
    var code = [
      '(function(){',
      '  "use strict";',
      '  var MSG_REQUEST = "' + MSG_REQUEST + '";',
      '  var MSG_RESPONSE = "' + MSG_RESPONSE + '";',
      '  var MSG_EVENT = "' + MSG_EVENT + '";',
      '  var pending = {};',
      '  var reqId = 0;',
      '',
      '  function sendMessage(message) {',
      '    return new Promise(function(resolve, reject) {',
      '      var id = ++reqId;',
      '      pending[id] = { resolve: resolve, reject: reject };',
      '      window.postMessage({',
      '        type: MSG_REQUEST,',
      '        id: id,',
      '        payload: message',
      '      }, "*");',
      '      setTimeout(function() {',
      '        if (pending[id]) {',
      '          pending[id].reject(new Error("Extension message timeout"));',
      '          delete pending[id];',
      '        }',
      '      }, 30000);',
      '    });',
      '  }',
      '',
      '  window.addEventListener("message", function(ev) {',
      '    if (!ev.data || ev.source !== window) return;',
      '    if (ev.data.type === MSG_RESPONSE && pending[ev.data.id]) {',
      '      if (ev.data.error) {',
      '        pending[ev.data.id].reject(new Error(ev.data.error));',
      '      } else {',
      '        pending[ev.data.id].resolve(ev.data.payload);',
      '      }',
      '      delete pending[ev.data.id];',
      '    }',
      '  });',
      '',
      '  window.__claudeFirefoxExtension = {',
      '    sendMessage: sendMessage,',
      '    extensionId: "' + EXTENSION_ID + '"',
      '  };',
      '',
      '  window.dispatchEvent(new CustomEvent("claude-extension-available", {',
      '    detail: { extensionId: "' + EXTENSION_ID + '" }',
      '  }));',
      '})();',
    ].join('\n');

    var script = document.createElement('script');
    script.textContent = code;
    (document.head || document.documentElement).appendChild(script);
    script.remove();
  }

  // ------------------------------------------------------------------
  // 2. Listen for messages from the page and forward to background
  // ------------------------------------------------------------------
  // Only the message types the service worker's onMessageExternal accepts
  // (oauth_redirect, ping, onboarding_task) are handled, rebuilt from named
  // fields so the page cannot reach any other internal handler.
  window.addEventListener('message', function (ev) {
    if (!ev.data || ev.source !== window || ev.data.type !== MSG_REQUEST) {
      return;
    }

    var requestId = ev.data.id;
    var payload = ev.data.payload || {};

    function respond(response, error) {
      window.postMessage({
        type: MSG_RESPONSE,
        id: requestId,
        payload: error ? undefined : response,
        error: error || undefined,
      }, '*');
    }

    if (payload.type === 'ping') {
      respond({ success: true, exists: true });
      return;
    }

    var bgMessage;
    if (payload.type === 'oauth_redirect') {
      // Handled by the patched onMessage listener in the service worker.
      bgMessage = { type: 'EXTERNAL_oauth_redirect', redirect_uri: payload.redirect_uri };
    } else if (payload.type === 'onboarding_task') {
      // onMessageExternal relays this to the side panel the same way.
      bgMessage = { type: 'POPULATE_INPUT_TEXT', prompt: payload.payload && payload.payload.prompt };
    } else {
      respond(undefined, 'Unsupported message type');
      return;
    }

    chrome.runtime.sendMessage(bgMessage, function (response) {
      var error = chrome.runtime.lastError;
      if (payload.type === 'onboarding_task') {
        var errMsg = error ? error.message : undefined;
        respond({
          success: !errMsg && !!(response && response.success),
          error: errMsg || (response && response.success ? undefined : 'side panel not ready'),
        });
        return;
      }
      respond(response, error ? error.message : undefined);
    });
  });

  // ------------------------------------------------------------------
  // 3. Forward events from background to the page
  // ------------------------------------------------------------------
  chrome.runtime.onMessage.addListener(function (message, _sender, sendResponse) {
    if (message && message._target === 'claude_ai_page') {
      window.postMessage({
        type: MSG_EVENT,
        payload: message,
      }, '*');
      sendResponse({ received: true });
      return false;
    }
    return false;
  });

  // ------------------------------------------------------------------
  // 4. Inject the page script once DOM is ready
  // ------------------------------------------------------------------
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectPageScript);
  } else {
    injectPageScript();
  }
})();
