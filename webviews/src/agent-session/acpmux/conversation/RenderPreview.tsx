import { useEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import { RenderCard, renderTitle } from "./RenderCard";
import { renderFrameCSS } from "./renderBase";
import type { RenderCall } from "./renderCall";
import { isReactRender, REACT_MARKER } from "./renderFrameDoc";

const PREVIEW_POLICY = "default-src 'none'; style-src 'unsafe-inline'; img-src data:";

/// Partial pages never run scripts; the closed fence hands over in place (Lucas 2026-10-18).
export function RenderPreview({ call, streaming }: { call: RenderCall; streaming: boolean }) {
  const t = useT();
  const card = useRef<HTMLDivElement>(null);
  const [handoff, setHandoff] = useState(streaming);
  const [preview, setPreview] = useState(() => ({ html: call.html, css: renderFrameCSS() }));
  const updated = useRef(performance.now());
  useEffect(() => {
    if (!streaming) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    // Schedule from the last paint, so a steady stream still advances every 150 ms.
    const schedule = () => {
      if (timer !== undefined) return;
      timer = setTimeout(
        () => {
          updated.current = performance.now();
          setPreview({ html: call.html, css: renderFrameCSS() });
          timer = undefined;
        },
        Math.max(0, Math.ceil(150 - (performance.now() - updated.current))),
      );
    };
    if (call.html !== preview.html) schedule();
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { attributes: true });
    observer.observe(document.body, { attributes: true });
    observer.observe(document.head, { childList: true, subtree: true, characterData: true });
    const scheme = typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)") : undefined;
    scheme?.addEventListener("change", schedule);
    return () => {
      clearTimeout(timer);
      observer.disconnect();
      scheme?.removeEventListener("change", schedule);
    };
  }, [call.html, preview.html, streaming]);
  useEffect(() => {
    if (streaming || !handoff) return;
    const sized = (event: MessageEvent) => {
      if (
        event.source === card.current?.querySelector("iframe")?.contentWindow &&
        event.data?.type === "cmux-render-content-size"
      )
        setHandoff(false);
    };
    addEventListener("message", sized);
    return () => removeEventListener("message", sized);
  }, [streaming, handoff]);
  const srcdoc = useMemo(
    () =>
      // l10n-allow: iframe document markup and policy, not UI copy.
      `<!doctype html><meta http-equiv="Content-Security-Policy" content="${PREVIEW_POLICY}"><style>${preview.css}</style>${preview.html}`,
    [preview],
  );
  const title = call.title || renderTitle(preview.html) || t("render.untitled");
  const component = isReactRender(preview.html);
  return (
    <div ref={card} className={`acpmux-render-card acpmux-render-preview${!streaming && handoff ? " is-handoff" : ""}`}>
      {streaming ? (
        <>
          <div className="acpmux-render-card-head">
            <span className="acpmux-render-card-title">{title}</span>
            <span className="acpmux-render-preview-note">{t("render.writing")}</span>
          </div>
          <div className="acpmux-render-preview-body" inert>
            {component ? (
              <pre className="acpmux-render-preview-code">
                <code>{preview.html.slice(REACT_MARKER.length).trimStart().split("\n").slice(0, 8).join("\n")}</code>
              </pre>
            ) : (
              <iframe
                className="acpmux-render-card-frame"
                title={title}
                sandbox=""
                srcDoc={srcdoc}
                referrerPolicy="no-referrer"
                style={{ height: 160 }}
              />
            )}
          </div>
        </>
      ) : (
        <RenderCard call={call} />
      )}
    </div>
  );
}
