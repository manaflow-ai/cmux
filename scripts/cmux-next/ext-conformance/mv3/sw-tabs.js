// Tabs, windows and page APIs. Every test page comes from the collector, so
// the runner can also check that cmux adopted the tabs Chromium created.
"use strict";

const pageState = { tabId: null };

function waitComplete(tabId, ms = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      reject(new Error("tab " + tabId + " did not complete"));
    }, ms);
    const listener = (id, info, tab) => {
      if (id === tabId && info.status === "complete") {
        clearTimeout(timer);
        chrome.tabs.onUpdated.removeListener(listener);
        resolve(tab);
      }
    };
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === "complete" && tab.url && tab.url !== "about:blank") {
        clearTimeout(timer);
        chrome.tabs.onUpdated.removeListener(listener);
        resolve(tab);
      }
    }, () => {});
  });
}

async function tabTests(cfg) {
  const { test, expect, event } = CXT;
  const pageURL = cfg.collector + "/page.html?suite=mv3";

  await test("tabs", "query", async () => {
    const tabs = await chrome.tabs.query({});
    return tabs.length + " tabs";
  });
  await test("tabs", "create_onUpdated", async () => {
    const navigated = event(chrome.webNavigation.onCompleted, 15000, "webNavigation.onCompleted",
      (d) => d.frameId === 0 && d.url.startsWith(pageURL));
    const tab = await chrome.tabs.create({ url: pageURL, active: true });
    pageState.tabId = tab.id;
    const done = await waitComplete(tab.id);
    await CXT.post("/tab", { role: "page", tabId: tab.id, windowId: done.windowId, url: done.url });
    await navigated.then(() => CXT.report("webNavigation", "onCompleted", "pass", ""),
      (e) => CXT.report("webNavigation", "onCompleted", "fail", e.message));
    return { tabId: tab.id, windowId: done.windowId };
  }, { timeout: 20000 });
  const tabId = pageState.tabId;
  if (tabId == null) {
    await CXT.report("harness", "page_tab", "fail", "no test page tab; tab-dependent tests skipped");
    return;
  }
  await test("tabs", "get", async () => (await chrome.tabs.get(tabId)).title);
  await test("tabs", "sendMessage", async () => {
    let reply = null;
    for (let i = 0; i < 20 && !reply; i++) {
      reply = await chrome.tabs.sendMessage(tabId, { type: "ping" }).catch(() => null);
      if (!reply) await new Promise((r) => setTimeout(r, 250));
    }
    expect(reply && reply.pong, "no reply from content script");
    return reply;
  });
  await test("webNavigation", "getAllFrames", async () => {
    const frames = await chrome.webNavigation.getAllFrames({ tabId });
    expect(frames.length >= 3, frames.length + " frames");
    return frames.map((f) => f.url.replace(cfg.collector, ""));
  });
  await test("tabs", "captureVisibleTab", async () => {
    const tab = await chrome.tabs.get(tabId);
    await chrome.tabs.update(tabId, { active: true });
    const data = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
    expect(data.startsWith("data:image/png;base64,") && data.length > 2000, "data length " + data.length);
    const blob = await (await fetch(data)).blob();
    const bitmap = await createImageBitmap(blob);
    return bitmap.width + "x" + bitmap.height;
  });
  await test("tabs", "update_onActivated", async () => {
    const other = await chrome.tabs.create({ url: cfg.collector + "/blank.html", active: true });
    await waitComplete(other.id);
    const activated = event(chrome.tabs.onActivated, 5000, "onActivated", (info) => info.tabId === tabId);
    await chrome.tabs.update(tabId, { active: true });
    await activated;
    await chrome.tabs.update(other.id, { muted: true });
    const muted = await chrome.tabs.get(other.id);
    const removed = event(chrome.tabs.onRemoved, 5000, "onRemoved", (id) => id === other.id);
    await chrome.tabs.remove(other.id);
    await removed;
    expect(muted.mutedInfo.muted, "not muted");
    return "activated, muted, removed";
  });
  await test("tabs", "zoom", async () => {
    await chrome.tabs.setZoom(tabId, 1.25);
    const zoom = await chrome.tabs.getZoom(tabId);
    await chrome.tabs.setZoom(tabId, 0);
    expect(Math.abs(zoom - 1.25) < 0.01, "zoom " + zoom);
    return zoom;
  });
  await test("tabs", "detectLanguage", () => chrome.tabs.detectLanguage(tabId));
  await test("scripting", "executeScript", async () => {
    const [result] = await chrome.scripting.executeScript({ target: { tabId }, func: () => document.title });
    expect(result.result === "cxt page", "title " + result.result);
    return result.result;
  });
  await test("scripting", "executeScript_allFrames", async () => {
    const results = await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, func: () => location.pathname });
    expect(results.length >= 3, results.length + " frames");
    return results.map((r) => r.result);
  });
  await test("scripting", "insertCSS_removeCSS", async () => {
    const css = "#h { color: rgb(1, 2, 3) !important; }";
    await chrome.scripting.insertCSS({ target: { tabId }, css });
    const [styled] = await chrome.scripting.executeScript({ target: { tabId }, func: () => getComputedStyle(document.getElementById("h")).color });
    await chrome.scripting.removeCSS({ target: { tabId }, css });
    expect(styled.result === "rgb(1, 2, 3)", "color " + styled.result);
    return styled.result;
  });
  await test("scripting", "registerContentScripts", async () => {
    await chrome.scripting.unregisterContentScripts().catch(() => {});
    await chrome.scripting.registerContentScripts([{ id: "cxt-registered", matches: ["http://127.0.0.1/*"], js: ["registered.js"], runAt: "document_end" }]);
    const registered = await chrome.scripting.getRegisteredContentScripts();
    await chrome.tabs.reload(tabId);
    await waitComplete(tabId);
    const [flag] = await chrome.scripting.executeScript({ target: { tabId }, func: () => document.documentElement.dataset.cxtRegistered || "" });
    expect(flag.result === "1", "registered script did not run");
    return registered.map((s) => s.id);
  });
  await test("pageCapture", "saveAsMHTML", async () => {
    const blob = await chrome.pageCapture.saveAsMHTML({ tabId });
    expect(blob && blob.size > 100, "size " + (blob && blob.size));
    return blob.size + " bytes";
  });
  await test("debugger", "attach_sendCommand", async () => {
    await chrome.debugger.attach({ tabId }, "1.3");
    const result = await chrome.debugger.sendCommand({ tabId }, "Runtime.evaluate", { expression: "6 * 7" });
    await chrome.debugger.detach({ tabId });
    expect(result.result.value === 42, JSON.stringify(result));
    return 42;
  });
  await test("tabGroups", "group_update_query", async () => {
    const groupId = await chrome.tabs.group({ tabIds: [tabId] });
    await chrome.tabGroups.update(groupId, { title: "cxt", color: "grey" });
    const group = await chrome.tabGroups.get(groupId);
    const query = await chrome.tabGroups.query({ title: "cxt" });
    await chrome.tabs.ungroup([tabId]);
    expect(group.title === "cxt" && query.length === 1, JSON.stringify(group));
    return group.color;
  });
  await windowTests(cfg);
  await test("search", "query", async () => {
    const created = event(chrome.tabs.onCreated, 8000, "search tab");
    await chrome.search.query({ text: "cmux conformance", disposition: "NEW_TAB" });
    const [tab] = await created;
    await chrome.tabs.remove(tab.id);
    return "new tab " + tab.id;
  });
  await test("sessions", "getRecentlyClosed_restore", async () => {
    const closed = await chrome.tabs.create({ url: cfg.collector + "/blank.html?closed=1", active: false });
    await waitComplete(closed.id);
    await chrome.tabs.remove(closed.id);
    const recent = await chrome.sessions.getRecentlyClosed({ maxResults: 5 });
    expect(recent.length > 0, "nothing recently closed");
    const restored = await chrome.sessions.restore();
    const tab = restored.tab || (restored.window && restored.window.tabs[0]);
    if (tab) await chrome.tabs.remove(tab.id);
    return recent.length + " closed, restored " + (tab ? tab.url : "?");
  });
}

