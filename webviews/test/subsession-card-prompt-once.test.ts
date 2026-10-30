// l10n-allow-file: test fixtures.
// A sub-session's card showed its prompt's opening words twice: once as its `doing` line (acpmux names a
// fresh session from its prompt) and again as the start of the prompt preview right under it. Leo,
// 2026-10-29: "this doubling up is kinda weird? first line then whatever goes next". The line is left
// out when it only repeats the prompt's start; any other line (a real step, a wait, an error) stays.
import { expect, test } from "bun:test";
import { repeatsPrompt, sessionLine } from "../src/agent-session/acpmux/conversation/SubsessionCallCard";

const prompt =
  "You are ios-remote, the area owner for cmux's iOS app and the remote/mobile client (the cmux-remote code, including its Iroh transport), in example/cmux.";

test("a line that is the prompt's opening, cut mid-word with an ellipsis, repeats it", () => {
  expect(
    repeatsPrompt(
      "You are ios-remote, the area owner for cmux's iOS app and the remote/mobile client (the cmux-remote code, includi…",
      prompt,
    ),
  ).toBe(true);
  expect(repeatsPrompt("You are ios-remote, the area owner...", prompt)).toBe(true);
  expect(repeatsPrompt("you  are   IOS-remote,", prompt)).toBe(true);
});

test("a line that says what the session does now is not a repeat", () => {
  expect(repeatsPrompt("Read src/net/RetryBanner.tsx", prompt)).toBe(false);
  expect(repeatsPrompt("You are net-retries, a lane", prompt)).toBe(false);
  expect(repeatsPrompt("", prompt)).toBe(false);
});

test("only a line that ends in an ellipsis may stop mid-word", () => {
  // A real step whose last word is a prefix of the prompt's word is a step, not a cut repeat.
  expect(repeatsPrompt("Fix bug", "Fix bugs in parser")).toBe(false);
  expect(repeatsPrompt("Fix bug\u2026", "Fix bugs in parser")).toBe(true);
  expect(repeatsPrompt("Fix bugs in parser", "Fix bugs in parser and lexer")).toBe(true);
  expect(repeatsPrompt("Fix bugs in parser and more", "Fix bugs in parser")).toBe(false);
});

test('acpmux\'s "Working on: <prompt>" line repeats the prompt (hub/subsession_send.rs)', () => {
  expect(repeatsPrompt("Working on: You are ios-remote, the area owner for cmux's iOS app\u2026", prompt)).toBe(true);
  expect(repeatsPrompt("Working on: You are ios-remote\u2026", prompt)).toBe(true);
  // Its prefix never makes another session's line a repeat.
  expect(repeatsPrompt("Working on: You are net-retries\u2026", prompt)).toBe(false);
  expect(repeatsPrompt("Working on: Read src/net/RetryBanner.tsx", prompt)).toBe(false);
});

test('a prompt that itself starts with "Working on:" is still recognized when the line is the raw prompt', () => {
  const own = "Working on: inspect the parser and report what breaks.";
  expect(repeatsPrompt("Working on: inspect the parser\u2026", own)).toBe(true);
  expect(repeatsPrompt("Working on: inspect the parser and report what breaks.", own)).toBe(true);
  // And acpmux's prefix on top of such a prompt.
  expect(repeatsPrompt("Working on: Working on: inspect the parser\u2026", own)).toBe(true);
  expect(repeatsPrompt("Working on: fix the lexer", own)).toBe(false);
});

test("a failed session's error stays even when it starts like the prompt", () => {
  // Codex review of #27240: the dedupe hid an error "Run tests" under the prompt "Run tests for parser",
  // leaving only the bare failed state.
  expect(sessionLine(undefined, "Run tests", true, "Run tests for parser")).toBe("Run tests");
  expect(sessionLine(undefined, "Run tests for parser\u2026", true, "Run tests for parser")).toBe(
    "Run tests for parser\u2026",
  );
  // A doing line that repeats the prompt gives way to the error when the session failed.
  expect(sessionLine("Run tests\u2026", "exit 1: no such target", true, "Run tests for parser")).toBe(
    "exit 1: no such target",
  );
});

test("only a doing line that repeats the prompt is left out", () => {
  expect(sessionLine("Run tests\u2026", undefined, false, "Run tests for parser")).toBeUndefined();
  expect(sessionLine("Read src/parser.ts", undefined, false, "Run tests for parser")).toBe("Read src/parser.ts");
  expect(sessionLine("Run tests\u2026", undefined, false)).toBe("Run tests\u2026");
  // A working session's error is not its line.
  expect(sessionLine(undefined, "stale error", false, "Run tests for parser")).toBeUndefined();
});
