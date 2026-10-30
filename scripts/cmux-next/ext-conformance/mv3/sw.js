// MV3 conformance service worker. Listeners are registered synchronously at
// the top level (Chrome only delivers events to listeners added in the first
// turn), then the automatic phase runs every API test that needs no UI.
"use strict";
importScripts("harness.js", "sw-apis.js", "sw-tabs.js", "sw-network.js");

const { test, report, expect, event } = CXT;
const state = { installed: null, messages: [] };

chrome.runtime.onInstalled.addListener((details) => {
  state.installed = details;
  chrome.storage.session.set({ installedReason: details.reason });
  // Many extensions open a welcome tab here, often before the user has any
  // browser window. Chrome creates a window for it.
  // The runner reports it from the right profile (see startAutoPhase).
  state.onInstallTab = CXT.config()
    .then((cfg) => chrome.tabs.create({ url: cfg.collector + "/blank.html?welcome=1", active: false }))
    .then((tab) => ({ status: "pass", detail: "tab " + tab.id }), (error) => ({ status: "fail", detail: error.message }));
});

// UI-driven events: the runner triggers them, the listener reports.
chrome.commands.onCommand.addListener((command, tab) => {
  report("commands", "onCommand", command === "run-probe" ? "pass" : "fail", { command, tab: tab && tab.url });
});
chrome.contextMenus.onClicked.addListener((info) => {
  report("contextMenus", "onClicked", info.menuItemId === "cxt-page" ? "pass" : "fail", info.menuItemId);
});
chrome.action.onClicked.addListener(() => {
  // Only fires while the popup is cleared (setPopup test).
  report("action", "onClicked", "pass", "");
});
chrome.omnibox.onInputEntered.addListener((text) => {
  report("omnibox", "onInputEntered", "pass", text);
});
chrome.omnibox.onInputChanged.addListener((text, suggest) => {
  suggest([{ content: "cxt " + text, description: "cmux conformance" }]);
  report("omnibox", "onInputChanged", "pass", text);
});
chrome.alarms.onAlarm.addListener((alarm) => {
  state.messages.push({ alarm: alarm.name });
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  state.messages.push(message);
  if (message && message.type === "content-hello") {
    sendResponse({ ok: true, frameId: sender.frameId, tab: sender.tab && sender.tab.id });
    return false;
  }
  if (message && message.type === "popup-hello") {
    sendResponse({ ok: true, from: "sw" });
    return false;
  }
  if (message && message.type === "run-ui-phase") {
    runUIPhase(message.phase).then(() => sendResponse({ ok: true }));
    return true;
  }
  return false;
});

chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((message) => {
    if (message && message.ping) port.postMessage({ pong: message.ping });
  });
});

chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
  sendResponse({ ok: true });
});

async function runtimeTests() {
  await test("runtime", "id", () => {
    expect(/^[a-p]{32}$/.test(chrome.runtime.id), "bad id " + chrome.runtime.id);
    return chrome.runtime.id;
  });
  await test("runtime", "getURL", () => {
    const url = chrome.runtime.getURL("popup.html");
    expect(url === "chrome-extension://" + chrome.runtime.id + "/popup.html", url);
    return url;
  });
  await test("runtime", "getManifest", () => chrome.runtime.getManifest().name);
  await test("runtime", "getPlatformInfo", () => chrome.runtime.getPlatformInfo());
  await test("runtime", "onInstalled", async () => {
    for (let i = 0; i < 50 && !state.installed; i++) await new Promise((r) => setTimeout(r, 100));
    if (state.installed) return state.installed;
    const stored = await chrome.storage.session.get("installedReason");
    expect(stored.installedReason, "onInstalled never fired");
    return { reason: stored.installedReason, note: "fired before this worker instance" };
  });
  await test("runtime", "sendNativeMessage_refusal", async () => {
    try {
      const reply = await chrome.runtime.sendNativeMessage("com.cmux.conformance.missing", { ping: 1 });
      return { status: "fail", detail: "resolved: " + JSON.stringify(reply) };
    } catch (error) {
      const message = error.message || String(error);
      expect(/not found|forbidden|native messaging host/i.test(message), "unexpected error: " + message);
      return message;
    }
  });
  await test("runtime", "connectNative_refusal", async () => {
    const port = chrome.runtime.connectNative("com.cmux.conformance.missing");
    const [disconnected] = await event(port.onDisconnect, 5000, "onDisconnect");
    const message = chrome.runtime.lastError ? chrome.runtime.lastError.message : "";
    return message || "disconnected " + (disconnected && disconnected.name);
  });
  await test("runtime", "setUninstallURL", () => chrome.runtime.setUninstallURL("https://example.com/uninstalled"));
  await test("runtime", "getContexts", async () => {
    const contexts = await chrome.runtime.getContexts({});
    expect(contexts.some((c) => c.contextType === "BACKGROUND"), "no BACKGROUND context");
    return contexts.map((c) => c.contextType);
  }, { needs: "runtime.getContexts" });
  await test("runtime", "openOptionsPage", async () => {
    const created = event(chrome.tabs.onUpdated, 8000, "options tab",
      (id, info, tab) => info.status === "complete" && (tab.url || "").endsWith("/options.html"));
    await chrome.runtime.openOptionsPage();
    const [tabId] = await created;
    await chrome.tabs.remove(tabId);
    return "options tab " + tabId;
  });
}

