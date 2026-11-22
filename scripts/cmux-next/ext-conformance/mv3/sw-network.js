// webRequest (observational in MV3) and declarativeNetRequest static,
// dynamic and session rules, checked with real page requests.
"use strict";

async function pageFetch(tabId, url) {
  const [result] = await chrome.scripting.executeScript({
    target: { tabId },
    args: [url],
    func: async (target) => {
      try {
        const response = await fetch(target, { cache: "no-store" });
        return { ok: response.ok, status: response.status, url: response.url, body: (await response.text()).slice(0, 80) };
      } catch (error) {
        return { blocked: true, error: String(error) };
      }
    },
  });
  return result.result;
}

async function networkTests(cfg) {
  const { test, expect } = CXT;
  const tabId = pageState.tabId;
  if (tabId == null) return;
  const base = cfg.collector;

  await test("webRequest", "onBeforeRequest_onCompleted", async () => {
    const seen = [];
    const filter = { urls: [base + "/wr-probe*"] };
    const before = (d) => { seen.push("before:" + d.type); };
    const headers = (d) => { seen.push("headers:" + d.statusCode); };
    const completed = new Promise((resolve) => {
      const listener = (d) => {
        chrome.webRequest.onCompleted.removeListener(listener);
        resolve(d);
      };
      chrome.webRequest.onCompleted.addListener(listener, filter);
    });
    chrome.webRequest.onBeforeRequest.addListener(before, filter);
    chrome.webRequest.onHeadersReceived.addListener(headers, filter, ["responseHeaders"]);
    await pageFetch(tabId, base + "/wr-probe?x=1");
    const done = await CXT.timeout(completed, 5000, "onCompleted");
    chrome.webRequest.onBeforeRequest.removeListener(before);
    chrome.webRequest.onHeadersReceived.removeListener(headers);
    expect(seen.some((s) => s.startsWith("before:")), "no onBeforeRequest");
    return seen.concat("completed:" + done.statusCode);
  });

  await test("declarativeNetRequest", "static_ruleset", async () => {
    const enabled = await chrome.declarativeNetRequest.getEnabledRulesets();
    const result = await pageFetch(tabId, base + "/dnr/static-block");
    expect(result.blocked, "not blocked: " + JSON.stringify(result));
    return { enabled, result: "blocked" };
  });
  await test("declarativeNetRequest", "dynamic_rules", async () => {
    await chrome.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: [10, 11],
      addRules: [
        { id: 10, priority: 1, action: { type: "block" }, condition: { urlFilter: "/dnr/dynamic-block", resourceTypes: ["xmlhttprequest"] } },
        { id: 11, priority: 1, action: { type: "redirect", redirect: { url: base + "/dnr/redirect-dst" } },
          condition: { urlFilter: "/dnr/redirect-src", resourceTypes: ["xmlhttprequest"] } },
      ],
    });
    const rules = await chrome.declarativeNetRequest.getDynamicRules();
    const blocked = await pageFetch(tabId, base + "/dnr/dynamic-block");
    const redirected = await pageFetch(tabId, base + "/dnr/redirect-src");
    await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [10, 11] });
    expect(blocked.blocked, "dynamic block missed " + JSON.stringify(blocked));
    expect(redirected.body === "redirect-dst", "redirect missed " + JSON.stringify(redirected));
    return rules.length + " dynamic rules, block + redirect";
  });
  await test("declarativeNetRequest", "session_rules", async () => {
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: [20],
      addRules: [{ id: 20, priority: 1, action: { type: "block" }, condition: { urlFilter: "/dnr/session-block", resourceTypes: ["xmlhttprequest"] } }],
    });
    const blocked = await pageFetch(tabId, base + "/dnr/session-block");
    const rules = await chrome.declarativeNetRequest.getSessionRules();
    await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [20] });
    const allowed = await pageFetch(tabId, base + "/dnr/session-block");
    expect(blocked.blocked && allowed.ok, "blocked " + JSON.stringify(blocked) + " after " + JSON.stringify(allowed));
    return rules.length + " session rules";
  });
  await test("declarativeNetRequest", "testMatchOutcome", async () => {
    const outcome = await chrome.declarativeNetRequest.testMatchOutcome({ url: base + "/dnr/static-block", type: "xmlhttprequest", tabId });
    expect(outcome.matchedRules.length === 1, JSON.stringify(outcome));
    return outcome.matchedRules;
  }, { needs: "declarativeNetRequest.testMatchOutcome" });
  await test("declarativeNetRequest", "getMatchedRules", async () => {
    const matched = await chrome.declarativeNetRequest.getMatchedRules({ tabId });
    return matched.rulesMatchedInfo.length + " matched";
  });
  await test("downloads", "page_download", async () => {
    // A download the page starts (a CEF browser owns it): Chrome's default
    // handling saves it; chrome.downloads observes it.
    const created = CXT.event(chrome.downloads.onCreated, 15000, "downloads.onCreated", (item) => item.url.includes("/download.bin?page=1"));
    await chrome.scripting.executeScript({ target: { tabId }, func: (url) => {
      const link = document.createElement("a");
      link.href = url;
      link.download = "cmux-conformance-page.bin";
      document.body.appendChild(link);
      link.click();
    }, args: [base + "/download.bin?page=1"] });
    const [item] = await created;
    const [delta] = await CXT.event(chrome.downloads.onChanged, 20000, "page download complete",
      (d) => d.id === item.id && d.state && d.state.current !== "in_progress");
    const [done] = await chrome.downloads.search({ id: item.id });
    expect(delta.state.current === "complete", "state " + delta.state.current + " " + (done && done.error));
    await chrome.downloads.removeFile(item.id).catch(() => {});
    await chrome.downloads.erase({ id: item.id });
    return done.filename;
  }, { timeout: 40000 });
  await test("declarativeNetRequest", "isRegexSupported", () => chrome.declarativeNetRequest.isRegexSupported({ regex: "^https?://cmux" }));
}
