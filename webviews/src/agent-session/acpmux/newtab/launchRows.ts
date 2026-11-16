// The omnibar's agent rows (Lawrence 2026-11-13: "omnibar needs to be able to create new agent
// chats, search through all existing workspaces/terminals/panes/etc, search through history, and
// also launch claude code/codex/opencode in certain directories"): the chats that match the typed
// text, and "Start <agent> in <folder>" with the folder completed from the folders the page knows
// and, for a typed path, from the disk (`folder.complete`, answered later: ``FolderListing``).
// Pure and synchronous: a keystroke reads only the lists it is given, never the disk.
import { foldedScore, foldedTexts } from "../omnibar";
import { type AcpmuxSessionEntry, homePath, isAgentHome, withoutChildren } from "../sessionList";
import type { AllChatsRow } from "./allChatsListModel";
import type { DeviceChat } from "./deviceChats";

/// An agent the page can start: its catalog id (`claude`, `codex`, `opencode`) and name.
export type LaunchAgent = { id: string; name: string };

/// One chat the field can open: a live acpmux session (`id`) or a device chat (`key`, the harness
/// chat index's `harness:sessionId`, opened through `chats.open`).
export type OmnibarChat = {
  id: string;
  key?: string;
  title: string;
  harness?: string;
  cwd?: string;
  /// The harness chat it is (`harness:agentSessionId`): a live session and the device chat of the
  /// same harness chat are one row.
  same?: string;
  /// When the person or the agent last did something in it (Unix ms): newer first within a tier.
  at?: number;
};

/// The disk's subfolders of `parent` (absolute, no trailing slash but `/` itself), as the host's
/// `folder.complete` answered them: names only, folders only.
export type FolderListing = { parent: string; folders: readonly string[] };

/// What the text asks to start: which agents, and the folder text after them (`~/fun/cm`, `cmux`,
/// empty for "the folders you use").
export type LaunchIntent = {
  agents: LaunchAgent[];
  /// The folder as typed, without the agent word or `in`.
  path: string;
  /// The agent word as typed ("claude"), absent when the text is a path alone.
  word?: string;
  /// The text before the path as typed ("codex in "): Tab's fill keeps it.
  before?: string;
  /// The text named an agent by its whole name: its rows lead, above Ask, and Return takes them.
  named: boolean;
};

export const MAX_LAUNCH_ROWS = 4;
export const MAX_CHAT_ROWS = 3;
/// The shortest agent word that names an agent ("cod" is Codex; "co" and "c" are nothing).
const MIN_AGENT_WORD = 3;
/// The shortest folder name a word alone finds ("cm" asks, "cmux" finds ~/fun/cmux).
const MIN_FOLDER_WORD = 3;
/// The shortest text that finds a chat inside a title ("ab" only at a word's start).
const MIN_SUBSTRING = 3;

/// The agents the first word names: a prefix of the id or of the name's first word ("open" is
/// OpenCode, "cla" is Claude Code; "code" is Codex, never Claude Code's second word). `exact` when
/// the word is a whole id or first name word ("codex", "claude"): only then do its rows lead and
/// take Return, as Chrome's omnibox enters a keyword only on the whole keyword. A prefix still lists
/// them, in their section, so the top row does not change on every letter of "clarify".
function agentsNamed(word: string, agents: readonly LaunchAgent[]): { agents: LaunchAgent[]; exact: boolean } {
  const needle = word.toLocaleLowerCase();
  if (needle.length < MIN_AGENT_WORD) return { agents: [], exact: false };
  const first = (agent: LaunchAgent) => agent.name.toLocaleLowerCase().split(/\s+/, 1)[0] ?? "";
  const exact = agents.filter((agent) => agent.id.toLocaleLowerCase() === needle || first(agent) === needle);
  if (exact.length) return { agents: exact, exact: true };
  return {
    agents: agents.filter(
      (agent) => agent.id.toLocaleLowerCase().startsWith(needle) || first(agent).startsWith(needle),
    ),
    exact: false,
  };
}

/// A typed path: `~`, `~/…`, `/…`.
export function looksLikePath(text: string): boolean {
  return text === "~" || text.startsWith("~/") || text.startsWith("/");
}

/// `~/fun` to `/Users/me/fun` (with `home`); anything else as it is.
export function expandHome(path: string, home: string | undefined): string {
  if (!home) return path;
  if (path === "~") return home;
  return path.startsWith("~/") ? `${home.replace(/\/+$/, "")}${path.slice(1)}` : path;
}

