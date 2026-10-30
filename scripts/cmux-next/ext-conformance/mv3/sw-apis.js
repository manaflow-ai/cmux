// Browser-level APIs that need no tab.
"use strict";

async function actionTests() {
  const { test, expect } = CXT;
  await test("action", "setBadgeText", async () => {
    await chrome.action.setBadgeText({ text: "42" });
    const text = await chrome.action.getBadgeText({});
    expect(text === "42", "getBadgeText " + text);
    return text;
  });
  await test("action", "setBadgeBackgroundColor", async () => {
    await chrome.action.setBadgeBackgroundColor({ color: [200, 30, 30, 255] });
    return chrome.action.getBadgeBackgroundColor({});
  });
  await test("action", "setBadgeTextColor", async () => {
    await chrome.action.setBadgeTextColor({ color: "#ffffff" });
    return chrome.action.getBadgeTextColor({});
  }, { needs: "action.setBadgeTextColor" });
  await test("action", "setTitle", async () => {
    await chrome.action.setTitle({ title: "cxt title" });
    const title = await chrome.action.getTitle({});
    expect(title === "cxt title", "getTitle " + title);
    return title;
  });
  await test("action", "setIcon", async () => {
    const canvas = new OffscreenCanvas(32, 32);
    const context = canvas.getContext("2d");
    context.fillStyle = "#3c3c3c";
    context.fillRect(0, 0, 32, 32);
    await chrome.action.setIcon({ imageData: { 32: context.getImageData(0, 0, 32, 32) } });
    await chrome.action.setIcon({ path: { 16: "icon16.png", 32: "icon48.png" } });
    return "imageData and path";
  });
  await test("action", "setPopup", async () => {
    await chrome.action.setPopup({ popup: "popup.html?set=1" });
    const popup = await chrome.action.getPopup({});
    expect(popup.endsWith("popup.html?set=1"), "getPopup " + popup);
    await chrome.action.setPopup({ popup: "popup.html" });
    return popup;
  });
  await test("action", "enable_disable", async () => {
    await chrome.action.disable();
    const disabled = await chrome.action.isEnabled();
    await chrome.action.enable();
    const enabled = await chrome.action.isEnabled();
    expect(disabled === false && enabled === true, "isEnabled " + disabled + "/" + enabled);
    return "ok";
  }, { needs: "action.isEnabled" });
  await test("action", "getUserSettings", () => chrome.action.getUserSettings(), { needs: "action.getUserSettings" });
  // Left for the runner: the toolbar button must show this badge and title.
  await chrome.action.setBadgeText({ text: "OK" });
  await chrome.action.setTitle({ title: "cmux conformance ready" });
}

async function alarmTests() {
  const { test, expect } = CXT;
  await test("alarms", "create_fire", async () => {
    await chrome.alarms.create("cxt-alarm", { when: Date.now() + 1000 });
    const listed = await chrome.alarms.get("cxt-alarm");
    expect(listed && listed.name === "cxt-alarm", "alarms.get " + JSON.stringify(listed));
    const [alarm] = await CXT.event(chrome.alarms.onAlarm, 8000, "onAlarm", (a) => a.name === "cxt-alarm");
    return "fired " + alarm.name;
  });
  await test("alarms", "getAll_clear", async () => {
    await chrome.alarms.create("cxt-clear", { delayInMinutes: 5 });
    const all = await chrome.alarms.getAll();
    const cleared = await chrome.alarms.clear("cxt-clear");
    expect(cleared, "clear returned false");
    return all.length;
  });
}

async function menuTests() {
  const { test } = CXT;
  await test("contextMenus", "create", async () => {
    await chrome.contextMenus.removeAll();
    await new Promise((resolve, reject) =>
      chrome.contextMenus.create({ id: "cxt-page", title: "cxt page item", contexts: ["page", "selection", "link"] }, () =>
        chrome.runtime.lastError ? reject(new Error(chrome.runtime.lastError.message)) : resolve()));
    await chrome.contextMenus.update("cxt-page", { title: "cxt page item" });
    return "created cxt-page";
  });
  await test("contextMenus", "action_context", () => new Promise((resolve, reject) =>
    chrome.contextMenus.create({ id: "cxt-action", title: "cxt action item", contexts: ["action"] }, () =>
      chrome.runtime.lastError ? reject(new Error(chrome.runtime.lastError.message)) : resolve("ok"))));
}

async function notificationTests() {
  const { test, expect } = CXT;
  await test("notifications", "create_clear", async () => {
    const id = await chrome.notifications.create("cxt-note", {
      type: "basic", iconUrl: "icon128.png", title: "cmux conformance", message: "probe", silent: true,
    });
    expect(id === "cxt-note", "id " + id);
    const all = await chrome.notifications.getAll();
    const cleared = await chrome.notifications.clear(id);
    return { listed: Object.keys(all), cleared };
  });
  await test("notifications", "getPermissionLevel", () => chrome.notifications.getPermissionLevel());
}

