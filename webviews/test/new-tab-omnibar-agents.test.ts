// Lawrence 2026-11-13: "omnibar needs to be able to create new agent chats, search through all
// existing workspaces/terminals/panes/etc, search through history, and also launch claude
// code/codex/opencode in certain directories". The New Tab field lists the chats it finds and
// "Start <agent> in <folder>" rows, the folder completed from the known folders and, for a typed
// path, the disk's answer; the rows come in ranked sections with headers.
import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import {
  chatRows,
  folderMatches,
  launchIntent,
  launchRows,
  listingWanted,
  omnibarChats,
  omnibarFolders,
  type LaunchAgent,
} from "../src/agent-session/acpmux/newtab/launchRows";
import {
  inlineCompletion,
  rowSection,
  screenRows,
  leadLength,
  sectionHeader,
  type ScreenRow,
} from "../src/agent-session/acpmux/newtab/screenModel";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const HOME = "/Users/me";
const AGENTS: LaunchAgent[] = [
  { id: "claude", name: "Claude Code" },
  { id: "codex", name: "Codex" },
  { id: "opencode", name: "OpenCode" },
];
const FOLDERS = ["/Users/me/fun/cmux", "/Users/me/fun/cmux-tui", "/Users/me/code/site", "/Users/me/notes"];
const ask = { harness: "claude", agent: "Claude Code" };

const context = (fields: Partial<OmnibarContext> = {}, more: Record<string, unknown> = {}) => ({
  omnibar: { ...EMPTY_OMNIBAR, ...fields },
  home: HOME,
  ask,
  agents: AGENTS,
  folders: FOLDERS,
  defaultAgent: "claude",
  ...more,
});

const kinds = (rows: ScreenRow[]) => rows.map((row) => row.type);
const launches = (rows: ScreenRow[]) =>
  rows.flatMap((row) => (row.type === "launch" ? [`${row.harness} ${row.folder}`] : []));

test("an agent's name and a folder word start that agent there, above Ask", () => {
  const rows = screenRows("codex cmux", context());
  expect(launches(rows)).toEqual(["codex /Users/me/fun/cmux", "codex /Users/me/fun/cmux-tui"]);
  expect(rows[0]).toMatchObject({ type: "launch", harness: "codex", folder: "/Users/me/fun/cmux" });
  expect(kinds(rows)).toContain("ask");
  expect(kinds(rows).indexOf("ask")).toBeGreaterThan(kinds(rows).lastIndexOf("launch"));
});

test("an agent's name alone lists the folders used lately; a prefix and a two-word name work too", () => {
  expect(launches(screenRows("opencode", context())).slice(0, 2)).toEqual([
    "opencode /Users/me/fun/cmux",
    "opencode /Users/me/fun/cmux-tui",
  ]);
  expect(launchIntent("open", AGENTS)?.agents.map((agent) => agent.id)).toEqual(["opencode"]);
  expect(launchIntent("claude code ~/fun", AGENTS)).toMatchObject({ path: "~/fun", word: "claude code" });
  expect(launchIntent("codex in ~/fun/cmux", AGENTS)).toMatchObject({ path: "~/fun/cmux", named: true });
  // "code" is Codex's prefix, never Claude Code's second word.
  expect(launchIntent("code", AGENTS)?.agents.map((agent) => agent.id)).toEqual(["codex"]);
});

test("a prompt that starts with an agent's name stays a prompt", () => {
  expect(launchIntent("claude why is the build slow", AGENTS)).toBeUndefined();
  const rows = screenRows("claude why is the build slow", context());
  expect(launches(rows)).toEqual([]);
  expect(rows[0]?.type).toBe("ask");
  // One letter names no agent.
  expect(launchIntent("c", AGENTS)).toBeUndefined();
});

test("a typed path starts the default agent there and offers the others in the best folder", () => {
  const rows = screenRows("~/fun/cmux", context());
  expect(launches(rows)).toEqual(["claude /Users/me/fun/cmux", "codex /Users/me/fun/cmux"]);
  expect(
    launchRows("~/fun/cmux", { agents: AGENTS, folders: FOLDERS, home: HOME, defaultAgent: "claude" }).rows.map(
      (row) => `${row.harness} ${row.folder}`,
    ),
  ).toEqual([
    "claude /Users/me/fun/cmux",
    "codex /Users/me/fun/cmux",
    "opencode /Users/me/fun/cmux",
    "claude /Users/me/fun/cmux-tui",
  ]);
  // A path alone names no agent: the path's own row and Ask still lead, the starts list under them.
  expect(kinds(rows).slice(0, 2)).toEqual(["open", "ask"]);
  expect(kinds(rows).indexOf("launch")).toBeGreaterThan(1);
});

test("a typed path completes from the disk's answer for its parent, and → or Tab fills it", () => {
  const listing = { parent: "/Users/me/fun", folders: ["cmux", "cmux-tui", "cmuxterm-hq", "games"] };
  expect(folderMatches("~/fun/cmuxt", FOLDERS, { home: HOME, listing })).toEqual(["/Users/me/fun/cmuxterm-hq"]);
  const { rows } = launchRows("codex ~/fun/g", { agents: AGENTS, folders: FOLDERS, home: HOME, listing });
  expect(rows).toEqual([
    { type: "launch", harness: "codex", agent: "Codex", folder: "/Users/me/fun/games", fill: "codex ~/fun/games/" },
  ]);
  const screen = screenRows("codex ~/fun/g", context({}, { listing }));
  expect(inlineCompletion("codex ~/fun/g", screen)).toBe("codex ~/fun/games/");
  // A listing for another folder adds nothing.
  expect(folderMatches("~/fun/g", [], { home: HOME, listing: { parent: "/tmp", folders: ["games"] } })).toEqual([]);
});

