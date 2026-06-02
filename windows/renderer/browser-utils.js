import { defaultSettings } from "./config.js";

const maxBrowserPageUrlLength = 2048;
export const embeddedGoogleHomeUrl = "https://www.google.com/webhp?igu=1";

// Google can cover embedded Chromium with a Chrome install sheet; keep the home pane usable.
export const embeddedGooglePromoDismissScript = `(() => {
  const observerKey = "__cmuxGooglePromoObserver";
  const doneKey = "__cmuxGooglePromoDone";
  if (window[doneKey]) return window[doneKey];
  const textOf = (node) => (node?.innerText || node?.textContent || "").replace(/\\s+/g, " ").trim();
  const cleanup = () => {
    window[observerKey]?.disconnect?.();
    window[observerKey] = null;
  };
  const nodes = (selector) => Array.from(document.querySelectorAll(selector));
  const finish = (result) => {
    cleanup();
    window[doneKey] = result || "done";
    return window[doneKey];
  };
  if (window[observerKey]) return "watching";
  const dismissPromo = () => {
    const dismiss = nodes('button, [role="button"], a, input[type="button"], input[type="submit"]').find((node) => {
      const text = textOf(node);
      if (!/^do not .*chrome$/i.test(text) && !/^no thanks$/i.test(text) && !/^not now$/i.test(text)) return false;
      const rect = node.getBoundingClientRect();
      return rect.width >= 80 && rect.width <= 260 && rect.height >= 24 && rect.height <= 90;
    });
    if (dismiss) {
      dismiss.click();
      return "clicked";
    }
    let hidden = 0;
    for (const node of nodes('dialog, [role="dialog"], [aria-modal="true"], aside, section, div')) {
      const text = textOf(node);
      if (!/built by Google/i.test(text) || !/Download Chrome/i.test(text)) continue;
      const rect = node.getBoundingClientRect();
      if (rect.width < 250 || rect.height < 100) continue;
      node.style.display = "none";
      node.setAttribute("aria-hidden", "true");
      hidden += 1;
    }
    return hidden ? "hidden" : "";
  };
  const immediateResult = dismissPromo();
  if (immediateResult) {
    return finish(immediateResult);
  }
  const root = document.documentElement || document.body;
  if (!root || typeof MutationObserver !== "function") return "";
  let pending = false;
  window[observerKey] = new MutationObserver(() => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      const result = dismissPromo();
      if (result) finish(result);
    });
  });
  window[observerKey].observe(root, { childList: true, subtree: true });
  return "watching";
})()`;

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

export function isGoogleHomeUrl(value, fallback = defaultSettings.browserHomeUrl) {
  try {
    const parsed = new URL(normalizeUrl(value, fallback));
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
    if (host !== "google.com") return false;
    const path = parsed.pathname.replace(/\/+$/, "") || "/";
    if (path !== "/" && path !== "/webhp") return false;
    if (parsed.searchParams.has("q")) return false;
    for (const key of parsed.searchParams.keys()) {
      if (!["igu", "zx"].includes(key.toLowerCase())) return false;
    }
    return true;
  } catch {
    return false;
  }
}

export function browserViewSourceUrl(value, fallback = defaultSettings.browserHomeUrl) {
  const targetUrl = normalizeUrl(value || fallback, fallback);
  return isGoogleHomeUrl(targetUrl, fallback) ? embeddedGoogleHomeUrl : targetUrl;
}

export function browserDisplayUrl(value, fallback = defaultSettings.browserHomeUrl) {
  const targetUrl = normalizeUrl(value || fallback, fallback);
  return isGoogleHomeUrl(targetUrl, fallback) ? "https://www.google.com/" : targetUrl;
}
