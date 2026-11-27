import { intl } from "../../../ui/intl";
// Made on the first long preview, not while the pane's modules evaluate ahead of its handshake.
let graphemes: Intl.Segmenter | undefined;
const PREVIEW_LIMIT = 240;

/// Keep the preview within its existing UTF-16 budget without splitting the last visible character.
export function clipMessagePreview(line: string): string {
  const text = line.replace(/\s+/g, " ").trim();
  if (text.length <= PREVIEW_LIMIT) return text;
  const end = (graphemes ??= intl.Segmenter(undefined, { granularity: "grapheme" }))
    .segment(text)
    .containing(PREVIEW_LIMIT)!.index;
  return text.slice(0, end);
}
