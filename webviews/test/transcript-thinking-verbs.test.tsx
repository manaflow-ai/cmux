// l10n-allow-file: test fixture text, not shipped UI.
// Leo (2026-11-04), on the Claude Code CLI's spinner verbs: "instead of just always saying thinking
// all the time. I feel like it's got a little spunk, a little personality to it". The live line reads
// one playful verb per turn where the pane gives verbs (English), and "Thinking" where it gives none.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import {
  THINKING_VERBS,
  thinkingVerb,
  thinkingVerbsFor,
  ThinkingVerbsContext,
} from "../src/agent-session/acpmux/conversation/thinkingVerbs";

const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const drawn = (verbs: readonly string[] | undefined, line: Parameters<typeof Thinking>[0]) =>
  text(
    renderToStaticMarkup(
      <ThinkingVerbsContext.Provider value={verbs}>
        <Thinking {...line} />
      </ThinkingVerbsContext.Provider>,
    ),
  );

test("the live line says the turn's verb, not Thinking, where the pane gives verbs", () => {
  const verb = thinkingVerb(THINKING_VERBS, 1_000)!;
  expect(THINKING_VERBS).toContain(verb);
  expect(drawn(THINKING_VERBS, { since: 1_000, now: () => 13_000 })).toBe(`${verb} 12s`);
  // The same word while its agent starts, so nothing changes from send to the first output.
  expect(drawn(THINKING_VERBS, { starting: true, since: 1_000, now: () => 13_000 })).toBe(`${verb} 12s`);
});

test("one verb for the whole turn, and turns get different ones", () => {
  const since = 1_762_216_819_219;
  expect(thinkingVerb(THINKING_VERBS, since)).toBe(thinkingVerb(THINKING_VERBS, since));
  const picked = new Set(Array.from({ length: 40 }, (_, turn) => thinkingVerb(THINKING_VERBS, since + turn * 7_000)));
  expect(picked.size).toBeGreaterThan(10);
});

test("with no verbs, or no prompt time, the line reads Thinking", () => {
  expect(drawn(undefined, { since: 1_000, now: () => 13_000 })).toBe("Thinking 12s");
  expect(drawn(THINKING_VERBS, { untimed: true })).toBe("Thinking");
});

test("a step in flight still names the step, never the verb", () => {
  expect(drawn(THINKING_VERBS, { since: 1_000, doing: "cargo test", doingShell: true, now: () => 4_000 })).toStartWith(
    "Running",
  );
});

test("English gets the verbs; another language keeps its own word for Thinking", () => {
  expect(thinkingVerbsFor("en")).toBe(THINKING_VERBS);
  expect(thinkingVerbsFor("en-GB")).toBe(THINKING_VERBS);
  expect(thinkingVerbsFor("ja")).toBeUndefined();
});
