// What a Cloud start's page keeps for the started chat (cloudStartCarry.ts).
import { expect, test } from "bun:test";
import {
  CLOUD_START_DRAFT_TTL_MS,
  dropCloudStartDraft,
  keepCloudStartDraft,
  promptBeforeTyped,
  takeCloudStartDraft,
  withoutPrompt,
  type CloudStartDraftStore,
} from "./cloudStartCarry";
import type { ComposerAttachment } from "./attachments";

function store(): CloudStartDraftStore & { items: Map<string, string> } {
  const items = new Map<string, string>();
  return {
    items,
    getItem: (name) => items.get(name) ?? null,
    setItem: (name, value) => void items.set(name, value),
    removeItem: (name) => void items.delete(name),
  };
}
const chip = (id: string) => ({ id, kind: "file", name: `${id}.txt` }) as unknown as ComposerAttachment;
const words = (text: string) => ({ text, attachments: [] });

test("a kept draft is taken once by the chat its prompt started, the newest first", () => {
  const kept = store();
  keepCloudStartDraft(kept, "start-1", "fix it", words("older"), 1_000);
  keepCloudStartDraft(kept, "start-2", "fix it", words("newer"), 2_000);
  keepCloudStartDraft(kept, "start-3", "other prompt", words("not this one"), 3_000);
  expect(takeCloudStartDraft(kept, "fix it", 4_000)).toEqual(words("newer"));
  expect(takeCloudStartDraft(kept, "fix it", 4_000)).toEqual(words("older"));
  expect(takeCloudStartDraft(kept, "fix it", 4_000)).toBeUndefined();
  expect(takeCloudStartDraft(kept, "other prompt", 4_000)).toEqual(words("not this one"));
  expect(kept.items.size).toBe(0);
});

test("an emptied composer, a start that ended here and an old start keep nothing", () => {
  const kept = store();
  keepCloudStartDraft(kept, "start-1", "fix it", words("typed"), 1_000);
  keepCloudStartDraft(kept, "start-1", "fix it", words("  "), 1_100);
  expect(takeCloudStartDraft(kept, "fix it", 1_200)).toBeUndefined();
  keepCloudStartDraft(kept, "start-2", "fix it", words("typed"), 1_000);
  dropCloudStartDraft(kept, "start-2", 1_100);
  expect(takeCloudStartDraft(kept, "fix it", 1_200)).toBeUndefined();
  keepCloudStartDraft(kept, "start-3", "fix it", words("typed"), 1_000);
  expect(takeCloudStartDraft(kept, "fix it", 1_000 + CLOUD_START_DRAFT_TTL_MS)).toBeUndefined();
});

test("chips go with the words; a store too full for them still keeps the words", () => {
  const kept = store();
  keepCloudStartDraft(kept, "start-1", "fix it", { text: "see this", attachments: [chip("a")] }, 1_000);
  expect(takeCloudStartDraft(kept, "fix it", 1_100)?.attachments.map((held) => held.id)).toEqual(["a"]);
  const full = store();
  const setItem = full.setItem;
  full.setItem = (name, value) => {
    if (value.includes('"attachments":[{')) throw new Error("QuotaExceededError");
    setItem(name, value);
  };
  keepCloudStartDraft(full, "start-1", "fix it", { text: "see this", attachments: [chip("a")] }, 1_000);
  expect(takeCloudStartDraft(full, "fix it", 1_100)).toEqual(words("see this"));
});

test("the start's own prompt in front of the draft is never carried twice", () => {
  expect(withoutPrompt(words("fix it"), "fix it")).toEqual(words(""));
  expect(withoutPrompt(words("fix it\n\nand the nightly"), "fix it")).toEqual(words("and the nightly"));
  expect(withoutPrompt(words("fix it later"), "fix it")).toEqual(words("fix it later"));
  const kept = store();
  keepCloudStartDraft(kept, "start-1", "fix it", words("fix it"), 1_000);
  expect(kept.items.size).toBe(0);
});

test("a failed start's prompt splits from the typed text only while the composer still holds both", () => {
  const typed = { text: "and the nightly", attachments: [chip("t")] };
  const composer = { text: "fix it\n\nand the nightly", attachments: [chip("p"), chip("t")] };
  expect(promptBeforeTyped(composer, typed)).toEqual({
    prompt: { text: "fix it", attachments: [chip("p")] },
    typed,
  });
  expect(promptBeforeTyped({ ...composer, text: "fix it\n\nand the nightly too" }, typed)).toBeUndefined();
  expect(promptBeforeTyped({ ...composer, attachments: [chip("p")] }, typed)).toBeUndefined();
  expect(promptBeforeTyped(composer, words(""))).toBeUndefined();
});
