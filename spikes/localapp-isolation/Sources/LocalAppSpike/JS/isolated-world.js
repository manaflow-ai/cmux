// Design A: runs in a private world (WKContentWorld "cmux-acpmux" in WebKit, a CDP isolated
// world of the same name in Chromium/CEF). It owns the acpmux WebSocket and the LocalApp token.
// The page world gets one MessagePort that carries frames in and out; never the token, the
// endpoint, or the socket. The host calls __acpmuxConnect(url, token) in THIS world only, at every
// handshake and reconnect. The page cannot choose the endpoint, so it cannot point the token at
// another listener.
(() => {
  "use strict";
  const ownJSON = { parse: JSON.parse, stringify: JSON.stringify };
  let live = null;
  const close = () => {
    if (!live) return;
    try { live.ws.close(); } catch (_) {}
    try { live.port.close(); } catch (_) {}
    live = null;
  };
  globalThis.__acpmuxConnect = (url, token) => new Promise((resolve, reject) => {
    close();
    const ws = new WebSocket(url);
    const channel = new MessageChannel();
    const state = { ws, port: channel.port1, token, first: true };
    live = state;
    ws.onopen = () => {
      // The page gets its end of the channel only once the socket is open.
      window.postMessage({ cmuxAcpmuxPort: 1 }, "*", [channel.port2]);
      resolve(true);
    };
    ws.onerror = () => reject(new Error("acpmux socket error"));
    ws.onclose = (event) => { state.port.postMessage({ cmuxAcpmuxClose: event.code }); if (live === state) live = null; };
    ws.onmessage = (event) => state.port.postMessage(event.data);
    state.port.onmessage = (event) => {
      let text = event.data;
      if (typeof text !== "string") return;
      if (state.first) {
        // The page's first frame must be `initialize`; the token is added here, then forgotten.
        state.first = false;
        let message;
        try { message = ownJSON.parse(text); } catch (_) { ws.close(4400, "first frame"); return; }
        if (!message || message.method !== "initialize") { ws.close(4400, "first frame"); return; }
        const params = message.params && typeof message.params === "object" ? message.params : {};
        const meta = params._meta && typeof params._meta === "object" ? params._meta : {};
        const acpmux = meta.acpmux && typeof meta.acpmux === "object" ? meta.acpmux : {};
        message.params = { ...params, _meta: { ...meta, acpmux: { ...acpmux, localAppToken: state.token } } };
        state.token = null;
        text = ownJSON.stringify(message);
      }
      ws.send(text);
    };
  });
  globalThis.__acpmuxClose = close;
})();