async function localeTests() {
  const { test, expect } = CXT;
  await test("i18n", "getMessage", () => {
    const text = chrome.i18n.getMessage("greeting", ["cmux"]);
    expect(text === "Hello cmux", "got " + text);
    return text;
  });
  await test("i18n", "getUILanguage", () => chrome.i18n.getUILanguage());
  await test("i18n", "getAcceptLanguages", () => chrome.i18n.getAcceptLanguages());
  await test("i18n", "detectLanguage", async () => {
    const result = await chrome.i18n.detectLanguage("Ceci est une phrase en français pour détecter la langue.");
    expect(result.languages.some((l) => l.language === "fr"), JSON.stringify(result));
    return result.languages[0];
  });
}

async function permissionTests() {
  const { test, expect } = CXT;
  await test("permissions", "contains_getAll", async () => {
    const has = await chrome.permissions.contains({ permissions: ["tabs"] });
    const optional = await chrome.permissions.contains({ permissions: ["readingList"] });
    expect(has && !optional, "tabs " + has + ", readingList " + optional);
    return (await chrome.permissions.getAll()).permissions.length + " permissions";
  });
}

async function offscreenTests() {
  const { test, expect } = CXT;
  await test("offscreen", "createDocument", async () => {
    const ready = CXT.event(chrome.runtime.onMessage, 8000, "offscreen-ready", (m) => m && m.type === "offscreen-ready");
    await chrome.offscreen.createDocument({ url: "offscreen.html", reasons: ["DOM_PARSER"], justification: "conformance" });
    const [message] = await ready;
    const contexts = await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] });
    expect(contexts.length === 1, "offscreen contexts " + contexts.length);
    await chrome.offscreen.closeDocument();
    return message.parsed;
  });
}

async function sidePanelTests() {
  const { test } = CXT;
  await test("sidePanel", "setOptions_getOptions", async () => {
    await chrome.sidePanel.setOptions({ path: "sidepanel.html", enabled: true });
    return chrome.sidePanel.getOptions({});
  });
  await test("sidePanel", "panelBehavior", async () => {
    await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: false });
    return chrome.sidePanel.getPanelBehavior();
  });
}

async function systemTests() {
  const { test, expect } = CXT;
  await test("omnibox", "setDefaultSuggestion", () => chrome.omnibox.setDefaultSuggestion({ description: "cmux conformance" }));
  await test("idle", "queryState", () => chrome.idle.queryState(60));
  await test("idle", "setDetectionInterval", () => chrome.idle.setDetectionInterval(60));
  await test("management", "getSelf", () => chrome.management.getSelf().then((s) => s.installType));
  await test("management", "getAll", async () => {
    const all = await chrome.management.getAll();
    expect(all.some((e) => e.id === chrome.runtime.id), "self missing");
    return all.length;
  });
  await test("privacy", "network.get", () => chrome.privacy.network.networkPredictionEnabled.get({}));
  await test("privacy", "services.get", () => chrome.privacy.services.passwordSavingEnabled.get({}));
  await test("privacy", "websites.get", () => chrome.privacy.websites.thirdPartyCookiesAllowed.get({}), { needs: "privacy.websites.thirdPartyCookiesAllowed" });
  await test("proxy", "settings", async () => {
    const before = await chrome.proxy.settings.get({});
    await chrome.proxy.settings.set({ value: { mode: "direct" }, scope: "regular" });
    const during = await chrome.proxy.settings.get({});
    await chrome.proxy.settings.clear({ scope: "regular" });
    expect(during.levelOfControl === "controlled_by_this_extension", "levelOfControl " + during.levelOfControl);
    return before.levelOfControl + " -> " + during.levelOfControl;
  });
  await test("fontSettings", "getFontList", async () => {
    const fonts = await chrome.fontSettings.getFontList();
    expect(fonts.length > 0, "empty font list");
    return fonts.length + " fonts";
  });
  await test("fontSettings", "getFont", () => chrome.fontSettings.getFont({ genericFamily: "standard" }));
  await test("tts", "getVoices", async () => (await chrome.tts.getVoices()).length + " voices");
  await test("tts", "speak", () => new Promise((resolve, reject) => {
    chrome.tts.speak("cmux", {
      volume: 0, rate: 4,
      onEvent: (e) => {
        if (e.type === "end") resolve("end");
        if (e.type === "error") reject(new Error(e.errorMessage));
      },
    }, () => chrome.runtime.lastError && reject(new Error(chrome.runtime.lastError.message)));
  }), { timeout: 15000 });
  await test("system", "cpu", () => chrome.system.cpu.getInfo().then((i) => i.numOfProcessors), { needs: "system.cpu" });
  await test("system", "memory", () => chrome.system.memory.getInfo().then((i) => i.capacity > 0), { needs: "system.memory" });
  await test("system", "display", () => chrome.system.display.getInfo().then((d) => d.length + " displays"), { needs: "system.display" });
  await test("power", "keepAwake", () => { chrome.power.requestKeepAwake("system"); chrome.power.releaseKeepAwake(); return "ok"; });
}

