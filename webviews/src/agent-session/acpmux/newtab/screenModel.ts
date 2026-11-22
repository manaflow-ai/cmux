// The new tab screen's pure state (variant B, plans/cmux-next/new-tab.md sections 3-4): the
// rows under the field for the typed text, the `!` conversion and the chat cards. No React, no
// host: NewTabScreen renders what these return.
import { withoutInlineTokens } from "../attachments";
import type { AcpmuxSnapshot } from "../model";
import { ageLabel, recentSessions } from "../newTabModel";
import {
  EMPTY_OMNIBAR,
  foldedScore,
  foldedTexts,
  matchScore,
  omnibarRows,
  type OmnibarContext,
  type OmnibarProfile,
  type OmnibarRow,
} from "../omnibar";
import { activityTime, listed, normalizedSessionEntry, sessionMark, type AcpmuxSessionEntry } from "../sessionList";
import { classifyNewTabInput, TERMINAL_PREFIX, type NewTabIntent } from "../newTabIntent";
import { resumeReference } from "../resumeCommand";
import { commandLikeness, isMultiline } from "./commandIntent";
import { type Translate, translate } from "../i18n";
import type { DeviceChat } from "./deviceChats";
import { DEFAULT_SUGGESTION_ORDER, type SuggestionOrder } from "./suggestionOrder";
import type { ScreenSections } from "./templates";
import { TOP_SITES } from "./topSites";
import { translateNewTab, type NewTabTranslate } from "./strings";
import { type FolderListing, launchRows, type LaunchAgent, type LaunchRow } from "./launchRows";

export type ScreenAgent = { id: string; name: string };

/// A row in the field's popover. The omnibar (Leo 2026-10-12, over cx-e2aa's addresses-only rows):
/// URL completions from visited pages and top sites, the open tabs and workspaces that match,
/// "Search the web for …" and "Ask <agent>". The top row is Return's.
export type ScreenRow =
  /// Search the web for `text` (the browser's search engine).
  | { type: "search"; text: string }
  | { type: "create"; kind: "terminal" | "browser" | "chat"; title: string }
  /// Load `url` (what `text` resolved to, or a top site that completes it).
  | { type: "open"; url: string; text: string }
  /// An open tab; `url` is a browser tab's page as `canonicalAddress` gives it.
  | { type: "tab"; id: string; title: string; detail?: string; icon?: string; url?: string }
  | { type: "workspace"; id: string; title: string; detail?: string }
  | { type: "history"; url: string; title?: string; icon?: string }
  /// A Commands palette action (Cmd-Shift-P) the host runs (`app.action`); `detail` is its section.
  | { type: "action"; id: string; title: string; detail?: string; keycaps?: string[]; symbol?: string }
  /// The text as a prompt to `harness`, named `agent` (its `model` when known).
  | { type: "ask"; text: string; harness: string; agent: string; model?: string }
  /// Open in Profile… (Lawrence 2026-11-05): the field becomes a search of every browser profile,
  /// for the address `url` that `text` resolved to (``profileRows``).
  | { type: "inProfile"; url: string; text: string }
  /// Open `url` in a profile made for it: named `name` (the profile search), else the host's next
  /// default name ("Profile 3").
  | { type: "newProfile"; url: string; name?: string }
  /// Open `url` in the browser profile `id` (a row of the profile search).
  | { type: "profile"; url: string; id: string; name: string; color?: string }
  /// Start an agent in a folder (launchRows.ts): "Codex in ~/fun/cmux".
  | LaunchRow
  /// Run `command` in a terminal in the page's folder, as `!command` does (commandIntent.ts).
  | { type: "run"; command: string }
  /// Resume the chat `ref` names (resumeCommand.ts `resumeReference`): `/resume <ref>`, a pasted
  /// session id, `claude --resume <id>`. It runs `/resume <ref>`, the chat composer's command.
  | { type: "resume"; ref: string };

/// The omnibar's agent sources: the folders and agents to start, and the disk's answer for a typed
/// path (``FolderListing``). All optional: without them the rows are as before. No chats: the
/// field starts things, the sidebar and All chats find chats (Lucas 2026-11-18).
export type ScreenAgentSources = {
  translate?: NewTabTranslate;
  create?: readonly ("terminal" | "browser" | "chat")[];
  folders?: readonly string[];
  agents?: readonly LaunchAgent[];
  defaultAgent?: string;
  listing?: FolderListing;
};

/// Groups used to rank suggestions before the web search.
export type ScreenSection = "lead" | "open" | "start" | "pages" | "actions" | "web";

/// The group a suggestion belongs to.
export function rowSection(row: ScreenRow): ScreenSection {
  switch (row.type) {
    case "tab":
    case "workspace":
      return "open";
    case "launch":
      return "start";
    case "history":
      return "pages";
    case "action":
    case "create":
      return "actions";
    case "search":
      return "web";
    default:
      return "lead";
  }
}

/// The web search row searches the draft's words, as `words` reads them: never an attachment's
/// token, whose id is no text the person wrote, which a pasted image's search row showed and
/// searched for (#41016). A draft of attachments alone searches nothing.
export function searchWords(rows: readonly ScreenRow[], words: (text: string) => string): ScreenRow[] {
  return rows.flatMap((row): ScreenRow[] => {
    if (row.type !== "search") return [row];
    const text = words(row.text).trim();
    return text ? [{ ...row, text }] : [];
  });
}

