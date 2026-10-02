import { describe, expect, test } from "bun:test";
import { mockSessions } from "../mockFixture";
import {
  findOpen,
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
});
