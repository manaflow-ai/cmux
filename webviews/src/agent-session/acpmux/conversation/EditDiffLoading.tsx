import { type CSSProperties, type ReactNode } from "react";
import type { DiffEdit, TurnFile } from "../diff";
import { useT } from "../i18n";
import { LOADING_TEXT_LINES } from "./editDiffLoadingModel";
/// What the placeholder draws for one edit: its hunks' lines and, before a hunk that skips lines
/// of the file, the separator Pierre draws there (its `collapsedBefore`, @pierre/diffs
/// parsePatchFiles: the hunk's new-file start less the previous hunk's end, from the same ranges
/// `editPatch` writes). Pierre draws no separator after the last hunk of a patch.
type Part = { kind: "sep" } | { kind: "line"; text: string } | { kind: "rest"; lines: number };

function editParts(edit: DiffEdit, budget: number): { parts: Part[]; digits: number } {
  const parts: Part[] = [];
  let lastEnd = 0;
  let maxLine = 0;
  let drawn = 0;
  let rest = 0;
  for (const hunk of edit.hunks) {
    const oldLines = hunk.lines.filter((line) => line.type !== "add");
    const newLines = hunk.lines.filter((line) => line.type !== "del");
    const start = newLines[0]?.newLine ?? Math.max(0, (oldLines[0]?.oldLine ?? 1) - 1);
    if (start - 1 - lastEnd > 0) {
      if (rest) parts.push({ kind: "rest", lines: rest });
      rest = 0;
      parts.push({ kind: "sep" });
    }
    lastEnd = start + newLines.length - 1;
    for (const line of hunk.lines) {
      maxLine = Math.max(maxLine, line.newLine ?? 0, line.oldLine ?? 0);
      if (drawn < budget) {
        parts.push({ kind: "line", text: line.text });
        drawn++;
      } else rest++;
    }
  }
  if (rest) parts.push({ kind: "rest", lines: rest });
  return { parts, digits: Math.max(4, String(maxLine).length) };
}

/** No syntax renderer in this dependency graph. While Pierre's chunk loads, each edit draws its
 * lines as text in the diff's font, column and wrapping, painted as bars, so the body is as tall
 * as the rendered diff and nothing moves when it replaces this (gallery health's layout-shift
 * check). A cut preview draws its hidden lines too, so Show all opens it to the rendered diff's
 * height while the chunk is still pending. */
export function EditDiffLoading({ file, wrap }: { file: TurnFile; wrap: boolean }) {
  const t = useT();
  let budget = LOADING_TEXT_LINES;
  return (
    <section className="cv-edit-diff__loading" aria-label={t("changes.loading")} aria-busy="true">
      {file.edits.map((edit, index) => {
        if (!edit.hunks.length)
          return (
            <div key={edit.toolId + index} className="cv-edit-diff__empty">
              {t("changes.noLineChanges")}
            </div>
          );
        const { parts, digits } = editParts(edit, Math.max(0, budget));
        budget -= parts.filter((part) => part.kind === "line").length;
        const children: ReactNode[] = parts.map((part, at) =>
          part.kind === "sep" ? (
            <div key={at} className="cv-edit-diff__loading-sep" />
          ) : part.kind === "rest" ? (
            <div
              key={at}
              className="cv-edit-diff__loading-rest"
              style={{ "--cv-loading-lines": part.lines } as CSSProperties}
            />
          ) : (
            <div key={at} className="cv-edit-diff__loading-line">
              {part.text ? <span>{part.text}</span> : null}
            </div>
          ),
        );
        return (
          <div
            key={edit.toolId + index}
            className="cv-edit-diff__loading-lines"
            data-numbered={edit.numbered}
            data-wrap={wrap}
            data-find-skip=""
            aria-hidden="true"
            style={{ "--cv-loading-digits": digits } as CSSProperties}
          >
            {children}
          </div>
        );
      })}
    </section>
  );
}
