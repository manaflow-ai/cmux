import type { FileDiffMetadata } from "@pierre/diffs";
import type { DiffViewerLabelResolver } from "./labels";

/**
 * File-type badge for the header, derived from the file extension (Graphite
 * shows the language next to the path). Deliberately the uppercased extension
 * rather than a friendly language name: an extension like `TSX`/`TS`/`SWIFT` is
 * a universal, locale-independent file-type code (the same in every UI
 * language), so it needs no localization. Returns "" for extensionless files
 * (e.g. `Makefile`) so they don't get a noisy badge.
 */
export function diffFileLanguageLabel(fileDiff: FileDiffMetadata): string {
  const name = fileDiff.name ?? "";
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

/**
 * Graphite-style file header: a muted directory prefix with an emphasized
 * filename, a language badge, and +N/-N counts. Rendered by @pierre/diffs'
 * `renderCustomHeader` prop (a React node portaled into the virtualized file's
 * `<slot name="header-custom">`), so it lives in the light DOM and its styles
 * live in `styles.css` alongside the rest of the diff-viewer chrome.
 */
export function DiffFileHeader({
  fileDiff,
  label,
}: {
  fileDiff: FileDiffMetadata;
  label?: DiffViewerLabelResolver;
}) {
  const name = fileDiff.name ?? "";
  const slash = name.lastIndexOf("/");
  const directory = slash >= 0 ? name.slice(0, slash + 1) : "";
  const filename = slash >= 0 ? name.slice(slash + 1) : name;
  const badge = diffFileLanguageLabel(fileDiff);
  const { additions, deletions } = diffFileLineTotals(fileDiff);
  const title = fileDiff.prevName ? `${fileDiff.prevName} → ${name}` : name;

  return (
    <div className="cmux-fileheader">
      <span className="cmux-fileheader-path" title={title}>
        {directory ? <span className="cmux-fileheader-dir">{directory}</span> : null}
        <span className="cmux-fileheader-name">{filename}</span>
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
      </span>
    </div>
  );
}
