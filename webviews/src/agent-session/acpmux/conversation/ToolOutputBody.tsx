// The one readable body for non-shell tool results. Both rendered Markdown and Raw have a
// compact, scrollable viewport and the same all-lines disclosure; copy always takes the full text.
import { memo, useCallback, useId, useState } from "react";
import { useT } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { hoverActions } from "../../../ui/hoverActions.experiment";
import { useBlockWrap } from "./blockWrap";
import { Lines, lineCount, PreviewMore, SIDEWAYS_SCROLLER, usePreview, useSidewaysRef, WrapButton } from "./BlockParts";
import { CopyButton } from "./CopyButton";
import { ChevronRight } from "./icons";
import { Markdown } from "./Markdown";
import { menuPartRef } from "./menuParts";
import { watchOutputViewport } from "./outputViewport";
import { OutputMore, previewedOutput, useOutput } from "./toolOutput";
import type { ToolResult } from "./toolResult";

/// Its own component keeps the sideways watcher mounted with the Raw body when a reader switches
/// renderers. Markdown never mounts that watcher, and no renderer runs a tool's fences.
function MonoOutput({
  text,
  cut,
  preview,
  lang,
  viewport,
}: {
  text: string;
  cut: boolean;
  preview?: string;
  lang: ToolResult["lang"];
  viewport: (node: HTMLElement | null) => (() => void) | undefined;
}) {
  const t = useT();
  const [wrap] = useBlockWrap("output");
  const sideways = useSidewaysRef<HTMLPreElement>();
  const ref = useCallback(
    (node: HTMLPreElement | null) => {
      sideways.current = node;
      return viewport(node);
    },
    [sideways, viewport],
  );
  return (
    <pre
      ref={ref}
      className="cv-tool-output selectable"
      data-output-viewport=""
      data-wrap={wrap}
      data-preview={preview}
      data-lang={lang === "json" ? "json" : undefined}
      // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll body to read it with arrow keys.
      tabIndex={0}
      aria-label={t("handoff.tool_output")}
      {...SIDEWAYS_SCROLLER}
    >
      {cut && (
        <span className="cv-output-cut" aria-hidden="true">
          …{"\n"}
        </span>
      )}
      {text && <Lines text={text} />}
    </pre>
  );
}

export const ToolOutput = memo(function ToolOutput({
  id,
  result,
  reveal = 0,
}: {
  id?: string;
  result: ToolResult;
  reveal?: number;
}) {
  const t = useT();
  const generated = useId();
  const bodyId = `${id ?? generated}:body`;
  const raw = useOutput(result.text, reveal);
  const [rawShown, setRawShown] = useState(false);
  const [revealed, setRevealed] = useState(reveal);
  if (revealed !== reveal) {
    setRevealed(reveal);
    if (reveal > 0) setRawShown(false);
  }
  const [overflows, setOverflows] = useState(false);
  const preview = usePreview(lineCount(raw.text), reveal, overflows);
  const shown = previewedOutput(raw, preview);
  const markdown = result.lang === "markdown";
  const rendered = markdown && !rawShown;
  const viewport = useCallback(
    (node: HTMLElement | null) => (node ? watchOutputViewport(node, setOverflows) : undefined),
    [],
  );
  return (
    <div id={id} className="cv-tool-output-card" ref={menuPartRef({ output: raw.text })}>
      <div className="cv-tool-output__box" id={bodyId}>
        <span className="cv-tool-output__actions" data-find-skip="">
          {!rendered && <WrapButton kind="output" />}
          {experimentArm(hoverActions) === "all" && (
            <CopyButton text={raw.text ?? ""} label={t("turn.copy")} className="cv-codeblock__action" />
          )}
        </span>
        {rendered ? (
          <div
            ref={viewport}
            className="cv-tool-output__markdown selectable"
            data-output-viewport=""
            data-preview={preview.attribute}
            // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll body to read it with arrow keys.
            tabIndex={0}
            aria-label={t("handoff.tool_output")}
          >
            {shown.shown && <Markdown plainCode>{shown.shown}</Markdown>}
          </div>
        ) : (
          <MonoOutput
            text={shown.shown ?? ""}
            cut={shown.cut}
            preview={preview.attribute}
            lang={result.lang}
            viewport={viewport}
          />
        )}
      </div>
      <div className="cv-tool-output__controls" data-find-skip="">
        <PreviewMore preview={preview} />
        {!preview.long && <OutputMore output={shown} />}
        {markdown && (
          <button
            type="button"
            className="cv-tool-output__raw"
            aria-pressed={rawShown}
            data-fold-toggle=""
            aria-controls={bodyId}
            onClick={() => setRawShown((value) => !value)}
          >
            {t("subsession.raw")}
            <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${rawShown ? " is-open" : ""}`} />
          </button>
        )}
      </div>
    </div>
  );
});
