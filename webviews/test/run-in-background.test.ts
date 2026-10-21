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
  test("a local Claude Code chat moves its work, a profile's too", () => {
    expect(backgroundsWork({ harness: "claude" })).toBe(true);
    expect(backgroundsWork({ harness: "claude", hostKind: "local" })).toBe(true);
    expect(backgroundsWork({ harness: "claude-sr" })).toBe(true);
  });

  test("other harnesses, a peer's or Cloud chat and a chat not yet known do not", () => {
    expect(backgroundsWork({ harness: "codex" })).toBe(false);
    expect(backgroundsWork({ harness: "claudette" })).toBe(false);
    expect(backgroundsWork({ harness: "claude", peer: "huge-blue" })).toBe(false);
    expect(backgroundsWork({ harness: "claude", hostKind: "cloud" })).toBe(false);
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