/// The agent the Ask row names.
export type ScreenAsk = { harness: string; agent: string; model?: string };

/// Open tabs, workspaces and visited pages shown under Ask.
export const MAX_MATCH_ROWS = 4;
/// Every row, the web search and Ask included.
export const MAX_SUGGESTIONS = 8;
/// Addresses that complete the typed word ("reddit" to reddit.com).
export const MAX_COMPLETIONS = 3;
/// The shortest word an address completes: "go" or "no" stays a prompt, not google.com or notion.so.
const MIN_COMPLETION_LENGTH = 3;
/// Agent starts listed for text that names no agent (a path, a folder's name): the best two; named
/// ("codex cmux") they lead, up to launchRows' own cap.
export const MAX_UNNAMED_LAUNCH_ROWS = 2;
/// Commands palette actions shown under the matches.
export const MAX_ACTION_ROWS = 3;
/// Chat cards under the field.
export const CHAT_CARD_COUNT = 3;

/// The catalog's agents in its order, the remembered one first.
export function orderedAgents(agents: readonly ScreenAgent[], lastAgent?: string): ScreenAgent[] {
  const remembered = agents.find((agent) => agent.id === lastAgent);
  const rest = agents.filter((agent) => agent !== remembered);
  return remembered ? [remembered, ...rest] : rest;
}

/// The agent a prompt goes to before the user picks one: the remembered one, else the first
/// installed.
export function defaultHarness(agents: readonly ScreenAgent[], lastAgent?: string): string | undefined {
  return orderedAgents(agents, lastAgent)[0]?.id;
}

/// The matches the `minimal` order shows.
export const MINIMAL_MATCH_ROWS = 3;
/// Shorter text matches a name only at its start or a word's ("ff" is not "diffviewer").
const SUBSTRING_MATCH_LENGTH = 3;

/// Suggestions for the typed text, including creation commands only when their names match.
export function screenRows(
  text: string,
  context: {
    omnibar: OmnibarContext;
    home?: string;
    ask?: ScreenAsk;
    order?: SuggestionOrder;
  } & ScreenAgentSources,
): ScreenRow[] {
  return withProfileRows(navigationRows(text, context), text, context);
}

/// A typed web address gets Open in Profile… (with more than one profile to pick from) and Open in
/// New Profile right under the row that opens it, when the host names its profiles. A local file,
/// a search or a prompt has no browser profile to pick.
function withProfileRows(rows: ScreenRow[], text: string, context: { omnibar: OmnibarContext; home?: string }) {
  const profiles = context.omnibar.profiles;
  if (!profiles || !rows.length) return rows;
  const intent =
    typingPort(text, context.home) ?? classifyNewTabInput(text, context.home ? { home: context.home } : {});
  if (intent.kind !== "url" || !/^https?:/i.test(intent.url)) return rows;
  const url = intent.url;
  const address = canonicalAddress(url);
  // Under the address's own row: its open row, or the open tab that shows that page.
  const at = rows.findIndex(
    (row) => (row.type === "open" && row.url === url) || (row.type === "tab" && row.url === address),
  );
  const extra: ScreenRow[] = [
    ...(profiles.length > 1 ? [{ type: "inProfile", url, text: text.trim() } as const] : []),
    { type: "newProfile", url },
  ];
  const after = at < 0 ? 0 : at + 1;
  return [...rows.slice(0, after), ...extra, ...rows.slice(after)];
}

/// The profile search's rows for `query` (Open in Profile…): every profile whose name matches, best
/// first (a prefix, then a word start, then letters inside a word or in order: "pnl" finds
/// "Personal"), the profiles' own order breaking ties; the empty search lists them all. Last, a new
/// profile for `url`: named `query` when no profile has that name, else the host's default name.
export function profileRows(query: string, url: string, profiles: readonly OmnibarProfile[]): ScreenRow[] {
  const needle = query.trim();
  const matched = profiles
    .map((profile, index) => ({ profile, index, score: needle ? profileScore(needle, profile.name) : 1 }))
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map(({ profile }): ScreenRow => ({
      type: "profile",
      url,
      id: profile.id,
      name: profile.name,
      ...(profile.color ? { color: profile.color } : {}),
    }));
  const folded = needle.toLocaleLowerCase();
  const taken = profiles.some((profile) => profile.name.trim().toLocaleLowerCase() === folded);
  return [...matched, { type: "newProfile", url, ...(needle && !taken ? { name: needle } : {}) }];
}

/// How well `needle` names a profile called `name`: the omnibar's match (3 a prefix, 2 a word start,
/// 1 inside a word), else 0.5 for its letters in order ("wrk" for "Work"), else 0.
function profileScore(needle: string, name: string): number {
  const score = matchScore(needle, name);
  if (score > 0) return score;
  const hay = name.toLocaleLowerCase();
  let at = 0;
  for (const letter of needle.toLocaleLowerCase().replace(/\s+/g, "")) {
    at = hay.indexOf(letter, at);
    if (at < 0) return 0;
    at += 1;
  }
  return 0.5;
}

