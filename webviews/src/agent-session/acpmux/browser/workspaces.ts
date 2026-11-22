/// The person's cmux NEXT workspaces as acpmux reads them from the app for an enrolled browser
/// (`_acpmux/browser_workspaces`, cmux-tui/crates/acpmux/src/server/browser_workspaces.rs).

/// One agent chat tab in a workspace. `local`: the chat runs on the acpmux this browser reached, so
/// `sessionId` opens it here; a chat on another machine is shown but not opened.
export type BrowserWorkspaceChat = {
  tabId: string;
  sessionId?: string;
  local: boolean;
  title: string;
  host: string;
  harness?: string;
};

export type BrowserWorkspace = {
  id: string;
  name: string;
  title?: string | null;
  chats: BrowserWorkspaceChat[];
};

/// `available: false`: no app daemon answered (no source set, or it did not answer in time).
/// `truncated`: the reply stopped at its byte budget before the last workspace.
export type BrowserWorkspaces = {
  available: boolean;
  registryId?: string | null;
  workspaces: BrowserWorkspace[];
  truncated?: boolean;
};

/// The chats a workspace already shows, so the flat session list leaves them out.
export function linkedSessions(workspaces: BrowserWorkspaces | undefined): Set<string> {
  const linked = new Set<string>();
  for (const workspace of workspaces?.workspaces ?? []) {
    for (const chat of workspace.chats) {
      if (chat.local && chat.sessionId) linked.add(chat.sessionId);
    }
  }
  return linked;
}

/// The workspaces whose name, title or one of whose chat titles holds `needle` (lowercased); every
/// workspace when `needle` is empty. `chatTitle` names a chat as the sidebar shows it.
export function matchingWorkspaces(
  workspaces: BrowserWorkspaces | undefined,
  needle: string,
  chatTitle: (chat: BrowserWorkspaceChat) => string,
): BrowserWorkspace[] {
  const rows = workspaces?.workspaces ?? [];
  if (!needle) return rows;
  return rows.filter((workspace) =>
    [workspace.name, workspace.title, ...workspace.chats.map(chatTitle)].some((part) =>
      part?.toLocaleLowerCase().includes(needle),
    ),
  );
}
