import { defaultSettings } from "./config.js";

const maxBrowserPageUrlLength = 2048;

export function normalizeUrl(value, fallback = "https://www.google.com") {
  let next = String(value || "").trim();
  if (!next) next = fallback;
  if (/^https?:\/\//i.test(next)) return next;
  if (/^localhost(?::\d+)?(?:\/|$)/i.test(next) || /^(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?:\/|$)/.test(next)) {
    return `http://${next}`;
  }
  if (!/\s/.test(next) && next.includes(".")) return `https://${next}`;
  next = `https://www.google.com/search?q=${encodeURIComponent(next)}`;
  return next;
}

export function hostnameOf(value) {
  try {
    return new URL(normalizeUrl(value)).hostname;
  } catch {
    return "";
  }
}

export function normalizeBrowserPageUrl(value) {
  const url = normalizeUrl(value || defaultSettings.browserHomeUrl, defaultSettings.browserHomeUrl);
  try {
    const parsed = new URL(url);
    if (!["http:", "https:"].includes(parsed.protocol)) return "";
    if (parsed.username || parsed.password) return "";
    if (parsed.href.length > maxBrowserPageUrlLength) return "";
    return parsed.href;
  } catch {
    return "";
  }
}
