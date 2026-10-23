// An opened shell call: a "Shell" card with the folder it ran in (a leading `cd ~/wt/lanes/x &&`
// reads as "x" beside the label), Wrap lines and Copy, the command line, its output (the end of a
// long one) and, when the command failed, its exit code; a caller's `footer` closes the card. Past
// eight lines it shows its first ones under a fade, with Show all N lines (BlockParts.tsx). Output
// wraps by default, each line hanging under its start; unwrapped, its right edge fades while more
// lies past.
import type { ReactNode } from "react";
import { useT } from "../i18n";
import { useBlockWrap } from "./blockWrap";
import { Lines, lineCount, PreviewMore, SIDEWAYS_SCROLLER, usePreview, useSidewaysRef, WrapButton } from "./BlockParts";
import { commandFolder } from "./commandFolder";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { OutputMore, previewedOutput, useOutput } from "./toolOutput";

export function ShellBlock({
  id,
  command,
  output,
  exitCode,
  reveal,
  whole = false,
  cut,
  footer,
  live = false,
}: {
  id?: string;
  /** Bumped when Find in Chat reveals the call: shows the whole output, not only its end. */
  reveal?: number;
  command?: string;
  output?: string;
  exitCode?: number;
  /** Never cut to a preview (a command a permission ask is about). */
  whole?: boolean;
  /** The output starts after the beginning of what the command printed (a read tail). */
  cut?: boolean;
  /** The card's last line, under the exit code (a background task's Open in terminal). */
  footer?: ReactNode;
  /** The command still runs: its output may yet run past the right edge (conversation.css `data-live`). */
  live?: boolean;
}) {
  const t = useT();
  const raw = useOutput(output, reveal);
  const { folder, rest } = command ? commandFolder(command) : { folder: undefined, rest: undefined };
  const [wrap] = useBlockWrap("output");
  // The command's lines and all the output's, though a long output draws only its end until opened
  // (none to cut when whole).
  const preview = usePreview(whole ? 0 : (rest ? lineCount(rest) : 0) + lineCount(raw.text), reveal);
  const shown = previewedOutput(raw, preview);
  const body = useSidewaysRef<HTMLPreElement>();
  return (
    <div className="cv-shell" id={id} ref={menuPartRef({ command, output: shown.text })}>
      <div className="cv-shell__label">
        <span className="cv-shell__title">
          {t("shell.label")}
          {folder && (
            <span
              className="cv-shell__folder"
              data-find-skip
              /* tooltip-allow: the full `cd …` prefix shows nowhere else (the command line drops it) */
              title={command!.slice(0, command!.length - rest!.length).trim()}
            >
              {folder}
            </span>
          )}
        </span>
        <span className="cv-shell__actions">
          <WrapButton kind="output" />
          {shown.text && <CopyButton text={shown.text} label={t("turn.copy")} />}
        </span>
      </div>
      <pre
        ref={body}
        className="cv-shell__body selectable"
        data-wrap={wrap}
        data-preview={preview.attribute}
        data-live={live || undefined}
        {...SIDEWAYS_SCROLLER}
      >
        {rest && (
          <span className="cv-shell__command">
            <Lines text={`$ ${rest}`} />
          </span>
        )}
        {(shown.cut || Boolean(cut && shown.shown)) && (
          <span className="cv-output-cut" aria-hidden="true">
            …
          </span>
        )}
        {shown.shown && (
          <span className="cv-shell__output">
            <Lines text={shown.shown} />
          </span>
        )}
      </pre>
      <PreviewMore preview={preview} />
      {!preview.long && <OutputMore output={shown} />}
      {exitCode !== undefined && exitCode !== 0 && (
        // The block's own words, not the output: Find in Chat does not count them (chatFind.ts).
        <div className="cv-shell__exit" data-find-skip>
          {t("shell.exit", { code: exitCode })}
        </div>
      )}
      {footer}
    </div>
  );
}
