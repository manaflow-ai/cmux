// The render frame's document and policy outside the bundled pane (Lucas 2026-10-18): the dev
// server serves it at DEV_RENDER_FRAME_PATH with the policy as a header (vite.config.acpmux-pane.mjs),
// since a srcdoc frame would also inherit the pane's own stricter policy. No imports, so the dev
// server's config can load it.
export const DEV_RENDER_FRAME_PATH = "/__cmux-render-frame";

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

