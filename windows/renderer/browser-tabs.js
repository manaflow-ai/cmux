import { defaultSettings } from "./config.js";
import {
  hostnameOf,
  normalizeBrowserPageUrl
} from "./browser-utils.js";
import { t } from "./i18n.js";

export const browserTabLimit = 12;
export const browserTabsStorageKey = "cmux.browserTabs";

function createBrowserTabId() {
  return `tab_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

export function browserTabTitle(url) {
  const host = hostnameOf(url);
  return host || t("browser.newTab");
}

export function normalizeBrowserTab(entry, fallbackUrl = defaultSettings.browserHomeUrl) {
  const url = normalizeBrowserPageUrl(entry?.url || entry?.value || fallbackUrl);
  if (!url) return null;
  const title = String(entry?.title || "").trim().slice(0, 80) || browserTabTitle(url);
  return {
    id: String(entry?.id || "").trim().slice(0, 80) || createBrowserTabId(),
    url,
    title
  };
}

export function normalizeBrowserTabSnapshot(snapshot, fallbackUrl = defaultSettings.browserHomeUrl) {
  const sourceTabs = Array.isArray(snapshot?.tabs) ? snapshot.tabs : [];
  const tabs = [];
  const seen = new Set();
  for (const source of sourceTabs) {
    const tab = normalizeBrowserTab(source, fallbackUrl);
    if (!tab || seen.has(tab.id)) continue;
    seen.add(tab.id);
    tabs.push(tab);
    if (tabs.length >= browserTabLimit) break;
  }
  if (tabs.length === 0) {
    const tab = normalizeBrowserTab({ url: fallbackUrl }, defaultSettings.browserHomeUrl);
    if (tab) tabs.push(tab);
  }
  let activeTabId = String(snapshot?.activeTabId || "").trim();
  if (!tabs.some((tab) => tab.id === activeTabId)) activeTabId = tabs[0]?.id || "";
  return { activeTabId, tabs };
}

export function loadBrowserTabSnapshots() {
  try {
    const parsed = JSON.parse(localStorage.getItem(browserTabsStorageKey) || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return new Map();
    const snapshots = new Map();
    for (const [panelId, snapshot] of Object.entries(parsed)) {
      const id = String(panelId || "").trim();
      if (!id) continue;
      snapshots.set(id, normalizeBrowserTabSnapshot(snapshot));
    }
    return snapshots;
  } catch {
    return new Map();
  }
}

export function saveBrowserTabSnapshots(snapshots) {
  const payload = {};
  for (const [panelId, snapshot] of snapshots.entries()) {
    payload[panelId] = normalizeBrowserTabSnapshot(snapshot);
  }
  localStorage.setItem(browserTabsStorageKey, JSON.stringify(payload));
}

export function browserTabSnapshotForPanel(snapshots, panel, homeUrl = defaultSettings.browserHomeUrl) {
  const fallbackUrl = normalizeBrowserPageUrl(panel?.url || homeUrl) || defaultSettings.browserHomeUrl;
  const panelId = panel?.id;
  const snapshot = normalizeBrowserTabSnapshot(panelId ? snapshots.get(panelId) : null, fallbackUrl);
  if (panelId) snapshots.set(panelId, snapshot);
  return snapshot;
}
