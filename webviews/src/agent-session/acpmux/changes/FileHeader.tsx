// One edit's header in the changes view: name, badges, counts and the viewed toggle. It sits
// outside Pierre's diff so collapsing or marking a file keeps the focused button.
import React from "react";
import type { DiffEdit, DiffHunk, TurnFile } from "../diff";
import { ChevronDown, Code, Eye, OpenTab } from "../changeIcons";
import { FileTypeIcon } from "./FileTypeIcon";
import { useT, type StringKey } from "../i18n";
import type { FileKind } from "../../../fileKinds";
import { Counts } from "./Counts";
import { FileMenu } from "./FileMenu";
import { openFileKeys, type HunkDecision, type HunkReview } from "./hunkReview";

/// The kinds' names, as the pull request card and the diff viewer write them. Code is what a
/// person came to read, so it goes unlabelled.
const KIND_LABELS: Record<Exclude<FileKind, "code">, StringKey> = {
  tests: "prCard.kind.tests",
  mocks: "prCard.kind.mocks",
  docs: "prCard.kind.docs",
  evals: "prCard.kind.evals",
  generated: "prCard.kind.generated",
};

export type FileView = { collapsed: boolean; viewed: boolean };
/// Where the host opens a changed file: a tab beside the agent, or the editor app.
export type OpenTarget = "tab" | "editor";
export type FileActions = {
  toggleCollapsed: (path: string) => void;
  toggleViewed: (path: string) => void;
  openFile: (path: string, where: OpenTarget) => void;
  /// Stage (or, in Staged, unstage) a file; absent where the view can't change the index.
  stage?: { unstage: boolean; run: (path: string) => void };
  /// Stage (or, in Staged, unstage) one hunk of a file; absent outside Unstaged and Staged.
  stageHunk?: { unstage: boolean; run: (path: string, hunk: DiffHunk) => void };
  /// Show more lines (changes/wholeFile.ts): the file read with every unchanged line, and its name
  /// from the repository's top; absent outside a git scope.
  wholeFile?: (path: string) => Promise<{ named: string; value: unknown } | undefined>;
};

export function FileHeader({
  file,
  kind = "code",
  edit,
  index,
  view,
  on,
  review,
}: {
  file: TurnFile;
  /// The file's kind (fileKinds.ts); anything but code gets a label, as in the diff viewer.
  kind?: FileKind;
  edit: DiffEdit;
  index: number;
  view: FileView;
  on: FileActions;
  /// The turn's hunk review, where the view has one: the menu decides every change in the file.
  review?: HunkReview;
}) {
  const t = useT();
  const open = review ? openFileKeys(file, review.decisions) : [];
  const decideFile = (decision: HunkDecision) => open.forEach((key) => review?.decide(key, decision));
  const slash = file.displayPath.lastIndexOf("/");
  const additions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "add").length, 0);
  const deletions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "del").length, 0);
  return (
    <div className="acpmux-file-header" data-viewed={view.viewed ? "" : undefined}>
      <FileTypeIcon path={file.displayPath} />
      <button
        type="button"
        className="acpmux-fh-name"
        aria-expanded={!view.collapsed}
        onClick={() => on.toggleCollapsed(file.path)}
      >
        {slash >= 0 && <span className="acpmux-fh-dir">{file.displayPath.slice(0, slash + 1)}</span>}
        <span>{file.displayPath.slice(slash + 1)}</span>
        <ChevronDown className="acpmux-fh-chevron" width={14} height={14} />
      </button>
      {file.created && index === 0 && <span className="acpmux-fh-badge">{t("changes.badgeNew")}</span>}
      {file.deleted && <span className="acpmux-fh-badge">{t("changes.badgeDeleted")}</span>}
      {file.edits.length > 1 && <span className="acpmux-fh-badge">{`Edit ${index + 1} of ${file.edits.length}`}</span>}
      {file.outside && <span className="acpmux-fh-badge acpmux-fh-outside">{t("turn.outside")}</span>}
      {kind !== "code" && (
        <span className="acpmux-fh-badge acpmux-fh-kind" data-kind={kind}>
          {t(KIND_LABELS[kind])}
        </span>
      )}
      <span className="acpmux-fh-spacer" />
      <Counts additions={additions} deletions={deletions} />
      <button
        type="button"
        className="acpmux-fh-btn"
        aria-label={t(view.viewed ? "changes.markNotViewed" : "changes.markViewed", { path: file.displayPath })}
        aria-pressed={view.viewed}
        data-viewed-toggle=""
        onClick={() => on.toggleViewed(file.path)}
      >
        <Eye />
      </button>
      {/* A deleted file has nothing on disk to open. */}
      {!file.deleted && (
        <>
          <button
            type="button"
            className="acpmux-fh-btn"
            aria-label={t("changes.openPathInTab", { path: file.displayPath })}
            title={t("changes.openInTab")}
            onClick={() => on.openFile(file.path, "tab")}
          >
            <OpenTab />
          </button>
          <button
            type="button"
            className="acpmux-fh-btn"
            aria-label={t("changes.openPathInEditor", { path: file.displayPath })}
            title={t("changes.openInEditor")}
            onClick={() => on.openFile(file.path, "editor")}
          >
            <Code />
          </button>
        </>
      )}
      <FileMenu
        path={file.path}
        name={file.displayPath}
        collapsed={view.collapsed}
        onToggleCollapsed={() => on.toggleCollapsed(file.path)}
        onOpenInTab={file.deleted ? undefined : () => on.openFile(file.path, "tab")}
        review={
          open.length > 0
            ? [
                { label: t("hunk.rejectFile"), run: () => decideFile("rejected") },
                { label: t("hunk.acceptFile"), run: () => decideFile("accepted") },
              ]
            : undefined
        }
        stage={
          on.stage && {
            label: t(on.stage.unstage ? "changes.unstageFile" : "changes.stageFile"),
            run: () => on.stage?.run(file.path),
          }
        }
      />
    </div>
  );
}