async function identityTests(cfg) {
  const { test, expect } = CXT;
  await test("identity", "getRedirectURL", () => chrome.identity.getRedirectURL("cb"));
  await test("identity", "launchWebAuthFlow_silent", async () => {
    const redirect = chrome.identity.getRedirectURL("cb");
    const url = cfg.collector + "/auth?redirect_uri=" + encodeURIComponent(redirect);
    const result = await chrome.identity.launchWebAuthFlow({ url, interactive: false });
    expect(result && result.includes("code=cxt"), "result " + result);
    return result;
  });
  await test("identity", "getAuthToken", async () => {
    const result = await chrome.identity.getAuthToken({ interactive: false });
    return { status: "pass", detail: result };
  });
  await test("identity", "getProfileUserInfo", () => chrome.identity.getProfileUserInfo({}));
}

async function dataTests(cfg) {
  const { test, expect } = CXT;
  const url = cfg.collector + "/history-probe";
  await test("history", "addUrl_search_delete", async () => {
    await chrome.history.addUrl({ url });
    const found = await chrome.history.search({ text: "history-probe", startTime: 0 });
    expect(found.some((i) => i.url === url), "not found after addUrl");
    const visits = await chrome.history.getVisits({ url });
    await chrome.history.deleteUrl({ url });
    return visits.length + " visits";
  });
  await test("bookmarks", "create_search_remove", async () => {
    const folder = await chrome.bookmarks.create({ title: "cxt folder" });
    const mark = await chrome.bookmarks.create({ parentId: folder.id, title: "cxt mark", url });
    const found = await chrome.bookmarks.search("cxt mark");
    const tree = await chrome.bookmarks.getTree();
    await chrome.bookmarks.removeTree(folder.id);
    expect(found.some((b) => b.id === mark.id), "search missed");
    return tree[0].children.map((c) => c.title);
  });
  await test("topSites", "get", async () => (await chrome.topSites.get()).length + " sites");
  await test("sessions", "getDevices", () => chrome.sessions.getDevices());
  await test("cookies", "set_get_remove", async () => {
    const changed = CXT.event(chrome.cookies.onChanged, 4000, "cookies.onChanged", (c) => c.cookie.name === "cxt");
    await chrome.cookies.set({ url: cfg.collector, name: "cxt", value: "1" });
    const cookie = await chrome.cookies.get({ url: cfg.collector, name: "cxt" });
    expect(cookie && cookie.value === "1", "get " + JSON.stringify(cookie));
    await changed;
    const stores = await chrome.cookies.getAllCookieStores();
    await chrome.cookies.remove({ url: cfg.collector, name: "cxt" });
    return stores.length + " stores";
  });
  await test("browsingData", "removeCache", () => chrome.browsingData.removeCache({ since: Date.now() - 1000 }));
  await test("contentSettings", "javascript.get", () => chrome.contentSettings.javascript.get({ primaryUrl: cfg.collector + "/" }));
}

async function downloadTests(cfg) {
  const { test, expect } = CXT;
  await test("downloads", "download_complete", async () => {
    const filename = "cmux-conformance-" + cfg.run + ".bin";
    const id = await chrome.downloads.download({ url: cfg.collector + "/download.bin", filename, conflictAction: "uniquify" });
    const [delta] = await CXT.event(chrome.downloads.onChanged, 20000, "download complete",
      (d) => d.id === id && d.state && (d.state.current === "complete" || d.state.current === "interrupted"));
    const [item] = await chrome.downloads.search({ id });
    expect(delta.state.current === "complete", "state " + delta.state.current + " " + (item && item.error));
    await chrome.downloads.removeFile(id);
    await chrome.downloads.erase({ id });
    return item.filename;
  }, { timeout: 25000 });
}

async function apiTests(cfg) {
  await actionTests();
  await alarmTests();
  await menuTests();
  await notificationTests();
  await localeTests();
  await permissionTests();
  await offscreenTests();
  await sidePanelTests();
  await systemTests();
  await identityTests(cfg);
  await dataTests(cfg);
  await downloadTests(cfg);
}
