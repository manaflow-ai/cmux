// l10n-allow-file: test fixture subagent names and prompts, not shipped UI.
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import { canRestart, restartPrompt } from "./restart";

const ended = { state: "cancelled", parent: null, name: "Reviewer", prompt: "Review src/app.ts" } as const;

test("Restart is offered for a stopped, failed or lost subagent of the chat's own, with its prompt", () => {
  expect(canRestart(ended)).toBe(true);
  expect(canRestart({ ...ended, state: "failed" })).toBe(true);
  expect(canRestart({ ...ended, state: "disconnected" })).toBe(true);
  expect(canRestart({ ...ended, state: "completed" })).toBe(false);
  expect(canRestart({ ...ended, state: "running" })).toBe(false);
  expect(canRestart({ ...ended, parent: "a" })).toBe(false);
  expect(canRestart({ ...ended, prompt: undefined })).toBe(false);
});

test("the prompt asks the agent to run it again with its kind and prompt, as given", () => {
  expect(restartPrompt({ ...ended, kind: "Explore" }, translate)).toBe(
    'Run the Explore subagent "Reviewer" again with the same prompt:\n\nReview src/app.ts',
  );
  expect(restartPrompt({ ...ended, prompt: "Use {name} literally" }, translate)).toBe(
    'Run the subagent "Reviewer" again with the same prompt:\n\nUse {name} literally',
  );
  expect(restartPrompt({ ...ended, state: "completed" }, translate)).toBeUndefined();
});
