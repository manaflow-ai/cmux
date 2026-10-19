import { translate } from "../i18n";

import { literal } from "./renderFrameShell";
import { reactDependenciesSource } from "./renderStreamRuntime";

export { RENDER_FRAME_DOC, RENDER_POLICY } from "./renderFrameShell";

export { renderBridgeScript } from "./renderFrameShell";

export const REACT_MARKER = "<!-- cmux-react -->";
export const isReactRender = (html: string) => html.trimStart().startsWith(REACT_MARKER);

/// Compile in the opaque frame, never in the pane. Failures stay readable in the card.
export function reactRenderPage(code: string): string {
  const source = code.trimStart().startsWith(REACT_MARKER) ? code.trimStart().slice(REACT_MARKER.length) : code;
  // l10n-allow: executable component loader; its load failure uses the catalog
  return `<!doctype html><html><head></head><body><div id="root"></div><script>
  (function () {
    var root = document.getElementById('root');
    function fail(error) { if (window.__cmuxRenderKit) parent.postMessage({type:'cmux-render-error',error:String(error.message || error).slice(0,500)},'*'); root.style.color = 'var(--cmux-muted)'; root.textContent = String(error.message || error); }
    addEventListener('error', function (event) { fail(event.error || event.message); });
    ${reactDependenciesSource()}
    window.__cmuxReactReady = prepareReact(${literal(translate("render.loadFailed"))})
      .then(function () {
        var source = ${literal(source)};
        var code = Babel.transform(source + '\\nReactDOM.createRoot(document.getElementById("root")).render(React.createElement(App));', { presets: ['react'] }).code;
        new Function(code)();
      }).catch(fail);
  })();</script></body></html>`;
}
