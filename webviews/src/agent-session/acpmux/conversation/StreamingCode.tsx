// Code cards while a reply streams (plans/cmux-next/acp-streaming.md "Code"). Highlighting the
// whole fence on every delta rebuilt Pierre's lines 150-700 times a turn and left the card empty
// (collapsed to its chrome) on some frames. An open fence now draws plain lines in the card's own
// metrics (12px on 20px lines), so its height is final as it grows; when it closes, Pierre renders
// it once underneath, and the highlighted card fades in over the plain one only after Pierre has
// painted its lines. Same metrics, so nothing moves; only the colors arrive.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { CodeBlock } from "./CodeBlock";
import { CodeHeader, codeHeaderClass, useCodeHeaderLook } from "./CodeHeader";
import { isDiagram } from "./codeShape";
import { CopyButton } from "./CopyButton";
import { useT } from "../i18n";
import { menuPartRef } from "./menuParts";
import { OpenPreview } from "./OpenPreview";
import { isAgentMotionOff } from "../../shared/motion";
import { entranceAllowed } from "../../shared/pageReveal";

/// The card's chrome over plain lines: an open fence, or a closed one drawn plain (the highlighted
/// card's chunk still loading, a fence over the highlight limits, a highlight past its budget). A
/// closed fence keeps the highlighted card's Open preview, so the panel opens from either card.
export function PlainCode({
  code,
  lang,
  open = false,
  actions,
}: {
  code: string;
  lang: string;
  open?: boolean;
  actions?: ReactNode;
}) {
  const t = useT();
  const look = useCodeHeaderLook(lang);
  // A tree drawn in box-drawing characters (├─ │) draws on lines that touch (conversation.css
  // `.cv-codeblock--diagram`); read once per code, not per render.
  const diagram = useMemo(() => isDiagram(code, lang), [code, lang]);
  const lines = code.split("\n");
  // An open fence's trailing empty line is the newline before a line still arriving; drawing it
  // would make the card a line taller than the closed card it becomes.
  if (open && lines.length > 1 && lines.at(-1) === "") lines.pop();
  return (
    <div
      className={`cv-codeblock cv-codeblock--plain${codeHeaderClass(look)}${diagram ? " cv-codeblock--diagram" : ""}`}
      ref={menuPartRef({ code })}
    >
      <CodeHeader look={look} lang={lang}>
        {!open && <OpenPreview code={code} lang={lang} />}
        <CopyButton text={code} label={t("code.copy")} />
        {actions}
      </CodeHeader>
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

/// A fence that closed while the reply streamed: highlighted once, then faded in over the plain card.
export function CodeHandoff({ code, lang, actions }: { code: string; lang: string; actions?: ReactNode }) {
  // A diagram stays the plain card (CodeBlock.tsx): nothing to hand over.
  const diagram = useMemo(() => isDiagram(code, lang), [code, lang]);
  if (diagram) return <PlainCode code={code} lang={lang} actions={actions} />;
  return <CodeHandoffFade code={code} lang={lang} actions={actions} />;
}

function CodeHandoffFade({ code, lang, actions }: { code: string; lang: string; actions?: ReactNode }) {
  const [stage, setStage] = useState<"plain" | "fading" | "done">("plain");
  const ref = useRef<HTMLDivElement>(null);
  // A fence that closed while the chat was hidden (or as it shows again) hands over without the
  // fade: nobody watched it close (shared/pageReveal.ts).
  const [closedAway] = useState(() => !entranceAllowed());
  useLayoutEffect(() => {
    if (stage !== "plain") return;
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
  }, [stage, closedAway]);
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
      {stage !== "done" && <PlainCode code={code} lang={lang} actions={actions} />}
      <div className="cv-code-handoff__real" onAnimationEnd={() => setStage("done")}>
        <CodeBlock code={code} lang={lang} actions={stage === "done" ? actions : undefined} />
      </div>
    </div>
  );
}