/// What the text asks to start, or undefined for text that names no agent and no folder:
/// "claude ~/fun/cmux", "codex in cmux", "opencode" (the folders used lately), "~/fun/cmux"
/// (a path alone starts the default agent there). Two or more words where the second is not a
/// path or `in` are a prompt ("claude why is this slow"), never a launch.
export function launchIntent(
  text: string,
  agents: readonly LaunchAgent[],
  defaultAgent?: string,
): LaunchIntent | undefined {
  const query = text.trim();
  if (!query || !agents.length) return undefined;
  if (looksLikePath(query)) {
    if (/\s/.test(query)) return undefined;
    const first = agents.find((agent) => agent.id === defaultAgent);
    return {
      agents: first ? [first, ...agents.filter((agent) => agent !== first)] : [...agents],
      path: query,
      named: false,
    };
  }
  // A whole name of several words leads ("claude code ~/x"), else the first word ("claude ~/x").
  const folded = query.toLocaleLowerCase();
  const whole = agents.find((agent) => {
    const name = agent.name.toLocaleLowerCase();
    return name.includes(" ") && (folded === name || folded.startsWith(`${name} `));
  });
  const word = whole ? query.slice(0, whole.name.length) : query.split(/\s+/, 1)[0]!;
  const found = whole ? { agents: [whole], exact: true } : agentsNamed(word, agents);
  const named = found.agents;
  if (!named.length) {
    // One word that may name a folder ("cmux"): the default agent there, below the matches.
    const first = agents.find((agent) => agent.id === defaultAgent);
    if (!first || /\s/.test(query) || query.length < MIN_FOLDER_WORD) return undefined;
    return { agents: [first], path: query, named: false };
  }
  const rest = query
    .slice(word.length)
    .trim()
    .replace(/^in(?:\s+|$)/i, "");
  // The rest is a folder (a path or one word), else the text is a prompt to the agent.
  if (rest && !looksLikePath(rest) && (/\s/.test(rest) || rest.length < MIN_FOLDER_WORD)) return undefined;
  if (looksLikePath(rest) && /\s/.test(rest)) return undefined;
  const before = rest && looksLikePath(rest) ? query.slice(0, query.length - rest.length) : undefined;
  return { agents: named, path: rest, word, named: found.exact, ...(before ? { before } : {}) };
}

/// The known folders a typed folder text finds, best first: for a path, the folders under it (the
/// path itself first when it is one); for a word, the folders whose name starts with it, then
/// those with a word of it; empty text, the known folders in their order (most recent first).
/// `listing` adds the disk's subfolders of the typed path's parent when it answers that parent.
export function folderMatches(
  path: string,
  known: readonly string[],
  options: { home?: string; listing?: FolderListing; limit?: number } = {},
): string[] {
  const limit = options.limit ?? MAX_LAUNCH_ROWS;
  const seen = new Set<string>();
  const out: { folder: string; score: number; index: number }[] = [];
  const add = (folder: string, score: number, index: number) => {
    const key = folder.replace(/(.)\/+$/, "$1");
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ folder: key, score, index });
  };
  if (!path) {
    known.slice(0, limit).forEach((folder, index) => add(folder, 1, index));
    return out.map((entry) => entry.folder);
  }
  if (looksLikePath(path)) {
    const full = expandHome(path, options.home);
    const needle = full.toLocaleLowerCase();
    const bare = needle.replace(/(.)\/+$/, "$1");
    known.forEach((folder, index) => {
      const hay = folder.toLocaleLowerCase();
      if (hay === bare) add(folder, 3, index);
      else if (hay.startsWith(needle)) add(folder, 2, index);
    });
    const listing = options.listing;
    if (listing && listing.parent === parentOf(full)) {
      const name = full.slice(full.lastIndexOf("/") + 1).toLocaleLowerCase();
      const base = listing.parent === "/" ? "" : listing.parent;
      listing.folders.forEach((child, index) => {
        if (!child.toLocaleLowerCase().startsWith(name)) return;
        const folder = `${base}/${child}`;
        add(folder, child.toLocaleLowerCase() === name ? 3 : 1.5, known.length + index);
      });
    }
  } else {
    const needle = path.trim().toLowerCase();
    // Each folder's name and `~` path lowercased once per list, not on every key (foldedTexts).
    const folded = foldedTexts(known, "folders", (list) =>
      list.map((folder) => ({
        name: (folder.replace(/\/+$/, "").split("/").pop() ?? folder).toLowerCase(),
        shown: homePath(folder).toLowerCase(),
      })),
    );
    known.forEach((folder, index) => {
      const texts = folded[index]!;
      const score = foldedScore(needle, texts.name);
      if (score >= 2) add(folder, score, index);
      else if (needle.length >= MIN_FOLDER_WORD && foldedScore(needle, texts.shown) >= 2) add(folder, 1, index);
    });
  }
  return out
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, limit)
    .map((entry) => entry.folder);
}

