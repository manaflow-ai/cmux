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
  /// The Debug choice `agentPane.debug.thoughtHeader`: an opened thought reads "Thought for 12s"
  /// unless the app sets `data-thought-header="preview"`, "Thought" alone (#20948). Folded, it
  /// reads its words either way.
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

/// The most of a thought its closed row holds: more than the widest row shows, and short enough to
/// be the button's name a screen reader reads (a thought can be thousands of characters).
export const THOUGHT_LINE_CHARS = 240;

/// One line of a thought's words for its closed row: every line without Codex's heading marks, its
/// breaks as spaces, at most THOUGHT_LINE_CHARS; the row cuts it with an ellipsis.
export function thoughtLine(text: string): string {
  // Only the start of a long thought is read: the line never needs more.
  const line = text
    .slice(0, THOUGHT_LINE_CHARS * 4)
    .split("\n")
    .map(thoughtPreview)
    .filter(Boolean)
    .join(" ");
  return line.length > THOUGHT_LINE_CHARS ? `${line.slice(0, THOUGHT_LINE_CHARS).trimEnd()}\u2026` : line;
}

/// The folded line's text: the thought's first line without Codex's heading marks (`#`, `**`).
export function thoughtPreview(text: string): string {
  return (text.split("\n", 1)[0] ?? "")
    .replace(/^#+\s*/, "")
    .replace(/\*\*/g, "")
    .trim();
}