/// An address with its port still to come (`localhost:`, `example.com:`): the address it was a key
/// ago, so its row stays put while the port is typed instead of leaving for one key and coming
/// back (the rows under it jumped 28 px down, up and down again; agent-pane.new-tab#create-strip-narrow).
function typingPort(text: string, home?: string): { kind: "url"; url: string } | undefined {
  const trimmed = text.trim();
  if (!trimmed.endsWith(":") || trimmed.endsWith("::")) return undefined;
  const intent = classifyNewTabInput(trimmed.slice(0, -1), home ? { home } : {});
  return intent.kind === "url" && !intent.url.startsWith("file:") ? intent : undefined;
}

function navigationRows(
  text: string,
  context: { omnibar: OmnibarContext; home?: string; ask?: ScreenAsk; order?: SuggestionOrder } & ScreenAgentSources,
): ScreenRow[] {
  const intent =
    typingPort(text, context.home) ?? classifyNewTabInput(text, context.home ? { home: context.home } : {});
  // A pairing link offers nothing: no search, no Ask, no address, no create row (they carry the text).
  if (intent.kind === "none" || intent.kind === "terminal" || intent.kind === "refused") return [];
  // A chat to resume leads (user 2026-11-20: "resuming claude sessions needs to 'just work'"). Typed
  // as `/resume <ref>` it is the one row: Ask would run the same command, and it is no web search.
  const resumeRef = resumeReference(text);
  const resume: ScreenRow[] = resumeRef ? [{ type: "resume", ref: resumeRef }] : [];
  if (resume.length && text.trim().startsWith("/")) return resume;
  return [...resume, ...typedRows(text, intent, context)].slice(0, resume.length ? MAX_SUGGESTIONS : undefined);
}

/// The rows for typed text that is not only a chat to resume.
function typedRows(
  text: string,
  intent: Exclude<NewTabIntent, { kind: "none" | "terminal" | "refused" }>,
  context: { omnibar: OmnibarContext; home?: string; ask?: ScreenAsk; order?: SuggestionOrder } & ScreenAgentSources,
): ScreenRow[] {
  const order = context.order ?? DEFAULT_SUGGESTION_ORDER;
  const query = text.trim();
  const ask: ScreenRow[] = context.ask ? [{ type: "ask", text: query, ...context.ask }] : [];
  // Many lines are a prompt (Lucas 2026-11-17): Ask alone, no matches, starts, search or actions.
  if (intent.kind === "prompt" && isMultiline(query)) return ask;
  // A shell command gets a Run row: first when it reads as one (`ls`, `git status`), second when
  // it may be words too (`open the settings`), after an agent's starts for its bare name (`claude`).
  const likeness =
    intent.kind === "prompt"
      ? commandLikeness(query, {
          agents: context.agents?.map((agent) => agent.id) ?? [],
          recent: context.omnibar.commands,
        })
      : "prose";
  const run: ScreenRow[] = likeness === "prose" ? [] : [{ type: "run", command: query }];
  const actionID = (kind: "terminal" | "browser" | "chat") =>
    kind === "terminal" ? "newSurface" : kind === "browser" ? "openBrowser" : "palette.newAgentChat";
  const createQuery = withoutInlineTokens(query).trim();
  const creates: ScreenRow[] = (context.create ?? []).flatMap((kind) => {
    const label = (context.translate ?? translateNewTab)(`create.${kind}`);
    const action = context.omnibar.actions?.find((item) => item.id === actionID(kind));
    const title = action?.title ?? label;
    const score = matchScore(
      createQuery,
      title,
      label,
      kind === "terminal" ? "new terminal tab" : "",
      ...(action?.keywords ?? []),
    );
    return score >= 2 || (score > 0 && createQuery.length >= SUBSTRING_MATCH_LENGTH)
      ? [{ type: "create" as const, kind, title }]
      : [];
  });
  const replaced = new Set<string>((context.create ?? []).map(actionID));
  const actions = [
    ...creates,
    ...actionRows(query, context.omnibar, MAX_ACTION_ROWS + replaced.size).filter(
      (row) => row.type !== "action" || !replaced.has(row.id),
    ),
  ].slice(0, MAX_ACTION_ROWS);
  const search: ScreenRow[] =
    intent.kind === "url" && intent.url.startsWith("file:") ? [] : [{ type: "search", text: query }];
  const open: ScreenRow[] = intent.kind === "url" ? [{ type: "open", url: intent.url, text: query }] : [];
  const completed = completions(query, context.omnibar);
  const found = suggestions([...open, ...completed, ...matches(query, context.omnibar)], context.omnibar);
  // What leads above Ask: the address, the page a site's whole name or a host-like word completes
  // ("reddit", "reddit.c"; "reddi" or "app" ask), or a tab or workspace named exactly that.
  const addressTop = open.length > 0 || namesSite(query, completed[0]);
  const top = addressTop ? found[0] : exactMatch(query, found, context.omnibar);
  const rest = found.filter((row) => row !== top);
  const cap = order === "minimal" ? MINIMAL_MATCH_ROWS : MAX_MATCH_ROWS;
  // The open tabs and workspaces, then the agents to start, then the visited pages:
  // each section ranked inside itself (`ranked` keeps tabs, workspaces, pages in that order).
  // An agent named with a folder ("codex ~/fun/cmux") leads: what Return starts. Never over an
  // address or an exact name ("claude" completing to claude.ai, a workspace named "codex"): those
  // keep Return and the starts list under them.
  const agentFound = agentRows(query, context);
  const agent = top && agentFound.named ? { ...agentFound, named: false } : agentFound;
  const named = agent.named ? agent.launch : [];
  // What Return takes and what follows it, before the sections: a sure command first, then the
  // named starts, then the lead (an address or exact name, Ask; the web search with no agent). An
  // agent's folder start and a tab or workspace named exactly the text keep Return over Run.
  const searchLeads = !ask.length && !top;
  const lead = searchLeads
    ? search
    : !ask.length
      ? [top!]
      : top
        ? order === "chat"
          ? [...ask, top]
          : [top, ...ask]
        : ask;
  const runLeads = (likeness === "command" || likeness === "agent") && !named.length && !(top && !addressTop);
  const head = runLeads
    ? [...run, ...lead]
    : named.length
      ? [...named, ...run, ...lead]
      : [...lead.slice(0, 1), ...run, ...lead.slice(1)];
  // The rows under the head share what is left of MAX_SUGGESTIONS (the web search counts): one row
  // per section in turn, so each section the text finds keeps a row and no section's many push the
  // others out; each keeps its own order. The tabs, workspaces and pages keep their cap together.
  const kept = ranked(rest, context.omnibar.uses).slice(0, cap);
  const below = share(
    [
      kept.filter((row) => rowSection(row) === "open"),
      agent.named ? [] : agent.launch.slice(0, MAX_UNNAMED_LAUNCH_ROWS),
      kept.filter((row) => rowSection(row) !== "open"),
    ],
    MAX_SUGGESTIONS - head.length - search.length,
  );
  // No agent to ask: a question or a word is searched, an address still opens first.
  return [...head, ...below, ...actions, ...(searchLeads ? [] : search)];
}

