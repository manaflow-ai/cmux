// l10n-allow-file: test fixture prompts, not shipped UI.
// What was typed while a Cloud start was out reaches the chat it opens (review of #39877: on success
// the host closes the tab that sent it, and its draft went with it).
import { expect, test } from "bun:test";
import { CARRY_TTL_MS, carriedText, dropCloudCarry, holdCloudCarry, takeCloudCarry } from "./cloudStartCarry";

const memory = () => {
  const items = new Map<string, string>();
  return {
    getItem: (name: string) => items.get(name) ?? null,
    setItem: (name: string, value: string) => void items.set(name, value),
    removeItem: (name: string) => void items.delete(name),
    items,
  };
};

const TASK = "Run the sidebar tests and fix what fails.";

test("only what the draft adds past the sent prompt is carried", () => {
  expect(carriedText(TASK, TASK)).toBe("");
  expect(carriedText(TASK, `${TASK}\n\nalso check the dock`)).toBe("also check the dock");
  expect(carriedText(TASK, "a different prompt")).toBe("a different prompt");
  expect(carriedText(TASK, `${TASK} ￼att_1￼`)).toBe("");
});

test("the Cloud chat seeded with the prompt takes the typed text once", () => {
  const store = memory();
  holdCloudCarry(TASK, `${TASK}\n\nalso check the dock`, 1_000, store);
  expect(takeCloudCarry("another chat's prompt", 2_000, store)).toBeUndefined();
  expect(takeCloudCarry(TASK, 2_000, store)).toBe("also check the dock");
  expect(takeCloudCarry(TASK, 3_000, store)).toBeUndefined();
});

test("a draft back to the prompt alone, a failed start or an old carry leaves nothing", () => {
  const store = memory();
  holdCloudCarry(TASK, `${TASK} more`, 1_000, store);
  holdCloudCarry(TASK, TASK, 1_100, store);
  expect(store.items.size).toBe(0);
  holdCloudCarry(TASK, `${TASK} more`, 1_000, store);
  dropCloudCarry(TASK, store);
  expect(takeCloudCarry(TASK, 1_200, store)).toBeUndefined();
  holdCloudCarry(TASK, `${TASK} more`, 1_000, store);
  expect(takeCloudCarry(TASK, 1_000 + CARRY_TTL_MS + 1, store)).toBeUndefined();
  expect(store.items.size).toBe(0);
});

test("two starts out at once keep their own carry", () => {
  const store = memory();
  holdCloudCarry(TASK, `${TASK} one`, 1_000, store);
  holdCloudCarry("Other prompt", "Other prompt two", 1_000, store);
  dropCloudCarry("Other prompt", store);
  expect(takeCloudCarry(TASK, 1_100, store)).toBe("one");
});
