import { type Option } from "./model";

/// The option whose preview shows: the first of `rows` (the hovered row, then the highlighted one)
/// that has a preview, else the first option with one. The Other row has none.
export function shownPreview(options: Option[], rows: (number | undefined)[]): Option | undefined {
  for (const row of rows) {
    const option = row === undefined ? undefined : options[row];
    if (option?.preview) return option;
  }
  return options.find((option) => option.preview);
}

/// A preview's text as Claude Code draws it, Markdown in a monospace box: an agent often wraps its
/// mockup or code in a fence, which the box stands for, so the fence lines go (a fence and its info
/// string alone on a line, never a line with an inline code span) and the rest keeps every space
/// and line break (ASCII mockups line up only that way).
export function previewText(text: string): string {
  return text
    .split("\n")
    .filter((line) => !/^\s*(`{3,}|~{3,})[^`~]*$/.test(line))
    .join("\n")
    .replace(/^\n+|\s+$/g, "");
}