/// Up to `room` rows from `sections`, taken one per section in turn, listed section by section.
function share(sections: readonly (readonly ScreenRow[])[], room: number): ScreenRow[] {
  const counts = sections.map(() => 0);
  for (let taken = 0, more = true; more && taken < room;) {
    more = false;
    for (let index = 0; index < sections.length && taken < room; index += 1) {
      if (counts[index]! >= sections[index]!.length) continue;
      counts[index]! += 1;
      taken += 1;
      more = true;
    }
  }
  return sections.flatMap((rows, index) => rows.slice(0, counts[index]));
}

/// The agent starts the text names (launchRows.ts); `named` when the text named an agent, so its
/// starts lead.
function agentRows(
  query: string,
  context: ScreenAgentSources & { home?: string },
): { launch: ScreenRow[]; named: boolean } {
  if (!context.agents?.length) return { launch: [], named: false };
  const launch = launchRows(query, {
    agents: context.agents,
    folders: context.folders ?? [],
    ...(context.defaultAgent ? { defaultAgent: context.defaultAgent } : {}),
    ...(context.home ? { home: context.home } : {}),
    ...(context.listing ? { listing: context.listing } : {}),
  });
  return { launch: launch.rows, named: launch.named && launch.rows.length > 0 };
}

/// The Commands palette actions the text names, best match first (the palette's order breaks
/// ties): a title or keyword starting with it, or for 3+ characters containing it.
export function actionRows(query: string, omnibar: OmnibarContext, limit = MAX_ACTION_ROWS): ScreenRow[] {
  const actions = omnibar.actions ?? [];
  if (!actions.length || !query) return [];
  const uses = omnibar.uses ?? {};
  const needle = query.trim().toLowerCase();
  // Every palette action's title and keywords lowercased once per list, not on every key (2,000 of
  // them: the keystroke's largest pass, foldedTexts).
  const folded = foldedTexts(actions, "actions", (list) =>
    list.map((action) => [action.title, ...action.keywords].map((text) => text.toLowerCase())),
  );
  const score = (index: number) => {
    let best = 0;
    for (const text of folded[index]!) {
      best = Math.max(best, foldedScore(needle, text));
      if (best === 3) break;
    }
    return best;
  };
  return (
    actions
      .map((action, index) => ({ action, index, score: score(index), used: 0 }))
      .filter((entry) => entry.score >= 2 || (entry.score > 0 && query.length >= SUBSTRING_MATCH_LENGTH))
      .map((entry) => ({ ...entry, used: uses[`action:${entry.action.id}`] ?? 0 }))
      // Within a match tier, the palette's pick history: what the person runs often and lately first.
      .sort((a, b) => b.score - a.score || b.used - a.used || a.index - b.index)
      .slice(0, limit)
      .map(({ action }): ScreenRow => ({
        type: "action",
        id: action.id,
        title: action.title,
        ...(action.detail ? { detail: action.detail } : {}),
        ...(action.keycaps ? { keycaps: action.keycaps } : {}),
        ...(action.symbol ? { symbol: action.symbol } : {}),
      }))
  );
}

/// Whether `query` is a site's whole first name or reads as a host, for the completion `row`.
function namesSite(query: string, row: ScreenRow | undefined): boolean {
  if (!row || (row.type !== "open" && row.type !== "history")) return false;
  const needle = bareAddress(query.toLowerCase());
  return needle.includes(".") || canonicalAddress(row.url).toLowerCase().startsWith(`${needle}.`);
}

