import type { FileDiffMetadata } from "@pierre/diffs";
import type { KeyboardEvent } from "react";
import { fileName } from "./diff-stream";
import { Icon } from "./icons";
import type { DiffViewerLabelResolver } from "./labels";

type DiffFileHeaderMetadata = FileDiffMetadata & {
  newName?: string;
  oldName?: string;
};

/**
 * File-type badge for the header, derived from the file extension (Graphite
 * shows the language next to the path). Deliberately the uppercased extension
 * rather than a friendly language name: an extension like `TSX`/`TS`/`SWIFT` is
 * a universal, locale-independent file-type code (the same in every UI
 * language), so it needs no localization. Returns "" for extensionless files
 * (e.g. `Makefile`) so they don't get a noisy badge.
 */
export function diffFileLanguageLabel(fileDiff: FileDiffMetadata): string {
  const name = fileName(fileDiff, "");
  const slash = name.lastIndexOf("/");
  const dot = name.lastIndexOf(".");
  // Only a real trailing ".ext" on the basename counts (ignore dotfiles like
  // `.gitignore` and dots inside directory names).
  if (dot <= slash + 1 || dot >= name.length - 1) {
    return "";
  }
  const extension = name.slice(dot + 1);
  if (extension.length > 5 || !/^[a-z0-9]+$/i.test(extension)) {
    return "";
  }
  return extension.toUpperCase();
}

export function diffFileLineTotals(fileDiff: FileDiffMetadata): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;
  for (const hunk of fileDiff.hunks ?? []) {
    additions += hunk.additionLines ?? 0;
    deletions += hunk.deletionLines ?? 0;
  }
  return { additions, deletions };
}

function renderPath(path: string) {
  const slash = path.lastIndexOf("/");
  const directory = slash >= 0 ? path.slice(0, slash + 1) : "";
  const filename = slash >= 0 ? path.slice(slash + 1) : path;

  return (
    <>
      {directory ? <span className="cmux-fileheader-dir">{directory}</span> : null}
      <span className="cmux-fileheader-name">{filename}</span>
    </>
  );
}

function isInteractiveHeaderTarget(target: EventTarget | null, currentTarget: HTMLElement): boolean {
  if (target === currentTarget) {
    return false;
  }
  const element = target as Element | null;
  return typeof element?.closest === "function" &&
    Boolean(element.closest("a, button, input, select, textarea, [contenteditable='true'], [role='button']"));
}

/**
 * Graphite-style file header: a muted directory prefix with an emphasized
 * filename, a language badge, and +N/-N counts. Rendered by @pierre/diffs'
 * `renderCustomHeader` prop (a React node portaled into the virtualized file's
 * `<slot name="header-custom">`), so it lives in the light DOM and its styles
 * live in `styles.css` alongside the rest of the diff-viewer chrome.
 */
export function DiffFileHeader({
  collapsed = false,
  fileDiff,
  label,
  onOpenInTab,
  onToggleCollapsed,
}: {
  collapsed?: boolean;
  fileDiff: FileDiffMetadata;
  label?: DiffViewerLabelResolver;
  onOpenInTab?: () => void;
  onToggleCollapsed?: () => void;
}) {
  const metadata = fileDiff as DiffFileHeaderMetadata;
  const name = fileName(metadata, "");
  const rawPreviousName = metadata.prevName ?? metadata.oldName;
  const previousName = rawPreviousName && rawPreviousName !== name ? rawPreviousName : undefined;
  const badge = diffFileLanguageLabel(fileDiff);
  const { additions, deletions } = diffFileLineTotals(fileDiff);
  const title = previousName ? `${previousName} → ${name}` : name;
  const toggleLabel = collapsed ? label?.("expandFileDiff") : label?.("collapseFileDiff");
  const toggleProps = onToggleCollapsed
    ? {
      "aria-expanded": !collapsed,
      "aria-label": toggleLabel,
      onClick: onToggleCollapsed,
      onKeyDown: (event: KeyboardEvent<HTMLDivElement>) => {
        if (isInteractiveHeaderTarget(event.target, event.currentTarget)) {
          return;
        }
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        event.preventDefault();
        onToggleCollapsed();
      },
      role: "button",
      tabIndex: 0,
      title: toggleLabel,
    }
    : {};

  return (
    <div className="cmux-fileheader" data-collapsed={collapsed ? "true" : "false"} {...toggleProps}>
      <span className="cmux-fileheader-main">
        <span className="cmux-fileheader-caret" aria-hidden="true">
          <Icon name="chevronDown" />
        </span>
        <span className={`cmux-fileheader-path${previousName ? " cmux-fileheader-path-renamed" : ""}`} title={title}>
          {previousName ? (
            <>
              <span className="cmux-fileheader-path-part cmux-fileheader-path-old">{renderPath(previousName)}</span>
              <span className="cmux-fileheader-rename-arrow" aria-hidden="true">
                →
              </span>
              <span className="cmux-fileheader-path-part cmux-fileheader-path-new">{renderPath(name)}</span>
            </>
          ) : (
            renderPath(name)
          )}
        </span>
      </span>
      <span className="cmux-fileheader-meta">
        {badge ? <span className="cmux-fileheader-lang">{badge}</span> : null}
        {additions > 0 ? (
          <span className="cmux-fileheader-add" title={label?.("additions")}>
            {`+${additions}`}
          </span>
        ) : null}
        {deletions > 0 ? (
          <span className="cmux-fileheader-del" title={label?.("deletions")}>
            {`−${deletions}`}
          </span>
        ) : null}
        {onOpenInTab ? (
          <button
            type="button"
            className="cmux-fileheader-open"
            title={label?.("openFileDiffInTab")}
            aria-label={label?.("openFileDiffInTab")}
            onClick={(event) => {
              event.stopPropagation();
              onOpenInTab();
            }}
          >
            <Icon name="openTab" />
          </button>
        ) : null}
      </span>
    </div>
  );
}
