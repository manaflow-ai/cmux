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
export function PlainCode({
  code,
  lang,
  open = false,
  artifactIdentity,
  artifactRevision,
}: {
  code: string;
  lang: string;
  open?: boolean;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
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
          <OpenPreview code={code} lang={lang} identity={artifactIdentity} revision={artifactRevision} />
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

/// A fence that closed while the reply streamed: highlighted once, then faded in over the plain card.
export function CodeHandoff({
  code,
  lang,
  artifactIdentity,
  artifactRevision,
}: {
  code: string;
  lang: string;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
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
      {stage !== "done" && (
        <PlainCode code={code} lang={lang} artifactIdentity={artifactIdentity} artifactRevision={artifactRevision} />
      )}
      <div className="cv-code-handoff__real" onAnimationEnd={() => setStage("done")}>
        <CodeBlock code={code} lang={lang} artifactIdentity={artifactIdentity} artifactRevision={artifactRevision} />
      </div>
    </div>
  );
}