async function latencyTests() {
  // 30 sequential API round trips through the browser UI thread. Chrome does
  // this in well under 0.5 s; a stalled or throttled message pump takes seconds.
  await test("runtime", "api_round_trip_latency", async () => {
    const started = performance.now();
    for (let i = 0; i < 30; i++) await chrome.storage.local.get("cxt_latency");
    const ms = Math.round(performance.now() - started);
    CXT.expect(ms < 5000, "30 round trips took " + ms + " ms");
    return ms + " ms for 30 round trips";
  }, { needs: "storage" });
}

async function storageTests() {
  for (const area of ["local", "sync", "session"]) {
    await test("storage", area, async () => {
      const key = "cxt_" + area;
      await chrome.storage[area].set({ [key]: { n: 42 } });
      const got = await chrome.storage[area].get(key);
      expect(got[key] && got[key].n === 42, "read back " + JSON.stringify(got));
      await chrome.storage[area].remove(key);
      const gone = await chrome.storage[area].get(key);
      expect(!(key in gone), "remove failed");
      return "ok";
    }, { needs: "storage." + area });
  }
  await test("storage", "managed", async () => {
    const got = await chrome.storage.managed.get(null);
    return "resolved " + JSON.stringify(got);
  }, { needs: "storage.managed" });
  await test("storage", "onChanged", async () => {
    const changed = event(chrome.storage.onChanged, 3000, "onChanged", (changes) => "cxt_changed" in changes);
    await chrome.storage.local.set({ cxt_changed: Date.now() });
    const [changes, area] = await changed;
    return area;
  });
  await test("storage", "session.setAccessLevel", () =>
    chrome.storage.session.setAccessLevel({ accessLevel: "TRUSTED_AND_UNTRUSTED_CONTEXTS" }));
  await test("storage", "getBytesInUse", () => chrome.storage.local.getBytesInUse(null));
}

async function runAutoPhase() {
  const cfg = await CXT.config();
  await CXT.post("/phase", { phase: "auto", state: "start" });
  await latencyTests();
  await runtimeTests();
  await storageTests();
  await apiTests(cfg);
  await tabTests(cfg);
  await networkTests(cfg);
  await CXT.post("/phase", { phase: "auto", state: "done" });
}

async function runUIPhase(phase) {
  if (phase === "openPopup") {
    await test("action", "openPopup", async () => {
      await chrome.storage.session.set({ openedBy: "api" });
      await chrome.action.openPopup();
      return "resolved (the popup reports openedBy=api when it loads)";
    });
  }
}

// The runner calls this through CDP on the worker of the cmux profile only:
// Chromium loads command-line extensions into every profile, including CEF's
// root profile, which has no cmux windows.
async function startAutoPhase() {
  const stored = await chrome.storage.session.get("autoPhase");
  if (stored.autoPhase) return "already ran";
  await chrome.storage.session.set({ autoPhase: Date.now() });
  if (state.onInstallTab) {
    const outcome = await state.onInstallTab;
    await report("tabs", "create_on_install", outcome.status, outcome.detail);
  }
  runAutoPhase().catch((error) => report("harness", "auto_phase", "fail", error.message || String(error)));
  return "started";
}
self.startAutoPhase = startAutoPhase;

// Launch 2 of the runner (UI checks only): the state the UI checks expect.
async function resetForUIPhase() {
  await chrome.storage.session.set({ autoPhase: Date.now() });
  await chrome.contextMenus.removeAll();
  await new Promise((resolve) => chrome.contextMenus.create({ id: "cxt-page", title: "cxt page item", contexts: ["page", "selection", "link"] }, resolve));
  await chrome.action.setBadgeText({ text: "OK" });
  await chrome.action.setTitle({ title: "cmux conformance ready" });
  return "ready";
}
self.resetForUIPhase = resetForUIPhase;
// Toolbar click with no popup must fire chrome.action.onClicked.
self.setPopupForUI = (popup) => chrome.action.setPopup({ popup }).then(() => "popup=" + popup);
