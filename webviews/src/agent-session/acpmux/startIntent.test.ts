// Leo: "select the thing and then start the thing". A start a sign-in got in the way of waits
// with its agent, model, machine and folder, and goes once, on Start, with the newest draft.
import { expect, test } from "bun:test";
import { captureStartIntent, intentPrompt, intentStillApplies, takeStartIntent } from "./startIntent";

const target = { harness: "codex", host: "devbox", folder: "/work/app" };

test("the held start keeps the chosen agent, model, machine and folder", () => {
  expect(captureStartIntent(target, "gpt-5", "fix it", "signIn")).toEqual({
    harness: "codex",
    model: "gpt-5",
    host: "devbox",
    folder: "/work/app",
    draft: "fix it",
    reason: "signIn",
  });
  expect(captureStartIntent({}, "gpt-5", "x", "signIn")).toBeUndefined();
});

test("a newer draft typed during the repair wins; an empty field sends the held one", () => {
  const intent = captureStartIntent(target, undefined, "old words", "signIn")!;
  expect(intentPrompt(intent, "  new words ")).toBe("new words");
  expect(intentPrompt(intent, "   ")).toBe("old words");
});

test("another agent, machine or folder picked since drops the held start", () => {
  const intent = captureStartIntent(target, undefined, "", "signIn")!;
  expect(intentStillApplies(intent, target)).toBe(true);
  expect(intentStillApplies(intent, { ...target, harness: "claude" })).toBe(false);
  expect(intentStillApplies(intent, { ...target, host: undefined })).toBe(false);
  expect(intentStillApplies(intent, { ...target, folder: "/elsewhere" })).toBe(false);
});

test("Start takes the intent once: a second Start sends nothing", () => {
  const slot = { current: captureStartIntent(target, undefined, "go", "signIn") };
  expect(takeStartIntent(slot)?.draft).toBe("go");
  expect(takeStartIntent(slot)).toBeUndefined();
});
