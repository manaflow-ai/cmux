import { describe, expect, test } from "bun:test";
import { mockSessions } from "../mockFixture";
import {
  findOpen,
  closeTab,
  newTerminalWorkspace,
  openFromHistory,
  openSessionIds,
  seedStack,
  terminalFirst,
  workspaceLead,
} from "./workspaces";

describe("workspace stack prototype", () => {
  test("every seeded agent tab is a fixture session", () => {
    const fixture = new Set(mockSessions.map((session) => session.sessionId));
    for (const id of openSessionIds(seedStack)) expect(fixture.has(id)).toBe(true);
  });

  test("opening an open session jumps to its tab instead of duplicating it", () => {
    const { stack, jumped } = openFromHistory(seedStack, { sessionId: "mock-tool-output" });
    expect(jumped).toBe(true);
    expect(stack.workspaces).toHaveLength(seedStack.workspaces.length);
    expect(stack.activeId).toBe("ws-stream");
    expect(findOpen(stack, "mock-tool-output")!.workspace.activeTabId).toBe("agent-mock-tool-output");
  });

  test("opening a closed session restores it as a new workspace at the top, once", () => {
    const first = openFromHistory(seedStack, { sessionId: "mock-zsh", displayTitle: "Clean up zsh startup time" });
    expect(first.jumped).toBe(false);
    expect(first.stack.workspaces[0]!.id).toBe(first.stack.activeId);
    expect(workspaceLead(first.stack.workspaces[0]!).title).toBe("Clean up zsh startup time");
    const again = openFromHistory(first.stack, { sessionId: "mock-zsh" });
    expect(again.jumped).toBe(true);
    expect(again.stack.workspaces).toHaveLength(first.stack.workspaces.length);
  });

  test("a workspace is named by its agent session, else its first tab", () => {
    const dev = seedStack.workspaces.find((workspace) => workspace.id === "ws-dev")!;
    expect(workspaceLead(dev).title).toBe("cmux · bun run dev");
    const uploader = seedStack.workspaces[0]!;
    expect(workspaceLead(uploader).kind).toBe("agent");
  });

  test("classic cmux opens on a terminal, and a new workspace is a terminal", () => {
    const first = terminalFirst(seedStack);
    const active = first.workspaces.find((workspace) => workspace.id === first.activeId)!;
    expect(active.tabs.find((tab) => tab.id === active.activeTabId)!.kind).toBe("terminal");
    const added = newTerminalWorkspace(first);
    expect(added.workspaces[0]!.tabs.map((tab) => tab.kind)).toEqual(["terminal"]);
    expect(added.activeId).toBe(added.workspaces[0]!.id);
  });

  test("closing the active tab focuses the tab to its right, then the one to its left", () => {
    const right = closeTab(seedStack, "ws-uploader", "agent-mock-session");
    expect(right.closed).toBe(true);
    expect(right.stack.workspaces[0]!.tabs.map((tab) => tab.id)).toEqual(["t-uploader", "b-uploader"]);
    expect(right.stack.workspaces[0]!.activeTabId).toBe("t-uploader");
    expect(right.focus).toEqual({ workspaceId: "ws-uploader", tabId: "t-uploader" });

    const left = closeTab(right.stack, "ws-uploader", "t-uploader");
    expect(left.stack.workspaces[0]!.tabs.map((tab) => tab.id)).toEqual(["b-uploader"]);
    expect(left.stack.workspaces[0]!.activeTabId).toBe("b-uploader");
    expect(left.focus).toEqual({ workspaceId: "ws-uploader", tabId: "b-uploader" });
  });

  test("closing an inactive tab preserves the active tab and focus", () => {
    const result = closeTab(seedStack, "ws-uploader", "b-uploader");
    expect(result.closed).toBe(true);
    expect(result.focus).toBeUndefined();
    expect(result.stack.activeId).toBe("ws-uploader");
    expect(result.stack.workspaces[0]!.activeTabId).toBe("agent-mock-session");
    expect(result.stack.workspaces[0]!.tabs.map((tab) => tab.id)).toEqual(["agent-mock-session", "t-uploader"]);
  });

  test("closing the final tab focuses the next workspace, otherwise the previous one", () => {
    const first = closeTab(seedStack, "ws-docs", "b-docs");
    expect(first.stack.activeId).toBe("ws-uploader");
    expect(first.focus).toBeUndefined();
    expect(first.stack.workspaces.map((workspace) => workspace.id)).not.toContain("ws-docs");

    const last = closeTab({ ...first.stack, activeId: "ws-dotfiles" }, "ws-dotfiles", "t-dotfiles");
    expect(last.stack.activeId).toBe("ws-home");
    expect(last.focus).toEqual({ workspaceId: "ws-home", tabId: "agent-mock-home-screen" });
  });

  test("an unknown tab is a no-op", () => {
    const result = closeTab(seedStack, "ws-uploader", "missing");
    expect(result).toEqual({ stack: seedStack, closed: false });
  });

  test("closing a tab keeps the nearest tab active and removes an empty workspace", () => {
    const afterActive = closeTab(seedStack, "ws-uploader", "agent-mock-session");
    const uploader = afterActive.stack.workspaces.find((workspace) => workspace.id === "ws-uploader")!;
    expect(uploader.tabs.map((tab) => tab.id)).toEqual(["t-uploader", "b-uploader"]);
    expect(uploader.activeTabId).toBe("t-uploader");

    const afterMiddle = closeTab(afterActive.stack, "ws-uploader", "t-uploader");
    const afterFinal = closeTab(afterMiddle.stack, "ws-uploader", "b-uploader");
    expect(afterFinal.stack.workspaces.some((workspace) => workspace.id === "ws-uploader")).toBe(false);
    expect(afterFinal.stack.activeId).toBe("ws-flicker");
  });

  test("closing the only tab in the only workspace is a safe no-op", () => {
    const single = {
      activeId: "ws-only",
      workspaces: [
        {
          id: "ws-only",
          tabs: [{ id: "tab-only", kind: "terminal" as const, title: "shell" }],
          activeTabId: "tab-only",
        },
      ],
    };
    expect(closeTab(single, "ws-only", "tab-only")).toEqual({ stack: single, closed: false });
  });
});
