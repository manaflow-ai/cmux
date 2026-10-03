// One edit in the changes view: its header and its diff on @pierre/diffs.
import React, { useMemo } from "react";
import { getFiletypeFromFileName, getSingularPatch, setLanguageOverride } from "@pierre/diffs";
import { FileDiff, useStableCallback } from "@pierre/diffs/react";
import { editPatch, hunkKey, type DiffEdit, type TurnFile } from "../diff";
import { t } from "../i18n";
import { isHighlighted } from "../shikiLanguages";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS } from "../diffTheme";
import { FileHeader, type FileActions, type FileView } from "./FileHeader";
import { HunkActions } from "./HunkActions";
import { hunkAnchor, type FocusAfter, type HunkAnchor, type HunkReview } from "./hunkReview";

export type DiffLayout = "unified" | "split";

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () =>
  document.documentElement.dataset.theme === "light" ? ("light" as const) : ("dark" as const);

export function EditBlock({
  file,
  edit,
  index,
  layout,
  wrap,
  view,
  on,
  onPainted,
  review,
  outsideAgentEdits,
  focusAfter,
}: {
  file: TurnFile;
  edit: DiffEdit;
  index: number;
  layout: DiffLayout;
  wrap: boolean;
  view: FileView;
  on: FileActions;
  onPainted: () => void;
  /// Hunk review, when the view offers it: each hunk gets Reject and Accept as a line annotation.
  review?: HunkReview;
  /// A file the turn changed outside its tool calls (a shell command, the user): read-only,
  /// with a note that says so.
  outsideAgentEdits?: boolean;
  focusAfter?: FocusAfter;
}) {
  // A language the bundle can't highlight shows as plain text; Pierre throws for it otherwise.
  // Each transcript update rebuilds the turn's files; the patch text is compared so an
  // unchanged edit keeps its parsed diff and does not paint again.
  const patch = useMemo(() => editPatch(file, edit), [file, edit]);
  const highlighted = isHighlighted(getFiletypeFromFileName(file.displayPath));
  const fileDiff = useMemo(() => {
    const parsed = getSingularPatch(patch);
    return highlighted ? parsed : setLanguageOverride(parsed, "text");
  }, [patch, highlighted]);
  const afterRender = useStableCallback(onPainted);
  const reviewing = review !== undefined;
  const annotations = useMemo(
    () =>
      reviewing
        ? edit.hunks.flatMap(
            (hunk, hunkIndex) => hunkAnchor(hunk, hunkKey(file, index, hunkIndex), file, edit.numbered) ?? [],
          )
        : [],
    [reviewing, edit, file, index],
  );
  const options = useMemo(
    () => ({
      theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
      themeType: paneThemeType(),
      diffStyle: layout,
      diffIndicators: "bars" as const,
      hunkSeparators: "line-info" as const,
      lineDiffType: "none" as const,
      overflow: wrap ? ("wrap" as const) : ("scroll" as const),
      // A fragment edit has no known place in its file, so its numbers would be made up.
      disableLineNumbers: !edit.numbered,
      // The bundled page allows no WebAssembly.
      preferredHighlighter: "shiki-js" as const,
      disableFileHeader: true,
      unsafeCSS: diffUnsafeCSS,
      onPostRender: afterRender,
    }),
    [layout, wrap, edit.numbered, afterRender],
  );
  // The header sits outside Pierre's diff, so collapsing or marking a file keeps the same
  // header node and the button the reader pressed keeps focus.
  const header = <FileHeader file={file} edit={edit} index={index} view={view} on={on} />;
  const showDiff = !view.collapsed && edit.hunks.length > 0;
  return (
    <div className="acpmux-diff-file" data-path={file.path} data-collapsed={view.collapsed ? "" : undefined}>
      {header}
      {outsideAgentEdits && <div className="acpmux-diff-outside">{t("changes.outsideAgentEdits")}</div>}
      {!view.collapsed && edit.hunks.length === 0 && (
        <div className="acpmux-diff-empty-edit">{file.binary ? "Binary file not shown" : "No line changes"}</div>
      )}
      {showDiff && (
        <FileDiff<HunkAnchor>
          className="acpmux-diff-pierre"
          fileDiff={fileDiff}
          options={options}
          lineAnnotations={annotations}
          renderAnnotation={(annotation) => {
            const anchor = annotation.metadata;
            return review && focusAfter && anchor ? (
              <HunkActions
                anchor={anchor}
                decision={review.decisions.get(anchor.key)}
                onDecide={(decision) => review.decide(anchor.key, decision)}
                focusAfter={focusAfter}
              />
            ) : null;
          }}
        />
      )}
    </div>
  );
}
