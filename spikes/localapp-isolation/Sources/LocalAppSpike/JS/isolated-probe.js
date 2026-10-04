// Run in the isolated world after the page spy patched the page world: what the isolated world
// sees of those patches, and what it leaves on the shared DOM.
(() => {
  const native = (fn) => typeof fn === "function" && Function.prototype.toString.call(fn).includes("[native code]");
  globalThis.__isoGlobal = "iso-secret-global";
  document.__isoExpando = "iso-secret-expando";
  document.documentElement.setAttribute("data-iso", "shared-dom-attribute");
  document.dispatchEvent(new CustomEvent("spike-detail", { detail: { secret: "iso-secret-detail" } }));
  return JSON.stringify({
    wsSendNative: native(WebSocket.prototype.send),
    wsCtorNative: native(WebSocket),
    jsonNative: native(JSON.stringify),
    portNative: native(MessagePort.prototype.postMessage),
    protoSetter: Object.getOwnPropertyDescriptor(Object.prototype, "localAppToken") !== undefined,
    spyVisible: typeof window.__spySeen,
    pageStartVisible: typeof window.startDirect,
  });
})()