/// The folder whose subfolders complete `full`'s last part: `/Users/me/fun` for
/// `/Users/me/fun/cm`, the folder itself for `/Users/me/fun/`. Undefined for a relative path.
export function parentOf(full: string): string | undefined {
  if (!full.startsWith("/")) return undefined;
  const at = full.lastIndexOf("/");
  return at <= 0 ? "/" : full.slice(0, at);
}

/// The folder `folder.complete` is asked about for the typed text, or undefined when the text is
/// no launch of a typed path (a word, a prompt, an address).
export function listingWanted(
  text: string,
  agents: readonly LaunchAgent[],
  home: string | undefined,
  defaultAgent?: string,
): string | undefined {
  const intent = launchIntent(text, agents, defaultAgent);
  if (!intent || !looksLikePath(intent.path)) return undefined;
  // "/model" or "/rev" is a slash command being typed, not a folder under /: only "/" itself or a
  // path with a second part ("/Users/") lists from the disk.
  if (intent.path.startsWith("/") && intent.path !== "/" && !intent.path.slice(1).includes("/")) return undefined;
  const full = expandHome(intent.path, home);
  return full.startsWith("/") ? parentOf(full) : undefined;
}

/// One "Start <agent> in <folder>" row; `fill` is the field's text with the folder completed and a
/// slash after it (→, End or Tab take it, the way a shell completes a folder).
export type LaunchRow = { type: "launch"; harness: string; agent: string; folder: string; fill?: string };

/// The launch rows for the text: each named agent in each matching folder (the first agent first),
/// or for a path alone the default agent there and, in its best folder, the other agents too.
export function launchRows(
  text: string,
  context: {
    agents: readonly LaunchAgent[];
    folders: readonly string[];
    defaultAgent?: string;
    home?: string;
    listing?: FolderListing;
  },
): { rows: LaunchRow[]; named: boolean } {
  const intent = launchIntent(text, context.agents, context.defaultAgent);
  if (!intent) return { rows: [], named: false };
  const folders = folderMatches(intent.path, context.folders, {
    ...(context.home ? { home: context.home } : {}),
    ...(context.listing ? { listing: context.listing } : {}),
  });
  if (!folders.length) return { rows: [], named: false };
  const fill = (folder: string) => {
    if (!intent.path || !looksLikePath(intent.path)) return undefined;
    const shown = intent.path.startsWith("~") ? homePath(folder) : folder;
    const prefix = intent.before ?? "";
    return `${prefix}${shown}/`;
  };
  const row = (agent: LaunchAgent, folder: string): LaunchRow => {
    const completed = fill(folder);
    return {
      type: "launch",
      harness: agent.id,
      agent: agent.name,
      folder,
      ...(completed ? { fill: completed } : {}),
    };
  };
  const rows: LaunchRow[] = [];
  if (intent.named) {
    for (const folder of folders) for (const agent of intent.agents) rows.push(row(agent, folder));
  } else {
    const [lead, ...others] = intent.agents;
    const [best, ...rest] = folders;
    if (lead && best) rows.push(row(lead, best));
    for (const agent of others) rows.push(row(agent, best!));
    if (lead) for (const folder of rest) rows.push(row(lead, folder));
  }
  // A word after the agent's name leads only when it is a folder's whole name ("codex cmux"): a
  // word that only starts one ("claude tests" with ~/code/tests-e2e) may be a one-word prompt, so
  // its starts list under Ask and Return still asks.
  const word = intent.path && !looksLikePath(intent.path) ? intent.path.toLocaleLowerCase() : undefined;
  const whole = !word || folders.some((folder) => (folder.split("/").pop() ?? "").toLocaleLowerCase() === word);
  return { rows: rows.slice(0, MAX_LAUNCH_ROWS), named: intent.named && whole };
}

/// One chat row.
export type ChatRow = { type: "chat"; id: string; key?: string; title: string; harness?: string };

