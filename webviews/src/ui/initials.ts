import { intl } from "./intl";
// Whether the engine has a segmenter is read as the module loads; the segmenter itself is made later.
const hasSegmenter = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function";

function makeSegmenter(): Intl.Segmenter | undefined {
  try {
    return hasSegmenter ? intl.Segmenter(undefined, { granularity: "grapheme" }) : undefined;
  } catch {
    return undefined;
  }
}

// Made on the first initials, not while the pane's modules evaluate ahead of its handshake: the
// first grapheme segmenter a page makes loads the engine's break data, the agent pane's largest
// single cost in module evaluation (scripts/measure/pane-handshake-eval.mjs --profile).
let segmenter: Intl.Segmenter | undefined;
let made = false;

function* characters(text: string): IterableIterator<string> {
  if (!made) {
    made = true;
    segmenter = makeSegmenter();
  }
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
