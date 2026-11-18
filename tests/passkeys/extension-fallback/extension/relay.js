// Isolated world, as Bitwarden's fido2-content-script.js: carries page requests to the service worker.
window.addEventListener("message", (event) => {
  if (event.source !== window || !event.data?.probeRequest) return;
  const id = event.data.probeRequest;
  chrome.runtime.sendMessage({ probe: event.data.data }, (result) => {
    window.postMessage({ probeReply: id, result: result ?? { error: String(chrome.runtime.lastError?.message) } }, "*");
  });
});
chrome.runtime.onMessage.addListener((message) => {
  if (message?.probeEvent) window.postMessage({ probeEvent: message.probeEvent }, "*");
});
