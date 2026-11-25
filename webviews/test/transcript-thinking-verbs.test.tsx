// l10n-allow-file: test fixture text, not shipped UI.
// Leo (2026-11-04), on the Claude Code CLI's spinner verbs: "instead of just always saying thinking
// all the time. I feel like it's got a little spunk, a little personality to it". The live line reads
// one playful verb per turn where the pane gives verbs (English), and "Thinking" where it gives none.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
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
  const verb = thinkingVerb(THINKING_VERBS, "u-1")!;
  expect(THINKING_VERBS).toContain(verb);
  expect(drawn(THINKING_VERBS, { since: 1_000, verbKey: "u-1", now: () => 13_000 })).toBe(`${verb} 12s`);
  // The same word while its agent starts, so nothing changes from send to the first output.
  expect(drawn(THINKING_VERBS, { starting: true, since: 1_000, verbKey: "u-1", now: () => 13_000 })).toBe(
    `${verb} 12s`,
  );
});

test("the turn keeps its verb when its prompt's time moves (the echo, a clock offset, a retry)", () => {
  const verb = thinkingVerb(THINKING_VERBS, "u-1")!;
  expect(drawn(THINKING_VERBS, { since: 1_000, verbKey: "u-1", now: () => 13_000 })).toStartWith(verb);
  expect(drawn(THINKING_VERBS, { since: 1_437, verbKey: "u-1", now: () => 13_000 })).toStartWith(verb);
  // The live row carries its prompt's id, pending or echoed back with the daemon's time.
  const prompt: AcpmuxRow = { id: "u-1", kind: "user", version: 1, at: 1_000, text: "Why?", pending: true };
  const live = (rows: AcpmuxRow[], working: boolean) =>
    turnView(rows, new Set(), { working, now: 2_000 }).find((entry) => entry.kind === THINKING);
  expect(live([prompt], false)?.verbKey).toBe("u-1");
  expect(live([{ ...prompt, pending: undefined, at: 1_437 }], true)?.verbKey).toBe("u-1");
});

test("one verb for the whole turn, and turns get different ones", () => {
  expect(thinkingVerb(THINKING_VERBS, "u-7")).toBe(thinkingVerb(THINKING_VERBS, "u-7"));
  const picked = new Set(Array.from({ length: 40 }, (_, turn) => thinkingVerb(THINKING_VERBS, `optimistic-${turn}`)));
  expect(picked.size).toBeGreaterThan(10);
});

test("with no verbs, or no turn to key them, the line reads Thinking", () => {
  expect(drawn(undefined, { since: 1_000, verbKey: "u-1", now: () => 13_000 })).toBe("Thinking 12s");
  expect(drawn(THINKING_VERBS, { untimed: true })).toBe("Thinking");
});

test("a step in flight still names the step, never the verb", () => {
  expect(
    drawn(THINKING_VERBS, { since: 1_000, verbKey: "u-1", doing: "cargo test", doingShell: true, now: () => 4_000 }),
  ).toStartWith("Running");
});

test("English gets the verbs; another language keeps its own word for Thinking", () => {
  expect(thinkingVerbsFor("en")).toBe(THINKING_VERBS);
  expect(thinkingVerbsFor("en-GB")).toBe(THINKING_VERBS);
  expect(thinkingVerbsFor("ja")).toBeUndefined();
});
