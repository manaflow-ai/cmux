// MV2 background page (persistent). Chrome 154 removed MV2; the cmux CEF fork
// re-enables it, so this suite checks that the classic APIs still run.
"use strict";
const { expect } = CXT;
// MV2 rows use "mv2" as the API column; check the namespace each one needs.
const test = (api, name, fn, options = {}) => CXT.test(api, name, fn, Object.assign({ needs: null }, options));
const blocked = [];
chrome.webRequest.onBeforeRequest.addListener((details) => {
  blocked.push(details.url);
  return { cancel: true };
}, { urls: ["*://127.0.0.1/*mv2-block*"] }, ["blocking"]);

function cb(fn) {
  return new Promise((resolve, reject) => fn((value) =>
    chrome.runtime.lastError ? reject(new Error(chrome.runtime.lastError.message)) : resolve(value)));
}

async function run() {
  const cfg = await CXT.config();
  await CXT.post("/phase", { phase: "mv2", state: "start" });
  await test("mv2", "loaded", () => chrome.runtime.getManifest().manifest_version);
  await test("mv2", "extension.getURL", () => chrome.extension.getURL("popup.html"), { needs: "extension.getURL" });
  await test("mv2", "browserAction.setBadgeText", async () => {
    await cb((done) => chrome.browserAction.setBadgeText({ text: "M2" }, done));
    return cb((done) => chrome.browserAction.getBadgeText({}, done));
  }, { needs: "browserAction" });
  // A Chromium window exists only once cmux shows a Chromium tab.
  for (let i = 0; i < 100 && (await cb((done) => chrome.windows.getAll({}, done))).length === 0; i++) {
    await new Promise((r) => setTimeout(r, 200));
  }
  const tab = await cb((done) => chrome.tabs.create({ url: cfg.collector + "/page.html?suite=mv2", active: false }, done));
  await new Promise((resolve) => {
    const listener = (id, info) => {
      if (id === tab.id && info.status === "complete") { chrome.tabs.onUpdated.removeListener(listener); resolve(); }
    };
    chrome.tabs.onUpdated.addListener(listener);
  });
  await test("mv2", "tabs.executeScript", async () => {
    const [title] = await cb((done) => chrome.tabs.executeScript(tab.id, { code: "document.title" }, done));
    expect(title === "cxt page", "title " + title);
    return title;
  }, { needs: "tabs.executeScript" });
  await test("mv2", "webRequestBlocking", async () => {
    const [result] = await cb((done) => chrome.tabs.executeScript(tab.id, {
      code: "fetch('/mv2-block').then(r => 'loaded ' + r.status, e => 'blocked')",
    }, done));
    for (let i = 0; i < 30 && blocked.length === 0; i++) await new Promise((r) => setTimeout(r, 100));
    expect(blocked.length > 0, "listener never ran; page saw " + JSON.stringify(result));
    return blocked.length + " cancelled";
  });
  await cb((done) => chrome.tabs.remove(tab.id, done));
  await CXT.post("/phase", { phase: "mv2", state: "done" });
}
// Started by the runner in the cmux profile (see the MV3 worker's startAutoPhase).
window.startMV2Phase = () => {
  run().catch((error) => CXT.report("harness", "mv2_phase", "fail", error.message));
  return "started";
};
