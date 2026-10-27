// Code cards while a reply streams (plans/cmux-next/acp-streaming.md "Code"). Highlighting the
// whole fence on every delta rebuilt Pierre's lines 150-700 times a turn and left the card empty
// (collapsed to its chrome) on some frames. An open fence now draws plain lines in the card's own
// metrics (12px on 20px lines), so its height is final as it grows; when it closes, Pierre renders
// it once underneath, and the highlighted card fades in over the plain one only after Pierre has
// painted its lines. Same metrics, so nothing moves; only the colors arrive.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { CodeBlock, languageLabel } from "./CodeBlock";
import { CopyButton } from "./CopyButton";
import { CodeBrackets } from "./icons";
import { useT } from "../i18n";
import { menuPartRef } from "./menuParts";
import { OpenPreview } from "./OpenPreview";
import { isAgentMotionOff } from "../../shared/motion";
import { entranceAllowed } from "../../shared/pageReveal";

/// The card's chrome over plain lines: an open fence, or a closed one drawn plain (the highlighted
/// card's chunk still loading, a fence over the highlight limits, a highlight past its budget). A
/// closed fence keeps the highlighted card's Open preview, so the panel opens from either card.
export function PlainCode({ code, lang, open = false }: { code: string; lang: string; open?: boolean }) {
  const t = useT();
  const lines = code.split("\n");
  // An open fence's trailing empty line is the newline before a line still arriving; drawing it
  // would make the card a line taller than the closed card it becomes.
  if (open && lines.length > 1 && lines.at(-1) === "") lines.pop();
  return (
    <div className="cv-codeblock cv-codeblock--plain" ref={menuPartRef({ code })}>
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{languageLabel(lang, t)}</span>
        <span className="cv-codeblock__actions">
          {!open && <OpenPreview code={code} lang={lang} />}
          <CopyButton text={code} label={t("code.copy")} />
        </span>
      </div>
      <div className="cv-codeblock__body">
        <pre className="cv-code-plain selectable">
          {lines.map((line, index) => (
            <div key={index} className="cv-code-plain__line">
              {line || "​"}
            </div>
          ))}
        </pre>
      </div>
    </div>
  );
}

/// How long the plain card waits for Pierre's lines before handing over anyway.
const HANDOFF_LIMIT_MS = 1_000;

type IdleWindow = Window & {
  requestIdleCallback?: (callback: IdleRequestCallback, options?: IdleRequestOptions) => number;
  cancelIdleCallback?: (handle: number) => void;
};

/// Syntax highlighting is decorative while a reply is arriving. Keep the plain card visible and
/// start Pierre in idle time so its one-time parse cannot steal the frame in which the stream grows.
/// The timeout is a bound, not a polling loop: a very busy page still gets the color handoff within
/// 800 ms, and the cleanup cancels either kind of scheduled work when the card leaves the tree.
function scheduleHighlight(callback: () => void): () => void {
  const idle = window as IdleWindow;
  if (idle.requestIdleCallback) {
    const handle = idle.requestIdleCallback(callback, { timeout: 800 });
    return () => idle.cancelIdleCallback?.(handle);
  }
  const handle = window.setTimeout(callback, 0);
  return () => window.clearTimeout(handle);
}

/// The bundled page starts Pierre's worker from its own `cmux-agent:`/`cmux-page:` origin. Keep
/// that path eager so worker setup is not delayed; HTTP/dev and an explicitly failed worker use
/// the bounded fallback handoff instead.
function highlightWorkerAvailable(): boolean {
  if (typeof location === "undefined" || typeof document === "undefined") return false;
  const bundled = location.protocol === "cmux-agent:" || location.protocol === "cmux-page:";
  return bundled && document.documentElement.dataset.cmuxHighlightWorker !== "failed";
}

/// A fence that closed while the reply streamed: highlighted once, then faded in over the plain card.
/// While the parent reply is still streaming, the plain card stays in place and the decorative
/// highlighter waits until the reply settles before it enters an idle window.
export function CodeHandoff({ code, lang, streaming = false }: { code: string; lang: string; streaming?: boolean }) {
  const [stage, setStage] = useState<"plain" | "fading" | "done">("plain");
  const deferHighlight = !highlightWorkerAvailable();
  const [highlightReady, setHighlightReady] = useState(!streaming || !deferHighlight);
  const ref = useRef<HTMLDivElement>(null);
  // A fence that closed while the chat was hidden (or as it shows again) hands over without the
  // fade: nobody watched it close (shared/pageReveal.ts).
  const [closedAway] = useState(() => !entranceAllowed());
  useEffect(() => {
    if (streaming || highlightReady || !deferHighlight) return;
    return scheduleHighlight(() => setHighlightReady(true));
  }, [deferHighlight, highlightReady, streaming]);
  useEffect(() => {
    if (!deferHighlight || highlightReady || typeof MutationObserver === "undefined") return;
    const observer = new MutationObserver(() => {
      if (highlightWorkerAvailable()) setHighlightReady(true);
    });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-cmux-highlight-worker"] });
    return () => observer.disconnect();
  }, [deferHighlight, highlightReady]);
  useLayoutEffect(() => {
    if (stage !== "plain" || !highlightReady) return;
    let frame = 0;
    const started = performance.now();
    const check = () => {
      if (isAgentMotionOff()) {
        setStage("done");
        return;
      }
      const host = ref.current?.querySelector("diffs-container");
      if (host?.shadowRoot?.querySelector("[data-line]") || performance.now() - started > HANDOFF_LIMIT_MS)
        // Under Reduce Motion nothing fades: the highlighted card replaces the plain one at once.
        setStage(
          isAgentMotionOff() ||
            closedAway ||
            !entranceAllowed() ||
            window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
            ? "done"
            : "fading",
        );
      else frame = requestAnimationFrame(check);
    };
    check();
    return () => cancelAnimationFrame(frame);
  }, [stage, closedAway, highlightReady]);
  // `ui.animationSpeed: off` removes CSS animations globally, so a card already fading never gets
  // its animationend event. Finish when the setting turns off mid-fade (the root's
  // data-agent-motion changes), so the plain card does not stay mounted under the highlighted one.
  useEffect(() => {
    if (stage !== "fading" || typeof MutationObserver === "undefined") return;
    const root = document.documentElement;
    const observer = new MutationObserver(() => {
      if (isAgentMotionOff()) setStage("done");
    });
    observer.observe(root, { attributes: true, attributeFilter: ["data-agent-motion"] });
    return () => observer.disconnect();
  }, [stage]);
  return (
    <div ref={ref} className={`cv-code-handoff is-${stage}`}>
      {stage !== "done" && <PlainCode code={code} lang={lang} />}
      {highlightReady && (
        <div className="cv-code-handoff__real" onAnimationEnd={() => setStage("done")}>
          <CodeBlock code={code} lang={lang} />
        </div>
      )}
    </div>
  );
}
