// The attacker: a script in the PAGE world that runs before anything else and patches every place
// a frame or the token could pass. Everything it sees goes to window.__spySeen (strings). The test
// then asks whether any of it holds the token.
(() => {
  const seen = (window.__spySeen = []);
  const stringify = JSON.stringify;
  let inside = false;
  const note = (where, value) => {
    if (inside) return;
    inside = true;
    try { seen.push(where + ":" + (typeof value === "string" ? value : stringify(value))); } catch (_) { seen.push(where + ":?"); }
    inside = false;
  };
  const wrap = (owner, name, where) => {
    const original = owner[name];
    if (typeof original !== "function") return;
    owner[name] = function (...args) { note(where, args); return original.apply(this, args); };
  };
  wrap(WebSocket.prototype, "send", "ws.send");
  const NativeWebSocket = window.WebSocket;
  window.WebSocket = function (...args) { note("ws.new", args); return new NativeWebSocket(...args); };
  window.WebSocket.prototype = NativeWebSocket.prototype;
  wrap(JSON, "stringify", "json.stringify");
  wrap(JSON, "parse", "json.parse");
  wrap(MessagePort.prototype, "postMessage", "port.postMessage");
  wrap(window, "postMessage", "window.postMessage");
  wrap(window, "fetch", "fetch");
  wrap(XMLHttpRequest.prototype, "send", "xhr.send");
  const descriptor = Object.getOwnPropertyDescriptor(MessageEvent.prototype, "data");
  if (descriptor && descriptor.get) {
    Object.defineProperty(MessageEvent.prototype, "data", {
      configurable: true,
      get() { const value = descriptor.get.call(this); note("event.data", value); return value; },
    });
  }
  for (const key of ["localAppToken", "acpmux", "_meta", "token"]) {
    Object.defineProperty(Object.prototype, key, {
      configurable: true,
      set(value) { note("proto." + key, value); Object.defineProperty(this, key, { value, writable: true, enumerable: true, configurable: true }); },
    });
  }
  window.addEventListener("message", (event) => note("message", event.data), true);
  document.addEventListener("spike-detail", (event) => { window.__spyDetail = event.detail === null ? "null" : typeof event.detail === "object" ? JSON.stringify(event.detail) : String(event.detail); }, true);
})();
