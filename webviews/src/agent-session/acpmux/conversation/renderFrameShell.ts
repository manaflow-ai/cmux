import { renderStreamScript } from "./renderStreamRuntime";

// The render frame's document and policy outside the bundled pane (Lucas 2026-10-18): the dev
// server serves it at DEV_RENDER_FRAME_PATH with the policy as a header (vite.config.acpmux-pane.mjs),
// since a srcdoc frame would also inherit the pane's own stricter policy. Its imports stay
// browser-independent so the dev server's config can load it.
export const DEV_RENDER_FRAME_PATH = "/__cmux-render-frame";

/// The pane's navigation policy accepts only a different preview origin (Lucas 2026-10-18).
export function devRenderFrameURL(page: string): string {
  const url = new URL(page);
  url.hostname = url.hostname === "127.0.0.1" ? "localhost" : "127.0.0.1";
  url.pathname = DEV_RENDER_FRAME_PATH;
  url.search = "";
  url.hash = "";
  return url.href;
}

/// The dev frame mirrors AgentPaneRenderFrame's document and policy (Lucas 2026-10-18).
const CDNS = "https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com";
export const RENDER_POLICY = [
  "default-src 'none'",
  `script-src 'unsafe-inline' 'unsafe-eval' ${CDNS}`,
  `style-src 'unsafe-inline' https://fonts.googleapis.com ${CDNS}`,
  `font-src data: https://fonts.gstatic.com ${CDNS}`,
  "img-src data: blob:",
  "media-src data: blob:",
  "connect-src 'none'",
  "frame-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
].join("; ");
export const POLICY_META = `<meta http-equiv="Content-Security-Policy" content="${RENDER_POLICY}">`;
export const literal = (value: string) => JSON.stringify(value).replace(/</g, "\\u003c");

export const RENDER_FRAME_DOC = `<!doctype html><html><head>${POLICY_META}<meta charset="utf-8"><script>
"use strict";
(function () {
  var host = parent;
  function size() {
    var body = document.body;
    var height = Math.max(document.documentElement.scrollHeight, body ? body.scrollHeight : 0);
    host.postMessage({ type: "cmux-render-size", height: Math.ceil(height) }, "*");
  }
  function show(event) {
    var data = event.data;
    if (event.source !== host || !data || data.type !== "cmux-render" || typeof data.html !== "string") return;
    removeEventListener("message", show);
    document.open();
    // document.open replaces a srcdoc meta policy, so the replacement carries it first too.
    document.write('<!doctype html><html><head>' + ${literal(POLICY_META)} + '</head>' + data.html);
    document.close();
    var theme = document.createElement("style");
    theme.textContent = typeof data.css === "string" ? data.css : "";
    var head = document.head || document.documentElement;
    var policy = head.querySelector('meta[http-equiv="Content-Security-Policy"]');
    head.insertBefore(theme, policy ? policy.nextSibling : head.firstChild);
    new ResizeObserver(size).observe(document.documentElement);
    addEventListener("load", size);
    size();
  }
  addEventListener("message", show);
  host.postMessage({ type: "cmux-render-ready" }, "*");
})();
</script></head></html>`;

