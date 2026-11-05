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
  label,
  open = false,
  actions,
  artifactIdentity,
  artifactRevision,
}: {
  code: string;
  lang: string;
  label?: string;
  open?: boolean;
  actions?: ReactNode;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  const t = useT();
  const look = useCodeHeaderLook(lang, label);
  // A tree drawn in box-drawing characters (├─ │) draws on lines that touch (conversation.css
  // `.cv-codeblock--diagram`); read once per code, not per render.
  const diagram = useMemo(() => isDiagram(code, lang), [code, lang]);
  return (
    <div
      className={`cv-codeblock cv-codeblock--plain${codeHeaderClass(look)}${diagram ? " cv-codeblock--diagram" : ""}`}
      ref={menuPartRef({ code })}
    >
      <CodeHeader look={look} lang={lang} label={label}>
        <OpenPreview code={code} lang={lang} identity={artifactIdentity} revision={artifactRevision} />
        <CopyButton text={code} label={t("code.copy")} />
        {actions}
      </CodeHeader>
      <div className="cv-codeblock__body">
        <PlainCodeLines code={code} trimTrailingLine={open || !diagram} />
      </div>
    </div>
  );
}

/// The same visible lines serve the lazy chunk and the worker wait. Pierre treats a final newline
/// as the end of the last line, not an extra empty row.
export function PlainCodeLines({
  code,
  trimTrailingLine = true,
  wrap = false,
}: {
  code: string;
  trimTrailingLine?: boolean;
  wrap?: boolean;
}) {
  const lines = (trimTrailingLine ? code.replace(/\n$/, "") : code).split("\n");
  return (
    <pre
      className="cv-code-plain selectable"
      style={wrap ? { whiteSpace: "pre-wrap", overflowWrap: "anywhere" } : undefined}
    >
      {lines.map((line, index) => (
        <div key={index} className="cv-code-plain__line">
          {line || "​"}
        </div>
      ))}
    </pre>
  );
}

/// How long the plain card waits for Pierre's lines before handing over anyway.
const HANDOFF_LIMIT_MS = 1_000;

/// A fence that closed while the reply streamed: highlighted once, then faded in over the plain card.
type CodeHandoffProps = {
  code: string;
  lang: string;
  actions?: ReactNode;
  artifactIdentity?: string;
  artifactRevision?: number;
};

export function CodeHandoff(props: CodeHandoffProps) {
  // A diagram stays the plain card (CodeBlock.tsx): nothing to hand over.
  const diagram = useMemo(() => isDiagram(props.code, props.lang), [props.code, props.lang]);
  if (diagram) return <PlainCode {...props} />;
  return <CodeHandoffFade {...props} />;
}

function CodeHandoffFade({ code, lang, actions, artifactIdentity, artifactRevision }: CodeHandoffProps) {
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
        <PlainCode
          code={code}
          lang={lang}
          actions={actions}
          artifactIdentity={artifactIdentity}
          artifactRevision={artifactRevision}
        />
      )}
      <div
        className="cv-code-handoff__real"
        // Keep duplicate highlighted controls out of keyboard and assistive technology traversal
        // while the plain card is visible underneath.
        aria-hidden={stage !== "done" || undefined}
        inert={stage !== "done" || undefined}
        onAnimationEnd={() => setStage("done")}
      >
        <CodeBlock
          code={code}
          lang={lang}
          actions={stage === "done" ? actions : undefined}
          artifactIdentity={artifactIdentity}
          artifactRevision={artifactRevision}
        />
      </div>
    </div>
  );
}
