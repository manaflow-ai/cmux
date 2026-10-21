// The chat menu's Fork submenu and Copy session ID: Fork names each turn by the prompt that began
// it, newest first, and Copy lists the session id last.
import { expect, test } from "bun:test";
import { earlierForkPrompts, forkablePrompts } from "../src/agent-session/acpmux/conversation/messageMenu";
import { copyRow } from "../src/agent-session/acpmux/header/copyRow";
import { opensBesideRows, sideChatRow } from "../src/agent-session/acpmux/header/sideChatRow";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

test("Fork names each turn by its first prompt, newest first", () => {
  const rows = [
    { kind: "user", text: "Tidy   the\nnotes" },
    { kind: "assistant", text: "Done." },
    { kind: "turnSummary", seq: 4 },
    { kind: "user", text: "Rename the file" },
    // A steer later in the turn does not rename it.
    { kind: "user", text: "and keep its history" },
    { kind: "turnSummary", seq: 9 },
  ];
  expect(forkablePrompts(rows)).toEqual([
    { seq: 9, text: "Rename the file" },
    { seq: 4, text: "Tidy the notes" },
  ]);
});

test("Fork leaves out a turn begun without text instead of reusing the turn before", () => {
  const rows = [
    { kind: "user", text: "First" },
    { kind: "turnSummary", seq: 2 },
    { kind: "user", text: "" },
    { kind: "turnSummary", seq: 5 },
  ];
  expect(forkablePrompts(rows)).toEqual([{ seq: 2, text: "First" }]);
});

test("Fork names a turn by its sent prompt, not one that failed or is still pending", () => {
  const rows = [
    { kind: "user", text: "Lost prompt", failed: true },
    { kind: "user", text: "Queued prompt", pending: true },
    { kind: "user", text: "Sent prompt" },
    { kind: "turnSummary", seq: 3 },
  ];
  expect(forkablePrompts(rows)).toEqual([{ seq: 3, text: "Sent prompt" }]);
});

test("Fork's earlier turns leave out only the latest turn, even when it began with an image", () => {
  const rows = [
    { kind: "user", text: "One" },
    { kind: "turnSummary", seq: 2 },
    { kind: "user", text: "Two" },
    { kind: "turnSummary", seq: 4 },
    { kind: "user", text: "" },
    { kind: "turnSummary", seq: 6 },
  ];
  expect(earlierForkPrompts(rows)).toEqual([
    { seq: 4, text: "Two" },
    { seq: 2, text: "One" },
  ]);
  const many = Array.from({ length: 12 }, (_, index) => [
    { kind: "user", text: `Prompt ${index}` },
    { kind: "turnSummary", seq: index * 2 + 1 },
  ]).flat();
  const earlier = earlierForkPrompts(many);
  expect(earlier).toHaveLength(8);
  expect(earlier[0]).toEqual({ seq: 21, text: "Prompt 10" });
});

test("Copy lists the session id last, and only for a chat that has one", () => {
  const rows = [{ kind: "assistant", text: "Done." }] as unknown as AcpmuxRow[];
  const copied: string[] = [];
  const row = copyRow({ link: undefined, rows, sessionId: "sess-1" }, (text) => copied.push(text));
  const children = row && "children" in row ? (row.children ?? []) : [];
  const last = children.at(-1);
  expect(last && "key" in last ? last.key : undefined).toBe("copySessionId");
  if (last && "onSelect" in last) last.onSelect?.();
  expect(copied).toEqual(["sess-1"]);
  const without = copyRow({ link: undefined, rows }, () => {});
  const keys = (without && "children" in without ? (without.children ?? []) : []).map((child) =>
    "key" in child ? child.key : undefined,
  );
  expect(keys).not.toContain("copySessionId");
});

test("New terminal and New browser open beside a tab, and Quick Chat's panel has no tab beside it", () => {
  const open = { terminal: () => {}, browser: () => {} };
  const keys = (quick: boolean) => {
    const sideChat = sideChatRow({ canFork: true, throughSeq: 3, local: !quick }, () => {});
    return opensBesideRows({ sideChat, quick }, open).map((row) => row.key);
  };
  expect(keys(false)).toEqual(["sideChat", "newTerminal", "newBrowser"]);
  expect(keys(true)).toEqual([]);
});
