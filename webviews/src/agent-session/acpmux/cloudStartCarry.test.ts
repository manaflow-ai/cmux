// What the composer holds around a Cloud start (cloudStartCarry.ts).
import { expect, test } from "bun:test";
import { holdsDraft, promptBeforeTyped } from "./cloudStartCarry";
import type { ComposerAttachment } from "./attachments";

const chip = (id: string) => ({ id, kind: "file", name: `${id}.txt` }) as unknown as ComposerAttachment;
const words = (text: string) => ({ text, attachments: [] });

test("a draft of blank text and no chips holds nothing", () => {
  expect(holdsDraft(undefined)).toBe(false);
  expect(holdsDraft(words(" \n"))).toBe(false);
  expect(holdsDraft(words("note"))).toBe(true);
  expect(holdsDraft({ text: "", attachments: [chip("a")] })).toBe(true);
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
