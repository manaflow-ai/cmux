// The composer reads the caret's place in the prompt's markdown, and the `@` and `:emoji` word it
// ends, on every render. They used to cost one regex per character before the caret, and to scan the
// whole draft, so a key at the end of a 200,000-character draft spent tens of milliseconds on them.
// They now read the plain runs natively and only the caret's line; each must answer exactly as the
// old reading did.
import { expect, test } from "bun:test";
import { emojiTrigger } from "../src/agent-session/acpmux/emojiShortcodes";
import { markdownOffset, mentionQuery } from "../src/agent-session/acpmux/mentionMenuModel";

/** The reading before: one anchored regex per shown character. */
function markdownOffsetBefore(markdown: string, shown: number): number {
  let index = 0;
  for (let count = 0; count < shown && index < markdown.length; count++) {
    const escape = /^(\\[!-/:-@[-`{-~]|&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);|￼[\w.~%-]+￼)/i.exec(
      markdown.slice(index),
    );
    index += escape ? escape[0].length : 1;
  }
  return index;
}

/** The mention reading before: the whole markdown before the caret. */
function mentionQueryBefore(markdown: string, at: number) {
  const before = markdown.slice(0, at);
  const found = /(^|\s|&#x20;|&#32;|&nbsp;)@((?:\\.|(?!&#x20;|&#32;|&nbsp;)[^\s\\@])*)$/i.exec(before);
  if (!found) return undefined;
  const start = before.length - found[2]!.length - 1;
  if ((before.slice(0, start).match(/`/g)?.length ?? 0) % 2 === 1) return undefined;
  return { start, query: found[2]!.replace(/\\(.)/g, "$1") };
}

const PIECES = [
  "a",
  "b",
  " ",
  "\n",
  "\\",
  "\\_",
  "\\*",
  "\\a",
  "&",
  "&amp;",
  "&#x20;",
  "&#32;",
  "&nbsp;",
  "&x",
  "@",
  "@me",
  ":",
  ":smile",
  ":)",
  "`",
  "```\n",
  "￼",
  "￼id-1￼",
  "￼￼",
  "é",
  "😀",
];

function drafts(): string[] {
  let seed = 11;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const made: string[] = ["", "plain", "a\\_b&amp;c￼x￼d", "line\n@who", "x :smile", "`code :smile"];
  for (let draft = 0; draft < 400; draft++) {
    let text = "";
    const length = 1 + Math.floor(random() * 30);
    for (let piece = 0; piece < length; piece++) text += PIECES[Math.floor(random() * PIECES.length)];
    made.push(text);
  }
  return made;
}

test("the caret's markdown offset is the same as one regex per character gave", () => {
  for (const draft of drafts())
    for (let shown = 0; shown <= draft.length + 2; shown++)
      expect([draft, shown, markdownOffset(draft, shown)]).toEqual([draft, shown, markdownOffsetBefore(draft, shown)]);
});

test("the @ word before the caret, read from its line, is the same as from the whole draft", () => {
  for (const draft of drafts())
    for (let at = 0; at <= draft.length; at++)
      expect([draft, at, mentionQuery(draft, at)]).toEqual([draft, at, mentionQueryBefore(draft, at)]);
});

test("the :emoji word before the caret, read from its line, ends where it did on the whole draft", () => {
  // The old reading, for the start it found: the whole draft before the caret against the same rule.
  const SPACE = /(?:^|\s|&#x20;|&#32;|&nbsp;)((?:\\.|&[a-z]+;|&#x?[0-9a-f]+;|[^\s\\&]|&(?![a-z#]))+)$/i;
  for (const draft of [...drafts(), "words\nmore :smile", "a\n:)", "``` \n:smile"])
    for (let at = 0; at <= draft.length; at++) {
      const found = emojiTrigger(draft, at);
      if (!found) continue;
      const whole = SPACE.exec(draft.slice(0, at));
      expect([draft, at, found.start]).toEqual([draft, at, at - whole![1]!.length]);
    }
});

test("a caret at the end of a 200,000-character draft is read in well under a frame", () => {
  const draft = "composer latency fixture words keep the prompt long \\_ &amp;\n".repeat(3300);
  const started = performance.now();
  for (let key = 0; key < 20; key++) {
    const at = markdownOffset(draft, draft.length);
    mentionQuery(draft, at);
    emojiTrigger(draft, at);
  }
  expect((performance.now() - started) / 20).toBeLessThan(12);
});
