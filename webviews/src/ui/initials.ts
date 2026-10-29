const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** A prefix of whole visible characters, including combining marks and joined emoji. */
export function graphemePrefix(text: string, count: number): string {
  let prefix = "";
  for (const part of segmenter.segment(text)) {
    if (count-- <= 0) break;
    prefix += part.segment;
  }
  return prefix;
}

/** Up to two initials; callers choose whether to limit before or after uppercasing. */
export function initials(name: string, count = 2): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const letters =
    words.length > 1
      ? [graphemePrefix(words[0]!, 1), graphemePrefix(words[1]!, 1)]
      : Array.from(segmenter.segment(graphemePrefix(words[0] ?? "?", 2)), (part) => part.segment);
  return letters.slice(0, count).join("").toUpperCase();
}
