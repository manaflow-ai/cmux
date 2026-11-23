// The edited-files card cuts a long file name in its middle, keeping its extension and the word
// before it (Leo, 2026-11-23, on "Edited objective-design-edge-cases.md" with Undo drawn over it).
// The layout itself is test/chat-card-fit.test.ts; this pins which end stays.
import { expect, test } from "bun:test";
import { middleCutTail } from "../src/agent-session/acpmux/conversation/EditedFilesCard";

const tail = (name: string) => name.slice(name.length - middleCutTail(name));

test("a long name keeps its last word and its extension", () => {
  expect(tail("objective-design-edge-cases.md")).toBe("-cases.md");
  expect(tail("ios-target-is-cmux-internal.md")).toBe("-internal.md");
  expect(tail("exponentialWithDecorrelatedJitter.test.ts")).toBe(".test.ts");
});

test("a name without a break keeps its last characters, never the whole name", () => {
  const kept = tail("averyveryverylongnamewithnobreaksatall.ts");
  expect(kept.endsWith(".ts")).toBe(true);
  expect(kept.length).toBeLessThanOrEqual(16);
  expect(tail("README").length).toBeLessThan("README".length);
  expect(tail("a.md")).toBe(".md");
});
