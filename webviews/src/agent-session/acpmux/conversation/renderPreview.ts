// l10n-allow-file: offscreen preview protocol and agent diagnostics.
import { transcriptRowWidth } from "../model";
import { labOn } from "../labs";
import { embeddedFrameCSS } from "./renderBase";
import { isReactRender, reactRenderPage } from "./renderFrameDoc";
import { literal, renderBridgeScript } from "./renderFrameShell";
import { renderStreamScript } from "./renderStreamRuntime";
import { renderPreviewDiagnostics } from "./renderPreviewDiagnostics";

/// A bridge-free host for the same opaque frame as the transcript (Lucas 2026-10-19).
export function previewDocument(
  html: string,
  css: string,
  theme: string,
  kit: boolean,
  frameURL = "cmux-agent://render/frame",
): string {
  const url = new URL(frameURL);
  const frameSource = `${url.protocol}//${url.host}`;
  const shell =
    "<!doctype html><html><head>" +
    renderBridgeScript(theme, css) +
    renderPreviewDiagnostics() +
    renderStreamScript() +
    "</head><body></body></html>";
  const page = isReactRender(html) ? reactRenderPage(html) : html;
  return `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src ${frameSource}"><style>html,body{margin:0;background:var(--cmux-canvas);overflow:hidden}iframe{display:block;width:100%;border:0;height:120px}</style><style>${css.replace(/<\/style/gi, "<\\/style")}</style></head><body><iframe sandbox="allow-scripts" referrerpolicy="no-referrer" src="${url.href.replace(/"/g, "%22")}"></iframe><script>
  window.cmuxPreviewResult = new Promise(function(resolve) {
    var frame = document.querySelector('iframe'), height = 0, booted = false;
    var timer = setTimeout(function() { resolve({error:'timeout'}); }, 6000);
    addEventListener('message', function(event) {
      if (event.source !== frame.contentWindow || !event.data) return;
      var data = event.data;
      if (data.type === 'cmux-render-ready' && !booted) {
        booted = true;
        frame.contentWindow.postMessage({type:'cmux-render',html:${literal(shell)},css:${literal(css)}}, '*');
      } else if (data.type === 'cmux-render-stream-ready') {
        frame.contentWindow.postMessage({type:'cmux-render-theme',theme:${literal(theme)},css:${literal(css)}}, '*');
        frame.contentWindow.postMessage({type:'cmux-render-kit',enabled:${kit}}, '*');
        frame.contentWindow.postMessage({type:'cmux-render-stream',html:${literal(page)},done:true}, '*');
      } else if (data.type === 'cmux-render-content-size' && Number.isFinite(data.height)) {
        height = Math.max(0, Math.ceil(data.height));
      } else if (data.type === 'cmux-render-request') {
        frame.contentWindow.postMessage({type:'cmux-render-reply',id:data.id,ok:false,error:'App actions are unavailable during preview'}, '*');
      } else if (data.type === 'cmux-render-preview-result') {
        clearTimeout(timer);
        height = Number.isFinite(data.height) ? Math.max(0, Math.ceil(data.height)) : height;
        frame.style.height = Math.max(1, Math.min(1600, height)) + 'px';
        resolve({contentHeight:height,capturedHeight:Math.max(1,Math.min(1600,height)),consoleMessages:Array.isArray(data.consoleMessages)?data.consoleMessages.slice(0,50).map(function(m){return {level:String(m && m.level).slice(0,20),message:String(m && m.message).slice(0,500)};}):[],warnings:Array.isArray(data.warnings)?data.warnings.slice(0,20).map(function(s){return String(s).slice(0,200)}):[],missingImages:Array.isArray(data.missingImages)?data.missingImages.slice(0,20).map(function(s){return String(s).slice(0,200)}):[]});
      }
    });
  });
  </script></body></html>`;
}

/// The native caller reads only its own pane's resolved labs, width and theme.
export function prepareRenderPreview(html: string, width?: number) {
  if (!labOn("renderPreview") || !labOn("liveRender"))
    throw Object.assign(new Error("Render preview is disabled"), { code: "disabled" });
  if (!html.trim() || new TextEncoder().encode(html).length > 1 << 20)
    throw new Error("Preview needs 1 byte to 1 MiB of HTML");
  if (width !== undefined && (!Number.isInteger(width) || width < 320 || width > 1440))
    throw new Error("Width must be 320 to 1440px");
  const column = Array.from(document.querySelectorAll(".acpmux-row.acpmux-assistant, .cv-md"))
    .find((element) => element.getBoundingClientRect().width > 0);
  const measured = column?.getBoundingClientRect().width;
  const fallback = transcriptRowWidth(document.documentElement.clientWidth || window.innerWidth || 756);
  const theme = getComputedStyle(document.body).colorScheme.includes("dark") ? "dark" : "light";
  const css = embeddedFrameCSS();
  return {
    width: width ?? Math.min(1440, Math.max(1, Math.floor(measured || fallback))),
    theme,
    document: previewDocument(
      html,
      css,
      theme,
      labOn("renderKit"),
    ),
  };
}
