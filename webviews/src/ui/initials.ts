function makeSegmenter(): Intl.Segmenter | undefined {
  try {
    return typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
      ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
      : undefined;
  } catch {
    return undefined;
  }
}

const segmenter = makeSegmenter();

function* characters(text: string): IterableIterator<string> {
  if (segmenter) {
    for (const part of segmenter.segment(text)) yield part.segment;
  } else {
    yield* Array.from(text);
  }
}

/** Whole graphemes when supported; otherwise code points, never split surrogate pairs. */
export function graphemePrefix(text: string, count: number): string {
  let prefix = "";
  for (const character of characters(text)) {
    if (count-- <= 0) break;
    prefix += character;
  }
  return prefix;
}

/** Up to two initials; callers choose whether to limit before or after uppercasing. */
export function initials(name: string, count = 2): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const letters =
    words.length > 1
      ? [graphemePrefix(words[0]!, 1), graphemePrefix(words[1]!, 1)]
      : Array.from(characters(graphemePrefix(words[0] ?? "?", 2)));
  return letters.slice(0, count).join("").toUpperCase();
}
