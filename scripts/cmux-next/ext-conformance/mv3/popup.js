// Popup checks: it opened, it has its content size, messaging to the worker
// works, and user-gesture APIs (permission prompt, side panel) from clicks.
"use strict";
(async () => {
  const { test, report, expect } = CXT;
  const stored = await chrome.storage.session.get("openedBy");
  await chrome.storage.session.remove("openedBy");
  const name = stored.openedBy === "api" ? "openPopup_loaded" : "popup_click";
  // Not requestAnimationFrame: it never fires while the popup window is occluded.
  await new Promise((r) => setTimeout(r, 100));
  const size = { width: innerWidth, height: innerHeight };
  const sized = size.width >= 300 && size.height >= 180 && size.width <= 800 && size.height <= 600;
  await report("action", name, "pass", size);
  await report("action", "popup_size", sized ? "pass" : "fail", size);
  await test("runtime", "sendMessage_popup_to_sw", async () => {
    const reply = await chrome.runtime.sendMessage({ type: "popup-hello" });
    expect(reply && reply.from === "sw", JSON.stringify(reply));
    return reply;
  });
  await test("runtime", "connect_port", () => new Promise((resolve, reject) => {
    const port = chrome.runtime.connect({ name: "cxt" });
    port.onMessage.addListener((m) => { port.disconnect(); m.pong === 7 ? resolve(m) : reject(new Error(JSON.stringify(m))); });
    port.postMessage({ ping: 7 });
  }));
  await test("tabs", "query_from_popup", async () => {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    expect(tab, "no active tab in the popup's window");
    return tab.url;
  });
})();

document.getElementById("perm").addEventListener("click", async () => {
  await CXT.report("permissions", "request_prompt", "pending", "prompt requested");
  try {
    const granted = await chrome.permissions.request({ permissions: ["readingList"] });
    await CXT.report("permissions", "request_prompt", granted ? "pass" : "fail", granted ? "granted" : "denied or no prompt");
  } catch (error) {
    await CXT.report("permissions", "request_prompt", "fail", error.message);
  }
});
document.getElementById("side").addEventListener("click", async () => {
  try {
    const win = await chrome.windows.getCurrent();
    await chrome.sidePanel.open({ windowId: win.id });
    await CXT.report("sidePanel", "open", "pass", "resolved; sidepanel.html reports when it loads");
  } catch (error) {
    await CXT.report("sidePanel", "open", "fail", error.message);
  }
});
document.getElementById("close").addEventListener("click", () => window.close());