test("only a typed path asks the disk, and it asks for the folder its last part completes in", () => {
  expect(listingWanted("codex ~/fun/cm", AGENTS, HOME)).toBe("/Users/me/fun");
  expect(listingWanted("~/fun/", AGENTS, HOME, "claude")).toBe("/Users/me/fun");
  expect(listingWanted("/", AGENTS, HOME, "claude")).toBe("/");
  expect(listingWanted("codex cmux", AGENTS, HOME)).toBeUndefined();
  expect(listingWanted("reddit.com", AGENTS, HOME, "claude")).toBeUndefined();
  expect(listingWanted("claude explain ~/x", AGENTS, HOME)).toBeUndefined();
});

test("a word that names a folder offers the default agent there, under the open tabs", () => {
  const rows = screenRows("notes", context({ workspaces: [{ id: "w1", name: "notes app" }] }));
  expect(launches(rows)).toEqual(["claude /Users/me/notes"]);
  const workspace = kinds(rows).indexOf("workspace");
  expect(workspace).toBeGreaterThan(-1);
  expect(kinds(rows).indexOf("launch")).toBeGreaterThan(workspace);
});

test("chats are searched by title and folder, newest first, a live chat once with its device row", () => {
  const sessions = [
    {
      sessionId: "s1",
      displayTitle: "Fix the omnibar ranking",
      harness: "claude",
      cwd: "/Users/me/fun/cmux",
      activityAt: 10,
      agentSessionId: "a1",
    },
    { sessionId: "s2", displayTitle: "Omnibar perf", harness: "codex", cwd: "/Users/me/fun/cmux", activityAt: 20 },
    { sessionId: "s3", displayTitle: "Unrelated", harness: "codex", cwd: "/Users/me/notes", activityAt: 30 },
  ] as AcpmuxSessionEntry[];
  const chats = omnibarChats(
    sessions,
    [],
    [{ key: "claude:a1", harness: "claude", title: "Fix the omnibar ranking", updatedAt: 5 }],
  );
  const rows = chatRows("omni", chats);
  expect(rows.map((row) => row.id)).toEqual(["s2", "s1"]);
  expect(rows[0]).toMatchObject({ type: "chat", harness: "codex", detail: "~/fun/cmux" });
  // The folder's name finds a chat too.
  expect(chatRows("notes", chats).map((row) => row.id)).toEqual(["s3"]);
  // Two letters find a chat only at a word's start.
  expect(chatRows("ni", chats)).toEqual([]);
});

test("chats the device index found for the text list with their key, for chats.open", () => {
  const chats = omnibarChats(
    [],
    [{ key: "codex:x9", harness: "codex", title: "Ship the omnibar", cwd: "/Users/me/fun/cmux", updatedAt: 3 }],
    [],
  );
  expect(chatRows("ship", chats)).toEqual([
    {
      type: "chat",
      id: "codex:x9",
      key: "codex:x9",
      title: "Ship the omnibar",
      harness: "codex",
      detail: "~/fun/cmux",
    },
  ]);
});

test("the rows come in ranked sections: lead, open, chats, start, history, commands, web search", () => {
  const rows = screenRows(
    "cmux",
    context(
      {
        tabs: [{ id: "t1", kind: "terminal", title: "cmux build", workspace: "cmux" }],
        history: [{ url: "https://github.com/manaflow-ai/cmux", title: "manaflow-ai/cmux" }],
        actions: [{ id: "a1", title: "cmux: Reload", keywords: [] }],
      },
      { chats: [{ id: "s1", title: "cmux omnibar", at: 1 }] },
    ),
  );
  // The exact name ("cmux", the tab's workspace) and Ask lead; the sections follow in their order.
  expect(kinds(rows).slice(0, leadLength(rows))).toEqual(["tab", "ask"]);
  const sections = rows.slice(leadLength(rows)).map(rowSection);
  const order = ["lead", "open", "chats", "start", "pages", "actions", "web", "create"];
  const ranks = sections.map((section) => order.indexOf(section));
  expect(ranks).toEqual([...ranks].sort((a, b) => a - b));
  expect(sections).toEqual(expect.arrayContaining(["chats", "start", "pages", "actions", "web"]));
  // A header starts each section after the lead, once.
  const headers = rows.flatMap((_, index) => sectionHeader(rows, index) ?? []);
  expect(headers).toEqual(["chats", "start", "pages", "actions"]);
});

test("the folders are this Mac's projects, then the newest chats' folders, never home or a private folder", () => {
  const sessions = [
    { sessionId: "a", cwd: "/Users/me/old", activityAt: 1 },
    { sessionId: "b", cwd: "/Users/me/new", activityAt: 9 },
    { sessionId: "c", cwd: "/Users/me", activityAt: 10 },
    { sessionId: "d", cwd: "/Users/me/elsewhere", peer: "ssh://box", activityAt: 11 },
  ] as AcpmuxSessionEntry[];
  expect(omnibarFolders([{ cwd: "/Users/me/fun/cmux/" }, { cwd: "/srv/remote", peer: "ssh://box" }], sessions)).toEqual(
    ["/Users/me/fun/cmux", "/Users/me/new", "/Users/me/old"],
  );
});

test("without agent sources the rows are as before", () => {
  const before = screenRows("zqxv", { omnibar: EMPTY_OMNIBAR, ask });
  expect(kinds(before)).toEqual(["ask", "search"]);
});
