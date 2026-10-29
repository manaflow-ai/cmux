// One edit in the changes view: its header and its diff on @pierre/diffs.
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  getFiletypeFromFileName,
  getSingularPatch,
  processFile,
  setLanguageOverride,
  type DiffLineAnnotation,
} from "@pierre/diffs";
import { FileDiff, WorkerPoolContext, useStableCallback } from "@pierre/diffs/react";
import { editPatch, hunkKey, type DiffEdit, type TurnFile } from "../diff";
import { isHighlighted } from "../shikiLanguages";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS } from "../diffTheme";
import { FileHeader, type FileActions, type FileView } from "./FileHeader";
import { HunkActions } from "./HunkActions";
import { HunkStage } from "./HunkStage";
import { ReviewThread } from "./ReviewThread";
import { showsLine, threadId, type AddressState, type ReviewThread as Thread } from "./reviewThreads";
import { useT } from "../i18n";
import { intralineMode } from "./intraline";
import { hunkAnchor, type FocusAfter, type HunkAnchor, type HunkReview } from "./hunkReview";
import { paneHighlightPool } from "../conversation/highlightPool";
import { readWholeFile, type WholeFile } from "./wholeFile";
import type { FileKind } from "../../../fileKinds";

export type DiffLayout = "unified" | "split";
/// A line annotation: a hunk's actions, or a review thread.
type AnnotationOf = { anchor?: HunkAnchor; thread?: Thread };

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () =>
  document.documentElement.dataset.theme === "light" ? ("light" as const) : ("dark" as const);

