// Code cards while a reply streams (plans/cmux-next/acp-streaming.md "Code"). Highlighting the
// whole fence on every delta rebuilt Pierre's lines 150-700 times a turn and left the card empty
// (collapsed to its chrome) on some frames. An open fence now draws plain lines in the card's own
// metrics (12px on 20px lines), so its height is final as it grows; when it closes, Pierre renders
// it once underneath, and the highlighted card fades in over the plain one only after Pierre has
// painted its lines. Same metrics, so nothing moves; only the colors arrive.
import { useLayoutEffect, useRef, useState } from "react";
import { CodeBlock, languageLabel } from "./CodeBlock";
import { CodeBrackets } from "./icons";
import { useT } from "../i18n";

/// An open fence: the card's chrome over plain lines.
export function PlainCode({ code, lang, open = false }: { code: string; lang: string; open?: boolean }) {
  const t = useT();
  const lines = code.split("\n");
  // An open fence's trailing empty line is the newline before a line still arriving; drawing it
  // would make the card a line taller than the closed card it becomes.
  if (open && lines.length > 1 && lines.at(-1) === "") lines.pop();
  return (
    <div className="cv-codeblock cv-codeblock--plain">
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{languageLabel(lang, t)}</span>
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

/// A fence that closed while the reply streamed: highlighted once, then faded in over the plain card.
export function CodeHandoff({ code, lang }: { code: string; lang: string }) {
  const [stage, setStage] = useState<"plain" | "fading" | "done">("plain");
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (stage !== "plain") return;
    let frame = 0;
    const started = performance.now();
    const check = () => {
      const host = ref.current?.querySelector("diffs-container");
      if (host?.shadowRoot?.querySelector("[data-line]") || performance.now() - started > HANDOFF_LIMIT_MS)
        // Under Reduce Motion nothing fades: the highlighted card replaces the plain one at once.
        setStage(window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ? "done" : "fading");
      else frame = requestAnimationFrame(check);
    };
    check();
    return () => cancelAnimationFrame(frame);
  }, [stage]);
  return (
    <div ref={ref} className={`cv-code-handoff is-${stage}`}>
      {stage !== "done" && <PlainCode code={code} lang={lang} />}
      <div className="cv-code-handoff__real" onAnimationEnd={() => setStage("done")}>
        <CodeBlock code={code} lang={lang} />
      </div>
    </div>
  );
}
