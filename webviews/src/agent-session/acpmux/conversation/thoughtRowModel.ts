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
  /// Whether the closed row's one line holds more than it shows: its words wrap past the line it is
  /// cut to (`-webkit-line-clamp`), or run past its end.
  cut: (node: HTMLElement) => node.scrollHeight > node.clientHeight + 1 || node.scrollWidth > node.clientWidth + 1,
};

export type ThoughtHeader = "duration" | "preview";
export type ThoughtFoldThreshold = "every" | "viewport" | "codex";

/// The most of a thought's line its button gives as its name: short enough for a screen reader to
/// read (one unbroken line can be thousands of characters).
export const THOUGHT_LINE_CHARS = 240;

/// The row button's name when its line is longer than THOUGHT_LINE_CHARS: the line's start, cut with
/// an ellipsis. A shorter line names the button itself.
export function thoughtName(line: string): string | undefined {
  return line.length > THOUGHT_LINE_CHARS ? `${line.slice(0, THOUGHT_LINE_CHARS).trimEnd()}\u2026` : undefined;
}

/// A thought's row line and what opens under it (Leo, 2026-11-22: "what if instead of Thought blah
/// blah we simply... had the whole line be the line? then you expand and it simply shows you the
/// rest"). The line is the thought's own first line: a heading's words (`title`), else the text up
/// to its first break, as it draws in the whole text, so opening swaps no words. `rest` is every
/// line after it; `gap` says a blank line parted the two.
export type ThoughtHead = { line: string; title: boolean; rest: string; gap: boolean };

export function thoughtHead(text: string): ThoughtHead {
  const lines = text.split("\n");
  let at = 0;
  while (at < lines.length && !lines[at]!.trim()) at += 1;
  const first = lines[at] ?? "";
  const after = lines.slice(at + 1);
  const gap = after.length > 0 && !after[0]!.trim();
  const rest = after
    .join("\n")
    .replace(/^\s*\n/, "")
    .trimEnd();
  const parts = thoughtParts(first);
  const head = parts[0];
  if (head && "title" in head) return { line: head.title, title: true, rest, gap };
  return { line: first.trim(), title: false, rest, gap: gap && rest !== "" };
}
