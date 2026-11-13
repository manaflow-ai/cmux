import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Translate } from "../i18n";
import { moveToTerminal, terminalChatKey, terminalMoveRow, type TerminalMoveChat } from "./terminalMoveRow";

const t = ((key: string) => key) as Translate;

const chat: TerminalMoveChat = {
  sessionId: "s1",
  family: "claude",
  agentSessionId: "a1",
  local: true,
  native: true,
  quick: false,
  watching: false,
  working: false,
};

/// A move whose steps are recorded in order; `release` and `open` fail with the given errors.
function recorder(options: { releaseError?: unknown; openError?: unknown; switchAfterRelease?: boolean } = {}) {
  const steps: string[] = [];
  let shown = true;
  const run = {
    release: async () => {
      steps.push("release");
      if (options.switchAfterRelease) shown = false;
      if (options.releaseError) throw options.releaseError;
    },
    open: async (key: string) => {
      steps.push(`open ${key}`);
      if (options.openError) throw options.openError;
    },
    close: () => steps.push("close"),
    same: () => shown,
    say: (text: string) => steps.push(`say ${text}`),
  };
  return { steps, run };
}

describe("Move to terminal (header/terminalMoveRow.ts)", () => {
  test("the key names the chat index's harness id and the harness's own session id", () => {
    expect(terminalChatKey("claude", "a1")).toBe("claude-code:a1");
    expect(terminalChatKey("codex", "t1")).toBe("codex:t1");
    expect(terminalChatKey("opencode", "o1")).toBeUndefined();
    expect(terminalChatKey("claude", undefined)).toBeUndefined();
    expect(terminalChatKey(undefined, "a1")).toBeUndefined();
  });

  test("a started local Claude Code or Codex chat in the app offers the row, which moves its key", () => {
    const moved: string[] = [];
    const claude = terminalMoveRow(chat, (key) => moved.push(key), t);
    expect(claude?.key).toBe("moveToTerminal");
    expect(claude?.label).toBe("chatMenu.moveToTerminal");
    expect(claude?.disabled).toBe(false);
    claude?.onSelect?.();
    terminalMoveRow({ ...chat, family: "codex", agentSessionId: "t1" }, (key) => moved.push(key), t)?.onSelect?.();
    expect(moved).toEqual(["claude-code:a1", "codex:t1"]);
  });

  test("no row before the chat starts, off this Mac, outside the app, in Quick Chat, in View Only, or for another harness", () => {
    for (const other of [
      { sessionId: undefined },
      { agentSessionId: undefined },
      { local: false },
      { native: false },
      { quick: true },
      { watching: true },
      { family: "opencode" },
    ] satisfies Partial<TerminalMoveChat>[])
      expect(terminalMoveRow({ ...chat, ...other }, () => undefined, t)).toBeUndefined();
  });

  test("the row is disabled while a turn runs", () => {
    expect(terminalMoveRow({ ...chat, working: true }, () => undefined, t)?.disabled).toBe(true);
  });

  test("a move stops the pane's harness first, then opens the terminal, then closes the tab", async () => {
    const { steps, run } = recorder();
    expect(await moveToTerminal("claude-code:a1", run, t)).toBe(true);
    expect(steps).toEqual(["release", "open claude-code:a1", "close"]);
  });

  test("a busy chat is not moved: nothing opens and the tab stays", async () => {
    const { steps, run } = recorder({ releaseError: { code: -32030, data: { reason: "busy", busyWith: "queued" } } });
    expect(await moveToTerminal("claude-code:a1", run, t)).toBe(false);
    expect(steps).toEqual(["release", "say chatMenu.moveToTerminalBusy"]);
  });

  test("a failed stop opens nothing, and a failed open keeps the tab", async () => {
    const stop = recorder({ releaseError: new Error("gone") });
    await moveToTerminal("codex:t1", stop.run, t);
    expect(stop.steps).toEqual(["release", "say chatMenu.moveToTerminalFailed"]);
    const open = recorder({ openError: new Error("unsupported") });
    expect(await moveToTerminal("codex:t1", open.run, t)).toBe(false);
    expect(open.steps).toEqual(["release", "open codex:t1", "say chatMenu.moveToTerminalFailed"]);
  });

  test("a chat switch keeps the tab, which shows another chat now; one before the pick moves nothing", async () => {
    const switched = recorder({ switchAfterRelease: true });
    await moveToTerminal("claude-code:a1", switched.run, t);
    expect(switched.steps).toEqual(["release", "open claude-code:a1"]);
    const before = recorder();
    await moveToTerminal("claude-code:a1", { ...before.run, same: () => false }, t);
    expect(before.steps).toEqual([]);
  });

  test("the chat menu draws the row, guarded, and releases with a conditional stop that keeps the chat", () => {
    const app = readFileSync(join(import.meta.dir, "../App.tsx"), "utf8");
    const start = app.indexOf("const chatMenu = (): ChatMenuItem[] =>");
    const chatMenu = app.slice(start, app.indexOf("\n  };\n", start));
    expect(chatMenu).toContain("const terminalMove = guarded(");
    expect(chatMenu).toContain('callNative("chats.openInTerminal", { key: chat })');
    expect(chatMenu).toContain("...terminalMove");
    const direct = readFileSync(join(import.meta.dir, "../direct.ts"), "utf8");
    expect(direct).toContain('this.request("_acpmux/kill", { sessionId, purge: false, ifIdle: true })');
  });
});
