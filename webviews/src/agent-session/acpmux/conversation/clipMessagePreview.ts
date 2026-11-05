const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const PREVIEW_LIMIT = 240;

/// Keep the preview within its existing UTF-16 budget without splitting the last visible character.
export function clipMessagePreview(line: string): string {
  const text = line.replace(/\s+/g, " ").trim();
  if (text.length <= PREVIEW_LIMIT) return text;
  const end = graphemes.segment(text).containing(PREVIEW_LIMIT)!.index;
  return text.slice(0, end);
}
