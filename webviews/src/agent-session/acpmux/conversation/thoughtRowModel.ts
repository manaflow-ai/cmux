import { thoughtDuration, thoughtParts } from "./thoughts";

export { thoughtDuration, thoughtParts };

/// A long thought still streaming holds a viewport this tall: seven of its 20px lines, the 8.75rem
/// Codex gives a live reasoning trace. conversation.css caps `.is-live` at the same. With the Debug
/// choice "viewport" or "codex" a done thought folds once taller than this; by default ("every")
/// every done thought folds.
export const THOUGHT_LIVE_PX = 140;

/// What the row reads from the page; tests swap these.
export const thoughtLayout = {
  /// The Debug choice `agentPane.debug.thoughtFoldThreshold`: by default ("every") every done
  /// thought folds. `data-thought-fold-threshold="viewport"` or `"codex"` brings back the older
  /// fold of long thoughts only, a short one in full after "Thought": once taller than Codex's
  /// seven lines (THOUGHT_LIVE_PX), the live viewport a long thought streamed in.
  threshold: (): ThoughtFoldThreshold => {
    const value = typeof document === "undefined" ? undefined : document.documentElement.dataset.thoughtFoldThreshold;
    return value === "viewport" || value === "codex" ? value : "every";
  },
  /// The Debug choice `agentPane.debug.thoughtHeader`: a folded thought reads "Thought for 12s"
  /// unless the app sets `data-thought-header="preview"`, "Thought" and its first line (#20948).
  header: (): ThoughtHeader =>
    typeof document !== "undefined" && document.documentElement.dataset.thoughtHeader === "preview"
      ? "preview"
      : "duration",
  height: (node: HTMLElement) => node.getBoundingClientRect().height,
  /// The text's whole height, also while the live viewport clips it.
  contentHeight: (node: HTMLElement) => node.scrollHeight,
};

export type ThoughtHeader = "duration" | "preview";
export type ThoughtFoldThreshold = "every" | "viewport" | "codex";

/// The folded line's text: the thought's first line without Codex's heading marks (`#`, `**`).
export function thoughtPreview(text: string): string {
  return (text.split("\n", 1)[0] ?? "")
    .replace(/^#+\s*/, "")
    .replace(/\*\*/g, "")
    .trim();
}