/// The row named exactly what was typed, any case: a workspace by its name first ("app-efficiency"),
/// then a tab by its title as the host sent it (before the row cleaned it), then a tab in a
/// workspace of that name (a terminal tab titled "~" lists under its workspace's name).
function exactMatch(query: string, rows: readonly ScreenRow[], omnibar: OmnibarContext): ScreenRow | undefined {
  const needle = query.toLocaleLowerCase();
  const named = (name: string | undefined) => name?.trim().toLocaleLowerCase() === needle;
  const tab = (row: ScreenRow) =>
    row.type === "tab" ? omnibar.tabs.find((candidate) => candidate.id === row.id) : undefined;
  return (
    rows.find((row) => row.type === "workspace" && named(row.title)) ??
    rows.find((row) => row.type === "tab" && (named(row.title) || named(tab(row)?.title))) ??
    rows.find((row) => row.type === "tab" && named(tab(row)?.workspace))
  );
}

/// The row Return takes before Down or Ctrl-N: the top one, what the text reads as. A question
/// with no agent to ask has the web search on top, and Return takes it.
export function defaultSelection(rows: readonly ScreenRow[]): number {
  return rows[0] ? 0 : -1;
}

/// The row Return takes for the text, the one path Return, Send and the composer's Return hint
/// read: the highlighted row (`current`) of the shown `rows`; with the list closed, the top of
/// `suggested` (closed suggestions still answer Return: "reddit" opens reddit.com); with no row
/// highlighted (↑ from the top row), the top one when the text is an address, since an address is
/// never sent as a prompt. Staged files make Return send a prompt unless the row asks or creates
/// (navigation keeps them in the chat). Undefined: Return sends the text as a prompt.
export function returnRow(
  rows: readonly ScreenRow[],
  suggested: readonly ScreenRow[],
  current: number,
  context: { address: boolean; attachments: number },
): { row: ScreenRow | undefined; takes: boolean } {
  const list = rows.length ? rows : suggested;
  const opensTop = !rows.length || (current < 0 && context.address);
  const row = opensTop ? list[defaultSelection(list)] : rows[current];
  const takes = !!row && (context.attachments === 0 || row.type === "ask" || row.type === "create");
  return { row, takes };
}

/// Whether the top row is Ask for the agent selected in the composer's model chip.
export function promptLeads(rows: readonly ScreenRow[], harness: string | undefined): boolean {
  const top = rows[0];
  return top?.type === "ask" && top.harness === harness;
}

/// The inline address completion accepted by Right or End. Only a top row that is an address and
/// extends the typed prefix qualifies: an open result (the typed address or a top site) or a visited
/// page (history, as Chrome's omnibox completes it). Prompt, search, tab and workspace rows stay
/// explicit picks. Accepting only fills the field; Enter or Send still opens it. Keeping this pure
/// lets the New Tab field and its tests share the same safety rule.
export function inlineCompletion(text: string, rows: readonly ScreenRow[]): string | undefined {
  const query = text.trim();
  const row = rows[0];
  const completion =
    row?.type === "open"
      ? row.text
      : row?.type === "history"
        ? canonicalAddress(row.url)
        : row?.type === "launch"
          ? row.fill
          : undefined;
  if (!query || !completion || completion.length <= query.length) return undefined;
  if (!completion.toLocaleLowerCase().startsWith(query.toLocaleLowerCase())) return undefined;
  return completion;
}

/// Whether Return on `text` with no row is an address (it never becomes a prompt).
export function isAddress(text: string, home?: string): boolean {
  return classifyNewTabInput(text, home ? { home } : {}).kind === "url";
}

/// Whether `text` is refused outright (an old pairing link): it never becomes a prompt, a search
/// or an address, and Return hands it to the host only to show the refusal.
export function pairingLinkRefused(text: string): boolean {
  return classifyNewTabInput(text).kind === "refused";
}

function matches(query: string, omnibar: OmnibarContext): ScreenRow[] {
  // Tabs, workspaces and pages compete for the rows (no chat, folder or command). A tab or visit
  // still on a blank page is nowhere to go: it showed as "about:blank workspace-N".
  const navigable: OmnibarContext = {
    ...EMPTY_OMNIBAR,
    tabs: omnibar.tabs.filter((tab) => !blankPage(tab.title) && !blankPage(tab.detail)),
    workspaces: omnibar.workspaces,
    history: omnibar.history.filter((entry) => !blankPage(entry.url)),
  };
  return omnibarRows(query, "browser", navigable)
    .filter((row) => query.length >= SUBSTRING_MATCH_LENGTH || matchScore(query, ...matchTexts(row)) >= 2)
    .flatMap((row) => screenRow(row, omnibar));
}

/// What a row matches by, as omnibarRows reads it.
function matchTexts(row: OmnibarRow): (string | undefined)[] {
  if (row.type === "tab" || row.type === "workspace") return [row.title, row.detail];
  if (row.type === "history") return [row.title, row.url.replace(/^https?:\/\/(www\.)?/, "")];
  return [];
}

/// Visited pages, then top sites, whose address starts with the typed word.
function completions(query: string, omnibar: OmnibarContext): ScreenRow[] {
  if (query.length < MIN_COMPLETION_LENGTH || /\s/.test(query)) return [];
  const needle = bareAddress(query.toLowerCase());
  const visited = omnibar.history
    .filter((entry) => /^https?:/i.test(entry.url) && canonicalAddress(entry.url).toLowerCase().startsWith(needle))
    .map((entry) => historyRow(entry));
  const sites = TOP_SITES.filter((site) => site.startsWith(needle)).map((site): ScreenRow => ({
    type: "open",
    url: `https://${site}`,
    text: site,
  }));
  return suggestions([...visited, ...sites], EMPTY_OMNIBAR).slice(0, MAX_COMPLETIONS);
}

