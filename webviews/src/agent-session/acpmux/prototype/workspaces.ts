// Sidebar prototype (#16688): the main sidebar is one stack of open workspaces, each holding
// terminals, browsers and agent sessions. Past and imported agent sessions are history, a layer
// the user opens on purpose; opening one jumps to its tab when it is already open.
import { WORKED_SESSION } from "../mockFixture";

export type TabKind = "agent" | "terminal" | "browser";
export type WorkspaceTab = {
  id: string;
  kind: TabKind;
  title: string;
  sessionId?: string;
  url?: string;
  /** A browser tab's profile, fixed when the tab is made (data-model.md 5). */
  browserProfile?: string;
};
/** `browserProfile` is the workspace's own default, over its room's. */
export type Workspace = { id: string; tabs: WorkspaceTab[]; activeTabId: string; browserProfile?: string };
export type Stack = { workspaces: Workspace[]; activeId: string };

export const agent = (sessionId: string, title: string): WorkspaceTab => ({
  id: `agent-${sessionId}`,
  kind: "agent",
  title,
  sessionId,
});
export const terminal = (id: string, title: string): WorkspaceTab => ({ id, kind: "terminal", title });
export const browser = (id: string, title: string, url: string): WorkspaceTab => ({ id, kind: "browser", title, url });
export const workspace = (id: string, ...tabs: WorkspaceTab[]): Workspace => ({ id, tabs, activeTabId: tabs[0]!.id });

/** What a few hours of work leave open, on the #16642 fixture's sessions. */
export const seedStack: Stack = {
  activeId: "ws-uploader",
  workspaces: [
    workspace(
      "ws-uploader",
      agent(WORKED_SESSION, "Add retry backoff to the fleet uploader"),
      terminal("t-uploader", "upload-retry"),
      browser("b-uploader", "fleet: retry artifact uploads", "github.com/manaflow-ai/cmux/pull/18204"),
    ),
    workspace(
      "ws-flicker",
      agent("mock-sidebar-flicker", "Fix sidebar flicker on theme change"),
      terminal("t-flicker", "hearty-beige-elk"),
    ),
    workspace(
      "ws-tabstrip",
      agent("mock-tab-strip", "Review the terminal tab strip"),
      browser("b-tabstrip", "Tab strip spec", "github.com/manaflow-ai/cmux/issues/16620"),
    ),
    workspace("ws-dev", terminal("t-dev", "cmux · bun run dev"), browser("b-dev", "cmux dev", "localhost:5173")),
    workspace(
      "ws-stream",
      agent("mock-tool-output", "Stream tool output in chunks"),
      terminal("t-stream", "cargo test"),
    ),
    workspace(
      "ws-home",
      agent("mock-home-screen", "Polish the home screen"),
      browser("b-home", "atlas-web", "localhost:4321"),
    ),
    workspace("ws-docs", browser("b-docs", "Ghostty configuration", "ghostty.org/docs/config")),
    workspace("ws-dotfiles", terminal("t-dotfiles", "dotfiles · nvim")),
  ],
};

/** The workspace and tab already showing a session, if any. */
export function findOpen(stack: Stack, sessionId: string): { workspace: Workspace; tab: WorkspaceTab } | undefined {
  for (const workspace of stack.workspaces) {
    const tab = workspace.tabs.find((candidate) => candidate.sessionId === sessionId);
    if (tab) return { workspace, tab };
  }
  return undefined;
}

/** Session ids open in some tab. */
export const openSessionIds = (stack: Stack) =>
  new Set(
    stack.workspaces.flatMap((workspace) => workspace.tabs.flatMap((tab) => (tab.sessionId ? [tab.sessionId] : []))),
  );

/** Opening a history row: jump to the tab that already shows it, else restore it as a new workspace at the top. */
export function openFromHistory(
  stack: Stack,
  session: { sessionId: string; displayTitle?: string },
): { stack: Stack; jumped: boolean } {
  const open = findOpen(stack, session.sessionId);
  if (open)
    return {
      jumped: true,
      stack: {
        activeId: open.workspace.id,
        workspaces: stack.workspaces.map((workspace) =>
          workspace === open.workspace ? { ...workspace, activeTabId: open.tab.id } : workspace,
        ),
      },
    };
  const restored = workspace(
    `ws-${session.sessionId}`,
    agent(session.sessionId, session.displayTitle ?? "Agent session"),
  );
  return { jumped: false, stack: { activeId: restored.id, workspaces: [restored, ...stack.workspaces] } };
}

export function selectTab(stack: Stack, workspaceId: string, tabId?: string): Stack {
  return {
    activeId: workspaceId,
    workspaces: stack.workspaces.map((workspace) =>
      workspace.id === workspaceId && tabId ? { ...workspace, activeTabId: tabId } : workspace,
    ),
  };
}

/** A workspace's name in the stack: its agent session when it has one, else its first tab. */
export function workspaceLead(workspace: Workspace): WorkspaceTab {
  return workspace.tabs.find((tab) => tab.kind === "agent") ?? workspace.tabs[0]!;
}

/** Classic cmux's new workspace: a terminal, at the top of the stack. */
export function newTerminalWorkspace(stack: Stack): Stack {
  const id = `ws-new-${stack.workspaces.length + 1}`;
  return { activeId: id, workspaces: [workspace(id, terminal(`t-${id}`, "~ · zsh")), ...stack.workspaces] };
}

/** Classic cmux opens on a terminal: the first terminal-led workspace, with its terminal tab showing. */
export function terminalFirst(stack: Stack): Stack {
  const lead = stack.workspaces.find((candidate) => candidate.tabs[0]!.kind === "terminal");
  return lead ? selectTab(stack, lead.id, lead.tabs[0]!.id) : stack;
}
