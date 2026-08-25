/* chatmux preview connector: pairs the vendored chobitsu bundle above with
 * the relay preview proxy (pinned contract in chatmux pane-primitives):
 * CDP frames ride WS /__chatmux__/page; the proxy pipes them to the
 * DevTools frontend on /__chatmux__/devtools and tees console/network
 * events into the preview_console_tail ring. Close code 4001 means a newer
 * page connection replaced this one — stay quiet, do not reconnect. */
(function () {
  'use strict';
  if (window.__chatmuxPreviewConnector) return;
  window.__chatmuxPreviewConnector = true;
  var chobitsu = window.chobitsu;
  if (!chobitsu) return;
  var scheme = location.protocol === 'https:' ? 'wss://' : 'ws://';
  var endpoint = scheme + location.host + '/__chatmux__/page';
  var retryMs = 1000;
  function connect() {
    var socket;
    try {
      socket = new WebSocket(endpoint);
    } catch (error) {
      return;
    }
    socket.onopen = function () {
      retryMs = 1000;
    };
    socket.onmessage = function (event) {
      chobitsu.dispatch(event.data);
    };
    socket.onclose = function (event) {
      chobitsu.setOnMessage(function () {});
      if (event && event.code === 4001) return; // replaced: newest page wins
      setTimeout(connect, retryMs);
      retryMs = Math.min(retryMs * 2, 15000);
    };
    chobitsu.setOnMessage(function (message) {
      if (socket.readyState === 1) socket.send(message);
    });
  }
  connect();
})();