async function windowTests(cfg) {
  const { test, expect, event } = CXT;
  await test("windows", "getAll_getCurrent", async () => {
    const all = await chrome.windows.getAll({ populate: true });
    const current = await chrome.windows.getCurrent();
    const last = await chrome.windows.getLastFocused();
    return { windows: all.length, tabs: all.map((w) => w.tabs.length), current: current.id, last: last.id };
  });
  await test("windows", "create_remove", async () => {
    const created = event(chrome.windows.onCreated, 8000, "windows.onCreated");
    const win = await chrome.windows.create({ url: cfg.collector + "/blank.html?window=1", focused: false, type: "normal" });
    await created;
    await CXT.post("/tab", { role: "window", windowId: win.id, tabId: win.tabs && win.tabs[0] && win.tabs[0].id });
    const got = await chrome.windows.get(win.id, { populate: true });
    await new Promise((r) => setTimeout(r, 1500));
    const removed = event(chrome.windows.onRemoved, 8000, "windows.onRemoved", (id) => id === win.id);
    await chrome.windows.remove(win.id);
    await removed;
    expect(got.tabs.length === 1, "tabs " + got.tabs.length);
    return { id: win.id, type: got.type, bounds: [got.left, got.top, got.width, got.height] };
  });
  await test("windows", "create_popup", async () => {
    const win = await chrome.windows.create({ url: cfg.collector + "/blank.html?popup=1", type: "popup", width: 400, height: 300, focused: false });
    await CXT.post("/tab", { role: "popup-window", windowId: win.id });
    await new Promise((r) => setTimeout(r, 1500));
    await chrome.windows.remove(win.id);
    return { id: win.id, type: win.type };
  });
}
