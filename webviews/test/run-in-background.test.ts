// Ctrl-B moves a Claude Code chat's running work to the background (conversation/runInBackground.ts):
// which chats can, which calls of the running turn it moves, and which keys count. The real pane's
// keys are covered by agent-pane-ctrl-b-background.test.ts.
import { describe, expect, test } from "bun:test";
import {
  backgroundsWork,
  foregroundCalls,
  isBackgroundKey,
} from "../src/agent-session/acpmux/conversation/runInBackground";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (
  kind: string,
  tools: { id: string; kind: string; status: string }[] = [],
  extra: Partial<AcpmuxRow> = {},
): AcpmuxRow =>
  ({
    id: `${kind}-${tools.map((tool) => tool.id).join("-")}`,
    version: 1,
    at: 0,
    kind,
    items: tools.map((tool) => ({ tool })),
    ...extra,
  }) as unknown as AcpmuxRow;

describe("backgroundsWork", () => {
  test("a local chat whose acpmux summary says it moves its work does, whatever its harness's name", () => {
    expect(backgroundsWork({ harness: "claude", backgroundsWork: true })).toBe(true);
    expect(backgroundsWork({ harness: "claude", backgroundsWork: true, hostKind: "local" })).toBe(true);
    expect(backgroundsWork({ harness: "claude-sr", backgroundsWork: true })).toBe(true);
    // The model router's profile is Claude Code under acpmux, named `cmux`.
    expect(backgroundsWork({ harness: "cmux", backgroundsWork: true })).toBe(true);
  });

  test("a chat acpmux does not move work for does not, a Claude-named ACP harness included", () => {
    expect(backgroundsWork({ harness: "codex", backgroundsWork: false })).toBe(false);
    expect(backgroundsWork({ harness: "claude-acp", backgroundsWork: false })).toBe(false);
    // An acpmux that does not say (older, or a summary not read yet) gets no Ctrl-B.
    expect(backgroundsWork({ harness: "claude" })).toBe(false);
  });

  test("a peer's or Cloud chat and a chat not yet known do not", () => {
    expect(backgroundsWork({ harness: "claude", backgroundsWork: true, peer: "huge-blue" })).toBe(false);
    expect(backgroundsWork({ harness: "claude", backgroundsWork: true, hostKind: "cloud" })).toBe(false);
    expect(backgroundsWork(undefined)).toBe(false);
  });
});

describe("foregroundCalls", () => {
  test("the running turn's running commands and subagents, newest first", () => {
    const rows = [
      row("user"),
      row("tools", [
        { id: "read", kind: "read", status: "in_progress" },
        { id: "build", kind: "execute", status: "in_progress" },
      ]),
      row("tools", [
        { id: "agent", kind: "think", status: "pending" },
        { id: "done", kind: "execute", status: "completed" },
      ]),
    ];
    expect(foregroundCalls(rows)).toEqual(["agent", "build"]);
  });

  test("a command left pending after its permission prompt was answered still counts", () => {
    const rows = [row("user"), row("tools", [{ id: "allowed", kind: "execute", status: "pending" }])];
    expect(foregroundCalls(rows)).toEqual(["allowed"]);
  });

  test("a prompt steered into the turn does not hide the calls before it", () => {
    const rows = [
      row("user"),
      row("tools", [{ id: "build", kind: "execute", status: "in_progress" }]),
      row("user", [], { steer: "landed" }),
    ];
    expect(foregroundCalls(rows)).toEqual(["build"]);
  });

  test("a prompt still sending, or never sent, does not end the turn either", () => {
    const rows = [
      row("user"),
      row("tools", [{ id: "build", kind: "execute", status: "in_progress" }]),
      row("user", [], { failed: true }),
      row("user", [], { pending: true }),
    ];
    expect(foregroundCalls(rows)).toEqual(["build"]);
  });

  test("a call left running in an earlier turn is not the running turn's", () => {
    const rows = [row("user"), row("tools", [{ id: "old", kind: "execute", status: "in_progress" }]), row("user")];
    expect(foregroundCalls(rows)).toEqual([]);
  });
});

describe("isBackgroundKey", () => {
  const key = (key: string, mods: Partial<Record<"ctrlKey" | "metaKey" | "altKey" | "shiftKey", boolean>> = {}) => ({
    key,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    ...mods,
  });

  test("Ctrl-B alone", () => {
    expect(isBackgroundKey(key("b", { ctrlKey: true }))).toBe(true);
  });

  test("not B, ⌘B (the sidebar's) or Ctrl-B with another modifier", () => {
    expect(isBackgroundKey(key("b"))).toBe(false);
    expect(isBackgroundKey(key("b", { metaKey: true }))).toBe(false);
    expect(isBackgroundKey(key("b", { ctrlKey: true, metaKey: true }))).toBe(false);
    expect(isBackgroundKey(key("B", { ctrlKey: true, shiftKey: true }))).toBe(false);
    expect(isBackgroundKey(key("b", { ctrlKey: true, altKey: true }))).toBe(false);
    expect(isBackgroundKey(key("c", { ctrlKey: true }))).toBe(false);
  });
});
