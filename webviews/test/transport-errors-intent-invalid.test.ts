// The pane's host refuses a malformed request with `transport.intent_invalid` (the Swift host
// checks every frame: .cmux-scratch/pane-protocol/pane-native-transport-review.md). That is the
// pane's bug, never the person's, so the text says what happened in plain words and what to do,
// without the pane's plumbing ("the pane sent a request the app does not accept", Leo's live
// report 2026-10-21). The refusal itself goes to the console for a developer.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { errorMessage } from "../src/agent-session/acpmux/transportErrors";

test("a malformed-request refusal reads as plain words with one action", () => {
  const logged: unknown[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void logged.push(args);
  let text: string;
  try {
    text = errorMessage(Object.assign(new Error("intent invalid"), { code: "transport.intent_invalid" }));
  } finally {
    console.error = original;
  }
  expect(text).toBe(translate("transport.intentInvalid"));
  // No plumbing words: what happened, then the one thing to do.
  for (const jargon of [/\brequest\b/i, /\bpane\b/i, /\baccept/i, /intent/i]) expect(text).not.toMatch(jargon);
  expect(text.endsWith(translate("question.replyFailed").split(". ").pop()!)).toBe(true);
  expect(logged).toHaveLength(1);
});
