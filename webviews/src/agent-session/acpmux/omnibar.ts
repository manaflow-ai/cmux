import type { TabKind } from "./NewTabPage";

/// What the omnibar can suggest besides the typed text: the window's open tabs and
/// workspaces (jumping to one beats opening a duplicate), recent sessions, folders,
/// commands and browser history. The host sends it with the new tab page.
export type OmnibarContext = {
  tabs: { id: string; kind: TabKind; title: string; detail?: string; workspace?: string }[];
  workspaces: { id: string; name: string; detail?: string }[];
  sessions: { sessionId: string; title: string; harness?: string; detail?: string }[];
  folders: string[];
  commands: string[];
  history: { url: string; title?: string }[];
};

export const EMPTY_OMNIBAR: OmnibarContext = {
  tabs: [],
  workspaces: [],
  sessions: [],
  folders: [],
  commands: [],
  history: [],
};

/// Maximum entries accepted from the host for each NewTab source.
export const MAX_NEW_TAB_ENTRIES = 40;

const string = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const records = (value: unknown) =>
  (Array.isArray(value) ? value : []).filter(
    (item): item is Record<string, unknown> => typeof item === "object" && item !== null,
  );

/// Reads the handshake's `newTab.omnibar`, dropping entries without the fields a row needs.
export function omnibarContext(value: unknown): OmnibarContext | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const object = value as Record<string, unknown>;
  const kinds = new Set(["terminal", "browser", "agent"]);
  return {
    tabs: records(object.tabs).flatMap((tab) => {
      const id = string(tab.id);
      const title = string(tab.title) ?? "";
      if (!id || !kinds.has(tab.kind as string)) return [];
      const detail = string(tab.detail);
      const workspace = string(tab.workspace);
      return [
        { id, kind: tab.kind as TabKind, title, ...(detail ? { detail } : {}), ...(workspace ? { workspace } : {}) },
      ];
    }).slice(0, MAX_NEW_TAB_ENTRIES),
    workspaces: records(object.workspaces).flatMap((workspace) => {
      const id = string(workspace.id);
      const name = string(workspace.name);
      const detail = string(workspace.detail);
      return id && name ? [{ id, name, ...(detail ? { detail } : {}) }] : [];
    }).slice(0, MAX_NEW_TAB_ENTRIES),
    sessions: [],
    folders: (Array.isArray(object.folders) ? object.folders : [])
      .flatMap((path) => string(path) ?? [])
      .slice(0, MAX_NEW_TAB_ENTRIES),
    commands: (Array.isArray(object.commands) ? object.commands : [])
      .flatMap((command) => string(command) ?? [])
      .slice(0, MAX_NEW_TAB_ENTRIES),
    history: records(object.history).flatMap((entry) => {
      const url = string(entry.url);
      const title = string(entry.title);
      return url ? [{ url, ...(title ? { title } : {}) }] : [];
    }).slice(0, MAX_NEW_TAB_ENTRIES),
  };
}

export type OmnibarRow =
  | { type: "tab"; id: string; kind: TabKind; title: string; detail?: string }
  | { type: "workspace"; id: string; title: string; detail?: string }
  | { type: "session"; id: string; title: string; harness?: string; detail?: string }
  | { type: "folder"; path: string }
  | { type: "command"; command: string }
  | { type: "history"; url: string; title?: string }
  /// The typed text as the selected kind: run it, open or search it.
  | { type: "run"; text: string }
  | { type: "open"; text: string }
  /// Always last: the text as a prompt to the agent.
  | { type: "ask"; text: string };

/// How many rows the empty bar shows per source, and the cap while typing.
const EMPTY_COUNTS = { tabs: 4, workspaces: 3, sessions: 3, folders: 2, commands: 2, history: 3 };
export const MAX_ROWS = 9;