/// The chats whose title (or folder name) the text finds: a prefix or a word's start, or for 3+
/// characters anywhere in the title; the newest first within a tier. A live session and a device
/// chat for the same harness chat are one row (the live one).
export function chatRows(query: string, chats: readonly OmnibarChat[], limit = MAX_CHAT_ROWS): ChatRow[] {
  const needle = query.trim().toLowerCase();
  if (!needle || !chats.length) return [];
  // Each title and folder name lowercased once per list, not on every key (foldedTexts).
  const folded = foldedTexts(chats, "chats", (list) =>
    list.map((chat) => ({ title: chat.title.toLowerCase(), folder: chat.cwd?.split("/").pop()?.toLowerCase() })),
  );
  const scored: { chat: OmnibarChat; score: number; index: number }[] = [];
  chats.forEach((chat, index) => {
    const texts = folded[index]!;
    const title = foldedScore(needle, texts.title);
    const folder = foldedScore(needle, texts.folder);
    const score = Math.max(title, folder >= 2 ? folder - 0.5 : 0);
    if (score >= 2 || (score > 0 && needle.length >= MIN_SUBSTRING)) scored.push({ chat, score, index });
  });
  const seen = new Set<string>();
  return scored
    .sort((a, b) => b.score - a.score || (b.chat.at ?? 0) - (a.chat.at ?? 0) || a.index - b.index)
    .filter(({ chat }) => {
      const key = chat.same ?? chat.key ?? chat.id;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, limit)
    .map(({ chat }) => ({
      type: "chat",
      id: chat.id,
      ...(chat.key ? { key: chat.key } : {}),
      title: chat.title,
      ...(chat.harness ? { harness: chat.harness } : {}),
    }));
}

/// The most folders the field searches: the projects, then the newest chats' folders.
export const MAX_KNOWN_FOLDERS = 200;
/// The most chats the field searches on each key (the device index's own search finds the rest).
export const MAX_KNOWN_CHATS = 500;

/// `/`, `/Users`, a home folder, a private agent-home folder: never a folder to start in.
function startable(cwd: string | undefined): cwd is string {
  return !!cwd && cwd.startsWith("/") && !/^\/(?:(?:Users|home)(?:\/[^/]+)?)?\/?$/.test(cwd) && !isAgentHome(cwd);
}

/// The folders the field completes from: this Mac's projects in the host's order, then the
/// folders of the newest chats here, once each.
export function omnibarFolders(
  projects: readonly { cwd: string; peer?: string }[] | undefined,
  sessions: readonly AcpmuxSessionEntry[],
): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const add = (cwd: string | undefined) => {
    if (!startable(cwd) || out.length >= MAX_KNOWN_FOLDERS) return;
    const key = cwd.replace(/(.)\/+$/, "$1");
    if (seen.has(key)) return;
    seen.add(key);
    out.push(key);
  };
  for (const project of projects ?? []) if (!project.peer) add(project.cwd);
  const local = sessions.filter((session) => !session.peer && session.hostKind !== "cloud");
  const newest = [...local].sort((a, b) => (b.activityAt ?? b.updatedAt ?? 0) - (a.activityAt ?? a.updatedAt ?? 0));
  for (const session of newest) add(session.cwd);
  return out;
}

/// The chats the field searches: the live sessions (a sub-agent's folds under its chat), then the
/// device index's chats its search found for the text, then the ones it pushed, newest first.
export function omnibarChats(
  sessions: readonly AcpmuxSessionEntry[],
  searched: readonly AllChatsRow[],
  pushed: readonly DeviceChat[],
): OmnibarChat[] {
  const out: OmnibarChat[] = [];
  for (const session of withoutChildren([...sessions])) {
    const title = session.displayTitle ?? session.title ?? session.name;
    if (!title) continue;
    const at = session.activityAt ?? session.updatedAt;
    out.push({
      id: session.sessionId,
      title,
      ...(session.harness ? { harness: session.harness } : {}),
      ...(session.cwd && !isAgentHome(session.cwd) ? { cwd: session.cwd } : {}),
      ...(session.harness && session.agentSessionId ? { same: `${session.harness}:${session.agentSessionId}` } : {}),
      ...(at ? { at } : {}),
    });
  }
  for (const chat of searched) {
    if (!chat.title) continue;
    out.push({
      id: chat.key,
      key: chat.key,
      same: chat.key,
      title: chat.title,
      harness: chat.harness,
      ...(chat.cwd ? { cwd: chat.cwd } : {}),
      at: chat.updatedAt,
    });
  }
  for (const chat of pushed) {
    if (!chat.title || chat.parent) continue;
    out.push({
      id: chat.key,
      key: chat.key,
      same: chat.key,
      title: chat.title,
      harness: chat.harness,
      at: chat.updatedAt,
    });
  }
  return out.slice(0, MAX_KNOWN_CHATS);
}