/// Installed before page scripts on either frame path. It exposes only requests to the card.
export function renderBridgeScript(theme: string, css: string): string {
  // l10n-allow: executable frame bridge, with no user-facing copy
  return `<script>(function () {
    var pending = new Map(), callbacks = new Set(), next = 0;
    var theme = { mode: ${literal(theme)} };
    var style = document.createElement('style');
    style.textContent = ${literal(css)};
    var head = document.head || document.documentElement;
    var policy = head.querySelector('meta[http-equiv="Content-Security-Policy"]');
    head.insertBefore(style, policy ? policy.nextSibling : head.firstChild);
    function request(method, params) {
      return new Promise(function (resolve, reject) {
        var id = String(++next);
        pending.set(id, { resolve: resolve, reject: reject });
        parent.postMessage({ type: 'cmux-render-request', id: id, method: method, params: params }, '*');
      });
    }
    window.cmux = {
      prefill: function (text) { return request('prefill', { text: text }); },
      sendPrompt: function (text) { return request('sendPrompt', { text: text }); },
      copy: function (text) { return request('copy', { text: text }); },
      openLink: function (url) { return request('openLink', { url: url }); },
      theme: theme,
      onTheme: function (callback) { callbacks.add(callback); return function () { callbacks.delete(callback); }; },
      state: {
        get: function () { return request('state.get', {}); },
        set: function (value) { return request('state.set', { value: value }); }
      }
    };
    // Viewport-sized bodies cannot measure their own frame. Follow their in-flow children.
    var lastHeight, sizing = false, resize, watched = new Set();
    function size() {
      sizing = false;
      var body = document.body;
      if (!body) return;
      var style = getComputedStyle(body);
      var top = Infinity, bottom = -Infinity;
      var children = Array.from(body.children).filter(function (child) {
        return !/^(SCRIPT|STYLE|LINK|META|TEMPLATE)$/.test(child.tagName);
      });
      // A fixed-height body cannot report child-only growth. Retain those observations.
      if (resize) {
        var current = new Set(children);
        watched.forEach(function (child) {
          if (!current.has(child)) { resize.unobserve(child); watched.delete(child); }
        });
        current.forEach(function (child) {
          if (!watched.has(child)) { resize.observe(child); watched.add(child); }
        });
      }
      children.forEach(function (child) {
        var position = getComputedStyle(child).position;
        if (position === 'absolute' || position === 'fixed') return;
        var rect = child.getBoundingClientRect();
        if (!rect.height) return;
        top = Math.min(top, rect.top); bottom = Math.max(bottom, rect.bottom);
      });
      var content = bottom > top ? bottom - top : 0;
      var margins = (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
      var height = content + (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0) + margins;
      if (!content && (children.length || body.textContent.trim())) height = Math.max(120, height);
      if (Math.ceil(height) === Math.ceil(window.innerHeight + margins)) return;
      height = Math.ceil(height);
      if (height === lastHeight) return;
      lastHeight = height;
      parent.postMessage({ type: 'cmux-render-content-size', height: height }, '*');
    }
    function scheduleSize() {
      if (sizing) return;
      sizing = true;
      window.requestAnimationFrame(size);
    }
    function observe() {
      // Keep the body as the wrapper, preserving agent selectors and layout.
      resize = new ResizeObserver(scheduleSize);
      resize.observe(document.body);
      var observer = new window.MutationObserver(scheduleSize);
      observer.observe(document.body, { childList: true, subtree: true, characterData: true });
      observer.observe(document.head, { childList: true, subtree: true, characterData: true });
      scheduleSize();
      document.fonts && document.fonts.ready.then(scheduleSize);
      document.fonts && document.fonts.addEventListener('loadingdone', scheduleSize);
    }
    if (document.readyState === 'loading') addEventListener('DOMContentLoaded', observe, { once: true });
    else observe();
    addEventListener('load', scheduleSize, true);
    addEventListener('transitionend', scheduleSize, true);
    addEventListener('animationend', scheduleSize, true);
    addEventListener('message', function (event) {
      var data = event.data;
      if (event.source !== parent || !data) return;
      if (data.type === 'cmux-render-reply') {
        var call = pending.get(data.id);
        if (!call) return;
        pending.delete(data.id);
        if (data.ok) call.resolve(data.value); else call.reject(new Error(data.error));
      } else if (data.type === 'cmux-render-theme' && (data.theme === 'light' || data.theme === 'dark') && typeof data.css === 'string') {
        theme.mode = data.theme;
        style.textContent = data.css;
        callbacks.forEach(function (callback) { try { callback(theme); } catch (_) {} });
      }
    });
  })();</script>`;
}

/// Already booted on the dev route and srcdoc; native shells retain the legacy handshake.
export const LIVE_RENDER_FRAME_DOC = `<!doctype html><html><head>${POLICY_META}<meta charset="utf-8">${renderBridgeScript("light", "")}${renderStreamScript()}</head><body></body></html>`;
