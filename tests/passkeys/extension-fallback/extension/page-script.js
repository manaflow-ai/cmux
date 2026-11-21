// MAIN world, as Bitwarden's content/fido2-page-script.js: a modal navigator.credentials.get goes to the
// extension first; when the extension asks for fallback (its popout window closed), wait for the page to have
// focus, then call the browser's own get.
(() => {
  const nativeGet = navigator.credentials.get.bind(navigator.credentials);
  const log = (event) => {
    (window.__probe ||= []).push({ t: Math.round(performance.now()), event });
  };
  window.addEventListener("focus", () => log("window focus"));
  window.addEventListener("message", (event) => {
    if (event.source === window && event.data?.probeEvent) log(`worker: ${event.data.probeEvent}`);
  });
  window.addEventListener("blur", () => log("window blur"));
  let next = 0;
  const ask = (data) => new Promise((resolve) => {
    const id = `probe-${++next}`;
    const listener = (event) => {
      if (event.source !== window || event.data?.probeReply !== id) return;
      window.removeEventListener("message", listener);
      resolve(event.data.result);
    };
    window.addEventListener("message", listener);
    window.postMessage({ probeRequest: id, data }, "*");
  });
  // Bitwarden's waitForFocus: top.document.hasFocus(), else the next 'focus' event on top, with a timeout.
  const waitForFocus = (timeout) => new Promise((resolve, reject) => {
    if (window.top.document.hasFocus()) return resolve("had focus");
    const timer = setTimeout(() => reject(new DOMException("no focus came back", "AbortError")), timeout);
    window.top.addEventListener("focus", () => { clearTimeout(timer); resolve("focus event"); }, { once: true });
  });
  navigator.credentials.get = async (options) => {
    if (!options || !("publicKey" in options) || options.mediation === "conditional") return nativeGet(options);
    log("get: to the extension");
    const result = await ask({ type: "get" });
    log(`extension answered ${JSON.stringify(result)}`);
    if (!result?.fallbackRequested) throw new DOMException("the extension did not fall back", "NotAllowedError");
    const how = await waitForFocus(window.__probeFocusTimeout || 20000);
    log(`fallback: ${how}; hasFocus=${document.hasFocus()}`);
    return nativeGet(options);
  };
})();
