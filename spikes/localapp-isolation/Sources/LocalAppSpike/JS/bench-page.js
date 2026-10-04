// The page world of the bench. One transport per mode; every frame is parsed as direct.ts does,
// and a stream frame is acknowledged at once through the same transport, so the server measures
// the latency of the whole path.
(() => {
  let transport = null;
  let ready = null;
  const onFrame = (text) => {
    const message = JSON.parse(text);
    const seq = message.params && message.params.s;
    if (seq !== undefined) transport.send('{"a":' + seq + "}");
    else if (message.id === 0 && ready) { const done = ready; ready = null; done(true); }
  };
  const initialize = (mode, token) => {
    const params = { protocolVersion: 1, clientInfo: { name: mode, version: "1" }, clientCapabilities: {} };
    if (token) params._meta = { acpmux: { localAppToken: token } };
    return JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params });
  };
  // Today: the page world owns the socket and the token.
  window.startDirect = (url, token) => new Promise((resolve, reject) => {
    ready = resolve;
    const ws = new WebSocket(url);
    transport = { send: (text) => ws.send(text) };
    ws.onopen = () => ws.send(initialize("direct", token));
    ws.onerror = () => reject(new Error("socket error"));
    ws.onmessage = (event) => onFrame(event.data);
  });
  // Design A: the page waits for the isolated world's port.
  window.startIsolated = () => new Promise((resolve) => {
    ready = resolve;
    window.addEventListener("message", function take(event) {
      if (event.source !== window || !event.data || event.data.cmuxAcpmuxPort !== 1 || !event.ports[0]) return;
      window.removeEventListener("message", take);
      const port = event.ports[0];
      transport = { send: (text) => port.postMessage(text) };
      port.onmessage = (e) => { if (typeof e.data === "string") onFrame(e.data); };
      port.postMessage(initialize("isolated"));
    });
  });
  // Design B: frames come from the host (`__relayRecv`) and go to it (`relaySend`).
  window.startRelay = (mode, send) => new Promise((resolve) => {
    ready = resolve;
    transport = { send };
    window.__relayRecv = (frames) => { for (let i = 0; i < frames.length; i++) onFrame(frames[i]); };
    send(initialize(mode));
  });
  window.__probe = () => JSON.stringify({
    connectVisible: typeof window.__acpmuxConnect,
    isoGlobal: typeof window.__isoGlobal,
    isoExpando: typeof document.__isoExpando,
    isoAttribute: document.documentElement.getAttribute("data-iso"),
    detail: window.__spyDetail === undefined ? "none" : window.__spyDetail,
    handlers: window.webkit && window.webkit.messageHandlers ? Object.keys(window.webkit.messageHandlers) : [],
  });
})();
