import type { TurnFile } from "./diff";
import type { ChangeScope } from "./changes/model";
import {
  blobFingerprint,
  patchFingerprint,
  viewedFileState,
  type ViewedFileEntry,
  type ViewedFileState,
} from "../../viewed-files";

const fingerprints = new WeakMap<object, string>();

function hunkFingerprint(file: TurnFile): string {
  const patch = file.edits
    .flatMap((edit) => edit.hunks)
    .map((hunk) => {
      const oldLines = hunk.lines.filter((line) => line.type !== "add");
      const newLines = hunk.lines.filter((line) => line.type !== "del");
      const oldStart = oldLines.find((line) => line.oldLine)?.oldLine ?? 0;
      const newStart = newLines.find((line) => line.newLine)?.newLine ?? 0;
      return [
        `@@ -${oldStart},${oldLines.length} +${newStart},${newLines.length} @@`,
        ...hunk.lines.map((line) => `${line.type === "add" ? "+" : line.type === "del" ? "-" : " "}${line.text}`),
      ].join("\n");
    })
    .join("\n");
  return patchFingerprint(patch || `${file.created ? "new" : file.deleted ? "deleted" : "file"}:${file.displayPath}`);
}

/** The identity stored by the full viewer: blob ids when git supplied a patch, otherwise hunks. */
export function diffFileFingerprint(file: TurnFile): string {
  const cached = fingerprints.get(file);
  if (cached !== undefined) return cached;
  const value =
    file.patch === undefined ? hunkFingerprint(file) : (blobFingerprint(file.patch) ?? patchFingerprint(file.patch));
  fingerprints.set(file, value);
  return value;
}

/** The old pane identity, accepted only as a compatibility fingerprint for existing marks. */
export function legacyDiffFileFingerprint(file: TurnFile): string {
  return hunkFingerprint(file);
}

export function diffFileViewedState(entry: ViewedFileEntry | undefined, file: TurnFile): ViewedFileState {
  return viewedFileState(entry, diffFileFingerprint(file), legacyDiffFileFingerprint(file));
}

export function viewedSourceKey(scope: ChangeScope, base?: string): string {
  if (scope === "uncommitted") return "branch:HEAD";
  if (scope === "branch") return `branch:${base ?? "HEAD"}`;
  return scope;
}

export function observeDiffPanelSize(node: HTMLElement, onWidth: (width: number) => void): () => void {
  if (typeof ResizeObserver === "undefined") return () => {};
  const measure = () => onWidth(Math.round(node.getBoundingClientRect().width));
  measure();
  const observer = new ResizeObserver(measure);
  observer.observe(node);
  return () => observer.disconnect();
}