/// How well `text` matches `query`: 3 for a prefix, 2 for a word start, 1 anywhere, 0 none.
export function matchScore(query: string, ...texts: (string | undefined)[]): number {
  const needle = query.trim().toLowerCase();
  if (!needle) return 0;
  let best = 0;
  for (const text of texts) {
    const hay = text?.toLowerCase();
    if (!hay) continue;
    const at = hay.indexOf(needle);
    if (at === 0) return 3;
    if (at > 0) best = Math.max(best, /[\s/._:@#-]/.test(hay[at - 1]!) ? 2 : 1);
  }
  return best;
}

/// The rows under the bar. Empty: where you can go (open tabs and workspaces first),
/// then what you did recently. Typed: the text as the selected kind, the matches from
/// every source best first, and "Ask <agent>" last. Agent text has no separate first row:
/// the last row is what Enter does.
export function omnibarRows(query: string, kind: TabKind, context: OmnibarContext): OmnibarRow[] {
  const text = query.trim();
  const tabs = context.tabs.map((tab): OmnibarRow => ({
    type: "tab",
    id: tab.id,
    kind: tab.kind,
    title: tab.title,
    ...(tab.detail || tab.workspace ? { detail: [tab.workspace, tab.detail].filter(Boolean).join(" · ") } : {}),
  }));
  const workspaces = context.workspaces.map((workspace): OmnibarRow => ({
    type: "workspace",
    id: workspace.id,
    title: workspace.name,
    ...(workspace.detail ? { detail: workspace.detail } : {}),
  }));
  const sessions = context.sessions.map((session): OmnibarRow => ({
    type: "session",
    id: session.sessionId,
    title: session.title,
    ...(session.harness ? { harness: session.harness } : {}),
    ...(session.detail ? { detail: session.detail } : {}),
  }));
  const folders = context.folders.map((path): OmnibarRow => ({ type: "folder", path }));
  const commands = context.commands.map((command): OmnibarRow => ({ type: "command", command }));
  const history = context.history.map((entry): OmnibarRow => ({
    type: "history",
    url: entry.url,
    ...(entry.title ? { title: entry.title } : {}),
  }));

  if (!text) {
    return [
      ...tabs.slice(0, EMPTY_COUNTS.tabs),
      ...workspaces.slice(0, EMPTY_COUNTS.workspaces),
      ...sessions.slice(0, EMPTY_COUNTS.sessions),
      ...folders.slice(0, EMPTY_COUNTS.folders),
      ...commands.slice(0, EMPTY_COUNTS.commands),
      ...history.slice(0, EMPTY_COUNTS.history),
    ];
  }

  // Open things rank above things to open, at the same match strength.
  const weight: Record<OmnibarRow["type"], number> = {
    tab: 0.6,
    workspace: 0.5,
    session: 0.4,
    folder: 0.3,
    command: kind === "terminal" ? 0.35 : 0.2,
    history: kind === "browser" ? 0.35 : 0.1,
    run: 0,
    open: 0,
    ask: 0,
  };
  const scored = [...tabs, ...workspaces, ...sessions, ...folders, ...commands, ...history]
    .map((row) => ({ row, score: matchScore(text, ...rowTexts(row)) }))
    .filter((entry) => entry.score > 0)
    .map((entry) => ({ row: entry.row, score: entry.score + weight[entry.row.type] }))
    .sort((a, b) => b.score - a.score)
    .map((entry) => entry.row);
  const first: OmnibarRow[] =
    kind === "terminal" ? [{ type: "run", text }] : kind === "browser" ? [{ type: "open", text }] : [];
  const last: OmnibarRow = { type: "ask", text };
  return [...first, ...scored.slice(0, MAX_ROWS - first.length - 1), last];
}

/// The row Enter takes before the arrows move: the typed text's own row. None for an
/// empty bar, where Enter makes the selected kind as it is (an empty terminal or chat).
export function defaultRow(rows: OmnibarRow[], kind: TabKind, query: string): number {
  if (!query.trim()) return -1;
  return kind === "agent" ? rows.length - 1 : 0;
}

function rowTexts(row: OmnibarRow): (string | undefined)[] {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return [row.title, row.detail];
    case "folder":
      return [row.path, row.path.split("/").pop()];
    case "command":
      return [row.command];
    case "history":
      return [row.title, row.url.replace(/^https?:\/\/(www\.)?/, "")];
    default:
      return [];
  }
}