/// `about:blank` and the other internal pages.
function blankPage(text: string | undefined): boolean {
  return !!text && /^about:/i.test(text.trim());
}

/// `reddit.com/r/x` for `https://www.reddit.com/r/x/`: what two addresses compare by.
function bareAddress(url: string): string {
  return url
    .replace(/^https?:\/\//i, "")
    .replace(/^www\./i, "")
    .replace(/\/$/, "");
}

/// `reddit.com` for `https://www.reddit.com/?solution=<token>&utm_source=x#top`: what two pages
/// compare by and what a row shows. The scheme, `www.`, the fragment, a trailing slash and the
/// parameters that only track or carry a one-off token go; the ones that name the page stay.
export function canonicalAddress(url: string): string {
  const text = url.trim();
  let parsed: URL;
  try {
    parsed = new URL(/^[a-z][a-z0-9+.-]*:/i.test(text) ? text : `https://${text}`);
  } catch {
    return bareAddress(text.toLowerCase());
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return text;
  const parameters = [...parsed.searchParams];
  const challenge = parameters.some(([name]) => /_challenge$|^__cf_chl_/i.test(name));
  const kept = parameters.filter(
    ([name]) => !NOISE_PARAMETER.test(name) && !(challenge && CHALLENGE_ANSWER.test(name)),
  );
  const query = new URLSearchParams(kept).toString();
  const host = parsed.hostname.replace(/^www\./, "") + (parsed.port ? `:${parsed.port}` : "");
  return `${host}${parsed.pathname.replace(/\/+$/, "")}${query ? `?${query}` : ""}`;
}

/// Parameters that only track the click or carry a bot check's one-off answer (reddit's
/// `?solution=…&js_challenge=1`). An id, a list, a query, a commit or a page token names the page:
/// it stays.
const NOISE_PARAMETER =
  /^(utm_\w+|fbclid|gclid|dclid|gbraid|wbraid|msclkid|yclid|twclid|igshid|mc_[ce]id|_ga|_gl|_hsenc|_hsmi|mkt_tok|ref_src|ref_url|si|spm|\w*_challenge|__cf_chl_\w+)$/i;
/// A bot check's answer, noise only beside the check's own parameter.
const CHALLENGE_ANSWER = /^(solution|token)$/i;

/// The host a row shows for a page: `reddit.com`.
/// A page not on the web shows its path.
export function shortHost(address: string): string {
  if (/^file:/i.test(address.trim())) return address.trim().replace(/^file:\/\//i, "");
  return canonicalAddress(address).split(/[/?]/)[0] ?? address;
}

const TITLE_SEPARATOR = /\s+[-|·—–]\s+/g;

/// A page's title without its site's tagline on its front page ("Reddit - The heart of the
/// internet" is "Reddit"; off it, "GitHub - owner/repo" names the page) or its trailing site name
/// ("Borrowing in loops : r/rust - Reddit"): the row shows the host.
export function cleanTitle(title: string, url: string): string {
  const labels = shortHost(url).split(":")[0]!.split(".");
  const site = labels.length > 1 ? labels[labels.length - 2] : labels[0];
  const cuts = [...title.matchAll(TITLE_SEPARATOR)];
  const first = cuts[0];
  const last = cuts.at(-1);
  if (!site || !first || !last) return title;
  const word = (part: string) => part.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
  const head = title.slice(0, first.index).trim();
  const front = !/[/?]/.test(canonicalAddress(url));
  if (front && head && word(head) === site) return head;
  const rest = title.slice(0, last.index).trim();
  if (rest && word(title.slice(last.index + last[0].length)) === site) return rest;
  return title;
}

/// One row per page and per tab or workspace, the first one staying, where a page an open browser
/// tab shows is that tab.
function suggestions(rows: ScreenRow[], omnibar: OmnibarContext): ScreenRow[] {
  const tabs = new Map<string, ScreenRow>();
  for (const tab of omnibar.tabs) {
    const row = tabRow(tab);
    if (row.url && !tabs.has(row.url)) tabs.set(row.url, row);
  }
  const seen = new Set<string>();
  return rows
    .map((row) => (row.type === "open" || row.type === "history" ? (tabs.get(canonicalAddress(row.url)) ?? row) : row))
    .filter((row) => {
      const keys = rowKeys(row);
      if (keys.some((key) => seen.has(key))) return false;
      for (const key of keys) seen.add(key);
      return true;
    });
}

function rowKeys(row: ScreenRow): string[] {
  switch (row.type) {
    case "open":
    case "history":
      return [`url:${canonicalAddress(row.url)}`];
    case "tab":
      return [`tab:${row.id}`, ...(row.url ? [`url:${row.url}`] : [])];
    case "workspace":
      return [`workspace:${row.id}`];
    default:
      return [row.type];
  }
}

/// Open tabs, then workspaces, then pages to open. Inside each kind, the palette's pick history
/// (`uses`, the Commands palette's FrecencyStore): what the person picks often and lately first, then
/// the order the rows came in.
function ranked(rows: ScreenRow[], uses: Record<string, number> = {}): ScreenRow[] {
  const rank = (row: ScreenRow) => (row.type === "tab" ? 0 : row.type === "workspace" ? 1 : 2);
  const used = (row: ScreenRow) =>
    row.type === "tab"
      ? (uses[`tab:${row.id}`] ?? 0)
      : row.type === "workspace"
        ? (uses[`workspace:${row.id}`] ?? 0)
        : 0;
  return rows
    .map((row, index) => ({ row, index, used: used(row) }))
    .sort((a, b) => rank(a.row) - rank(b.row) || b.used - a.used || a.index - b.index)
    .map((entry) => entry.row);
}

/// A browser tab by its page (a clean title, the host); another tab by its workspace and detail.
function tabRow(tab: OmnibarContext["tabs"][number]): Extract<ScreenRow, { type: "tab" }> {
  const icon = tab.icon ? { icon: tab.icon } : {};
  if (tab.kind === "browser") {
    const address = tab.detail ?? tab.title;
    const url = canonicalAddress(address);
    const title = tab.title === address ? url : cleanTitle(tab.title, address);
    return { type: "tab", id: tab.id, title, detail: shortHost(address), ...icon, url };
  }
  const detail = [tab.workspace, tab.detail].filter(Boolean).join(" · ");
  return { type: "tab", id: tab.id, title: tab.title, ...(detail ? { detail } : {}), ...icon };
}

function historyRow(entry: OmnibarContext["history"][number]): ScreenRow {
  return {
    type: "history",
    url: entry.url,
    ...(entry.title ? { title: cleanTitle(entry.title, entry.url) } : {}),
    ...(entry.icon ? { icon: entry.icon } : {}),
  };
}

function screenRow(row: OmnibarRow, omnibar: OmnibarContext): ScreenRow[] {
  switch (row.type) {
    case "tab": {
      const tab = omnibar.tabs.find((candidate) => candidate.id === row.id);
      return tab ? [tabRow(tab)] : [];
    }
    case "workspace":
      return [{ type: "workspace", id: row.id, title: row.title, ...(row.detail ? { detail: row.detail } : {}) }];
    case "history":
      return [historyRow(row)];
    default:
      return [];
  }
}

/// `!` typed into an empty field (or over a wholly selected one, a location the page put
/// there): shell mode, with the rest of the edit as the command typed so far. Anything else
/// stays as typed.
export function shellEntry(
  previous: string,
  next: string,
  previousWasSelected: boolean,
): { command: string } | undefined {
  if (previous !== "" && !previousWasSelected) return undefined;
  if (!next.startsWith(TERMINAL_PREFIX)) return undefined;
  return { command: next.slice(TERMINAL_PREFIX.length).replace(/^\s+/, "") };
}

export type ChatCard = {
  sessionId: string;
  /// A device chat from the acpmux chat index (`harness:sessionId`): opens through the host's
  /// shared Open Chat path (`chats.open`), not as an acpmux session.
  chatKey?: string;
  /// The harness chat's own id (a session's agent session id, a device chat key's `harness:` tail):
  /// the same chat under either source, so a session replacing its device row is not a new row.
  chatId?: string;
  title: string;
  harness?: string;
  age: string;
  message?: string;
  /// `failed`: its last turn failed (the chat itself is fine); `error`: it lost its agent.
  state: "idle" | "input" | "running" | "failed" | "error" | "unread";
  /// Its log is in acpmux's cold archive: the card is drawn from the preview alone (its last
  /// message), badged Compressed; opening it brings the log back.
  archived?: true;
  /// The chats its agent started (acpmux `spawnedBy`, a device chat's `parent`), newest first:
  /// listed under it, never on their own.
  children?: ChatCard[];
};

/// The newest chats, the ones waiting on the user first; a dropped chat is an error card. acpmux's
/// own sessions come first (they carry live state, and the name the user gave); the device chat
/// index (the sidebar's All chats source) fills the rest, newest first, without a chat a session
/// card shows: the same harness chat (its `harness:id` key holds the session's agent session id,
/// Leo 2026-10-13: each lane showed twice, once by name and once by its first prompt), or the
/// same title. With `fold` (the list layout) a chat another chat's agent started lists under that
/// chat's card (`children`); the card grid has no room for that, so there every chat has a card.
export function recentChatCards(
  sessions: AcpmuxSnapshot["sessions"],
  now = Date.now(),
  t: Translate = translate,
  device: DeviceChat[] = [],
  count = CHAT_CARD_COUNT,
  fold = true,
): ChatCard[] {
  const live = liveChatCards(sessions, now, t, count, fold);
  const shown = new Set(live.map((card) => card.title.trim().toLowerCase()));
  // Every session's, an archived one's too: its transcript must not come back as a device chat.
  const agents = new Set(
    sessions.flatMap((session) => {
      const id = normalizedSessionEntry(session as Parameters<typeof normalizedSessionEntry>[0]).agentSessionId;
      return id ? [id] : [];
    }),
  );
  const fill = [...device]
    .sort((a, b) => b.updatedAt - a.updatedAt || a.key.localeCompare(b.key))
    .filter((chat) => !(fold && chat.parent) && !agents.has(chat.key.slice(chat.key.indexOf(":") + 1)))
    .filter((chat) => !shown.has((chat.title ?? "").trim().toLowerCase()))
    .slice(0, Math.max(0, count - live.length))
    .map((chat): ChatCard => ({
      sessionId: chat.key,
      chatKey: chat.key,
      chatId: chat.key.slice(chat.key.indexOf(":") + 1),
      title: chat.title ?? t("sidebar.newChat"),
      harness: chat.harness,
      age: ageLabel(chat.updatedAt, now, t),
      state: "idle",
    }));
  const cards = [...live, ...fill];
  if (!fold) return cards;
  const parents = new Set(cards.flatMap((card) => [card.sessionId, card.chatKey].filter((id): id is string => !!id)));
  const children = indexChildren(sessions, device, now, t, parents);
  return cards.map((card) => withChildren(card, children));
}

/// The cards a template's page draws (`sections`): none, with no pass over the chats, on a page
/// that lists none (Minimal, the default, and Composer). Leo 2026-11-18, on New Tab sorting every
/// chat and carding about 2,500 child chats behind Minimal: "We literally don't even have that as
/// a visible option at all anymore".
export function pageChatCards(
  sections: ScreenSections,
  sessions: AcpmuxSnapshot["sessions"],
  now: number,
  t: Translate,
  device: DeviceChat[],
): ChatCard[] {
  if (sections.chats === "none") return NO_CHAT_CARDS;
  return recentChatCards(sessions, now, t, device, sections.recent, sections.chats === "list");
}

const NO_CHAT_CARDS: ChatCard[] = [];

/// The stage layout's needs-you rows (NewTabScreen's suggestions card).
export const MAX_NEEDS_YOU = 3;

/// The chats waiting on the user (asking for input, or hit an error or lost their agent), newest
/// first, picked from every chat before the cap: an older one is never hidden behind newer idle
/// chats, as `recentChatCards`' trimmed list would hide it.
export function needsYouCards(
  sessions: AcpmuxSnapshot["sessions"],
  now: number,
  t: Translate,
  count = MAX_NEEDS_YOU,
): ChatCard[] {
  // One pass keeps the waiting chats (sessionCard's state, read without building a card); only
  // those few are sorted and carded, never the whole list (greptile on #22119).
  const waiting = sessions.filter((raw) => {
    const session = normalizedSessionEntry(raw as Parameters<typeof normalizedSessionEntry>[0]);
    if (session.indicator === "failed") return true;
    const mark = sessionMark(session, false);
    return mark === "input" || mark === "error";
  });
  return liveChatCards(waiting, now, t, count, false);
}

function liveChatCards(
  sessions: AcpmuxSnapshot["sessions"],
  now: number,
  t: Translate,
  count: number,
  fold: boolean,
): ChatCard[] {
  return recentSessions(sessions, count, fold).map((session) => sessionCard(session, now, t));
}

function sessionCard(session: AcpmuxSessionEntry, now: number, t: Translate): ChatCard {
  // An archived chat's card reads its cold preview only: its last message.
  const cold = session.coldArchive;
  const message = cold ? (cold.last.at(-1)?.text ?? session.preview) : session.preview;
  return {
    sessionId: session.sessionId,
    title: session.displayTitle ?? session.sessionId,
    ...(session.agentSessionId ? { chatId: session.agentSessionId } : {}),
    ...(session.harness ? { harness: session.harness } : {}),
    age: ageLabel(activityTime(session), now, t),
    ...(message ? { message } : {}),
    state: session.indicator === "failed" ? "failed" : (sessionMark(session, false) ?? "idle"),
    ...(cold && { archived: true as const }),
  };
}

/// Child rows indexed once per snapshot, so each visible card does not rescan every session.
type ChildCard = { parent: string; at: number; card: ChatCard };

/// Only the shown cards' children (`parents`) get a card: thousands of child chats under parents
/// past the cut cost one pass, not a card each.
function indexChildren(
  sessions: AcpmuxSnapshot["sessions"],
  device: DeviceChat[],
  now: number,
  t: Translate,
  parents: ReadonlySet<string>,
): Map<string, ChildCard[]> {
  const indexed = new Map<string, ChildCard[]>();
  for (const raw of sessions) {
    const session = normalizedSessionEntry(raw as Parameters<typeof normalizedSessionEntry>[0]);
    if (!session.spawnedBy || !parents.has(session.spawnedBy)) continue;
    if (!listed(session) || sessionMark(session, false) === "input") continue;
    const child = { parent: session.spawnedBy, at: activityTime(session) ?? 0, card: sessionCard(session, now, t) };
    indexed.set(session.spawnedBy, [...(indexed.get(session.spawnedBy) ?? []), child]);
  }
  for (const chat of device) {
    if (!chat.parent || !parents.has(chat.parent)) continue;
    const child = {
      parent: chat.parent,
      at: chat.updatedAt,
      card: {
        sessionId: chat.key,
        chatKey: chat.key,
        chatId: chat.key.slice(chat.key.indexOf(":") + 1),
        title: chat.title ?? t("sidebar.newChat"),
        harness: chat.harness,
        age: ageLabel(chat.updatedAt, now, t),
        state: "idle",
      } satisfies ChatCard,
    };
    indexed.set(chat.parent, [...(indexed.get(chat.parent) ?? []), child]);
  }
  return indexed;
}

function withChildren(card: ChatCard, indexed: Map<string, ChildCard[]>): ChatCard {
  const parents = [...new Set([card.sessionId, card.chatKey].filter((id): id is string => Boolean(id)))];
  const children = parents
    .flatMap((parent) => indexed.get(parent) ?? [])
    .sort((a, b) => b.at - a.at || a.card.sessionId.localeCompare(b.card.sessionId))
    .map((child) => child.card);
  return children.length > 0 ? { ...card, children } : card;
}
