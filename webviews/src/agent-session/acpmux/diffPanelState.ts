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
const legacyFingerprints = new WeakMap<object, string>();
let unknownBinaryIdentity = 0;

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
    file.blobFingerprint ??
    (file.binary && file.patch === undefined
      ? `binary:session-${++unknownBinaryIdentity}`
      : file.patch === undefined
        ? hunkFingerprint(file)
        : (blobFingerprint(file.patch) ?? patchFingerprint(file.patch)));
  fingerprints.set(file, value);
  return value;
}

/** The old pane identity, accepted only as a compatibility fingerprint for existing marks. */
export function legacyDiffFileFingerprint(file: TurnFile): string | undefined {
  if (file.binary && file.blobFingerprint === undefined) return undefined;
  const cached = legacyFingerprints.get(file);
  if (cached !== undefined) return cached;
  const value = hunkFingerprint(file);
  legacyFingerprints.set(file, value);
  return value;
}

export function diffFileViewedState(entry: ViewedFileEntry | undefined, file: TurnFile): ViewedFileState {
  if (entry === undefined) return "unviewed";
  const fingerprint = diffFileFingerprint(file);
  if (entry.fingerprint === fingerprint) return "viewed";
  return viewedFileState(entry, fingerprint, legacyDiffFileFingerprint(file));
}

export function viewedSourceKey(scope: ChangeScope, base?: string): string {
  if (scope === "uncommitted") return "branch:HEAD";
  if (scope === "branch") return `branch:${base ?? "HEAD"}`;
  return scope;
}

export function nextViewedRequest(generations: Map<string, number>, scopeKey: string): number {
  const next = (generations.get(scopeKey) ?? 0) + 1;
  generations.set(scopeKey, next);
  return next;
}

export function isCurrentViewedRequest(
  generations: ReadonlyMap<string, number>,
  scopeKey: string,
  requestId: number,
): boolean {
  return generations.get(scopeKey) === requestId;
}

export function observeDiffPanelSize(node: HTMLElement, onWidth: (width: number) => void): () => void {
  if (typeof ResizeObserver === "undefined") return () => {};
  const measure = () => onWidth(Math.round(node.getBoundingClientRect().width));
  measure();
  const observer = new ResizeObserver(measure);
  observer.observe(node);
  return () => observer.disconnect();
}