export function EditBlock({
  file,
  kind,
  edit,
  index,
  layout,
  wrap,
  view,
  on,
  onPainted,
  review,
  focusAfter,
  threads,
  address,
}: {
  file: TurnFile;
  /// The file's kind (fileKinds.ts), named in its header when it is not code.
  kind?: FileKind;
  edit: DiffEdit;
  index: number;
  layout: DiffLayout;
  wrap: boolean;
  view: FileView;
  on: FileActions;
  onPainted: () => void;
  /// Hunk review, when the view offers it: each hunk gets Reject and Accept as a line annotation.
  review?: HunkReview;
  focusAfter?: FocusAfter;
  /// The file's pull request review threads (Branch scope): each under its line, or above the
  /// diff when this edit does not show that line.
  threads?: readonly Thread[];
  /// Address on an open thread (ReviewThread.tsx): each thread's state, by `threadId`, and its press.
  address?: { states: ReadonlyMap<string, AddressState>; run: (thread: Thread) => void };
}) {
  const t = useT();
  // A language the bundle can't highlight shows as plain text; Pierre throws for it otherwise.
  // Each transcript update rebuilds the turn's files; the patch text is compared so an
  // unchanged edit keeps its parsed diff and does not paint again.
  const patch = useMemo(() => editPatch(file, edit), [file, edit]);
  const highlighted = isHighlighted(getFiletypeFromFileName(file.displayPath));
  const language = highlighted ? getFiletypeFromFileName(file.displayPath) : "text";
  // Show more lines (cx-ncc.85): a git scope's file is read whole as it comes into view; with both
  // versions known, the diff is no longer partial and its hunk separators expand.
  const box = useRef<HTMLDivElement>(null);
  const [whole, setWhole] = useState<{ patch: string; file: WholeFile }>();
  const readWhole = on.wholeFile;
  const expandable =
    readWhole !== undefined &&
    !view.collapsed &&
    edit.numbered &&
    edit.hunks.length > 0 &&
    !file.created &&
    !file.deleted &&
    !file.binary &&
    !file.patchTruncated;
  const wholeFile = whole?.patch === patch ? whole.file : undefined;
  useEffect(() => {
    const element = box.current;
    if (!expandable || !readWhole || !element || wholeFile) return undefined;
    let live = true;
    const load = () =>
      readWhole(file.path).then(
        (answer) => {
          const read = answer && readWholeFile(answer.value, answer.named, edit);
          if (live && read) setWhole({ patch, file: read });
        },
        () => undefined,
      );
    if (typeof IntersectionObserver === "undefined") {
      void load();
      return () => void (live = false);
    }
    const watch = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        watch.disconnect();
        void load();
      },
      { rootMargin: "400px 0px" },
    );
    watch.observe(element);
    return () => {
      live = false;
      watch.disconnect();
    };
  }, [expandable, readWhole, wholeFile, file.path, patch, edit]);
  const fileDiff = useMemo(() => {
    const name = file.displayPath;
    const parsed =
      (wholeFile &&
        processFile(patch, {
          isGitDiff: true,
          oldFile: { name, contents: wholeFile.before },
          newFile: { name, contents: wholeFile.after },
        })) ||
      getSingularPatch(patch);
    return highlighted ? parsed : setLanguageOverride(parsed, "text");
  }, [patch, highlighted, wholeFile, file.displayPath]);
  const afterRender = useStableCallback(onPainted);
  const lineDiffType = useMemo(() => intralineMode(edit), [edit]);
  const workerPool = paneHighlightPool(lineDiffType, language);
  const reviewing = review !== undefined;
  // A git scope's hunks stage one by one; a new or deleted file stages whole, from its header, and
  // a patch the host cut short has a last hunk the App's own read would not match.
  const staging = !reviewing && on.stageHunk !== undefined && !file.created && !file.deleted && !file.patchTruncated;
  const addressOf = (thread: Thread) =>
    address && {
      state: address.states.get(threadId(thread)) ?? { state: "idle" as const },
      run: () => address.run(thread),
    };
  const [placed, unplaced] = useMemo(() => {
    const on = (threads ?? []).filter((thread) => edit.numbered && showsLine(edit, thread));
    return [on, (threads ?? []).filter((thread) => !on.includes(thread))];
  }, [threads, edit]);
  const annotations = useMemo(
    (): DiffLineAnnotation<AnnotationOf>[] => [
      ...(reviewing || staging
        ? edit.hunks.flatMap((hunk, hunkIndex) => {
            const at =
              hunk.reviewKeys?.length === 0
                ? undefined
                : hunkAnchor(hunk, hunkKey(file, index, hunkIndex), file, edit.numbered);
            return at ? [{ side: at.side, lineNumber: at.lineNumber, metadata: { anchor: at.metadata } }] : [];
          })
        : []),
      ...placed.map((thread) => ({ side: thread.side, lineNumber: thread.line!, metadata: { thread } })),
    ],
    [reviewing, staging, edit, file, index, placed],
  );
  const options = useMemo(
    () => ({
      theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
      themeType: paneThemeType(),
      diffStyle: layout,
      diffIndicators: "bars" as const,
      hunkSeparators: "line-info" as const,
      // Word-level marks inside changed lines, unless the edit rewrote whole lines (intraline).
      lineDiffType,
      overflow: wrap ? ("wrap" as const) : ("scroll" as const),
      // A fragment edit has no known place in its file, so its numbers would be made up.
      disableLineNumbers: !edit.numbered,
      // The bundled page allows no WebAssembly.
      preferredHighlighter: "shiki-js" as const,
      disableFileHeader: true,
      unsafeCSS: diffUnsafeCSS,
      onPostRender: afterRender,
    }),
    [layout, wrap, edit.numbered, afterRender, lineDiffType],
  );
  // The header sits outside Pierre's diff, so collapsing or marking a file keeps the same
  // header node and the button the reader pressed keeps focus.
  const header = <FileHeader file={file} kind={kind} edit={edit} index={index} view={view} on={on} review={review} />;
  const showDiff = !view.collapsed && edit.hunks.length > 0;
  return (
    <div
      ref={box}
      className="acpmux-diff-file"
      data-path={file.path}
      data-collapsed={view.collapsed ? "" : undefined}
      data-whole-file={wholeFile ? "" : undefined}
    >
      {header}
      {!view.collapsed && edit.hunks.length === 0 && (
        <div className="acpmux-diff-empty-edit">
          {file.binary ? t("changes.binaryNotShown") : t("changes.noLineChanges")}
        </div>
      )}
      {!view.collapsed && unplaced.length > 0 && (
        <div className="acpmux-review-unplaced">
          {unplaced.map((thread) => (
            <ReviewThread key={threadId(thread)} thread={thread} address={addressOf(thread)} />
          ))}
        </div>
      )}
      {showDiff && (
        <WorkerPoolContext.Provider value={workerPool}>
          <FileDiff<AnnotationOf>
            className="acpmux-diff-pierre"
            fileDiff={fileDiff}
            options={options}
            lineAnnotations={annotations}
            renderAnnotation={(annotation) => {
              if (annotation.metadata?.thread)
                return (
                  <ReviewThread thread={annotation.metadata.thread} address={addressOf(annotation.metadata.thread)} />
                );
              const anchor = annotation.metadata?.anchor;
              const hunk = edit.hunks.find((_, hunkIndex) => hunkKey(file, index, hunkIndex) === anchor?.key);
              if (staging && on.stageHunk && anchor && hunk) {
                const { unstage, run } = on.stageHunk;
                return <HunkStage anchor={anchor} unstage={unstage} onPress={() => run(file.path, hunk)} />;
              }
              return review && focusAfter && anchor ? (
                <HunkActions
                  anchor={anchor}
                  decision={
                    anchor.keys.length > 0 &&
                    anchor.keys.every((key) => review.decisions.get(key) === review.decisions.get(anchor.keys[0]!))
                      ? review.decisions.get(anchor.keys[0]!)
                      : undefined
                  }
                  onDecide={(decision) => anchor.keys.forEach((key) => review.decide(key, decision))}
                  focusAfter={focusAfter}
                />
              ) : null;
            }}
          />
        </WorkerPoolContext.Provider>
      )}
    </div>
  );
}
