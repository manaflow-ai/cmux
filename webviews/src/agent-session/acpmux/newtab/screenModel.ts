// The new tab screen's pure state (variant B, plans/cmux-next/new-tab.md sections 3-4): the
// rows under the field for the typed text, the `!` conversion and the chat cards. No React, no
// host: NewTabScreen renders what these return.
import type { AcpmuxSnapshot } from "../model";
import { ageLabel, recentSessions } from "../NewTabPage";
import { EMPTY_OMNIBAR, matchScore, omnibarRows, type OmnibarContext, type OmnibarRow } from "../omnibar";
import { activityTime, listed, normalizedSessionEntry, sessionMark, type AcpmuxSessionEntry } from "../sessionList";
import { classifyNewTabInput, TERMINAL_PREFIX } from "../newTabIntent";
import { type Translate, translate } from "../i18n";
import type { DeviceChat } from "./deviceChats";
import { translateNewTab } from "./strings";
import { DEFAULT_SUGGESTION_ORDER, type SuggestionOrder } from "./suggestionOrder";
import { TOP_SITES } from "./topSites";

export type ScreenAgent = { id: string; name: string };

/// A row in the field's popover. The omnibar (Leo 2026-10-12, over cx-e2aa's addresses-only rows):
/// URL completions from visited pages and top sites, the open tabs and workspaces that match,
/// "Search the web for …" and "Ask <agent>". The top row is Return's.
export type ScreenRow =
  /// Search the web for `text` (the browser's search engine).
  | { type: "search"; text: string }
  /// Load `url` (what `text` resolved to, or a top site that completes it).
  | { type: "open"; url: string; text: string }
  /// An open tab; `url` is a browser tab's page as `canonicalAddress` gives it.
  | { type: "tab"; id: string; title: string; detail?: string; icon?: string; url?: string }
  | { type: "workspace"; id: string; title: string; detail?: string }
  | { type: "history"; url: string; title?: string; icon?: string }
  /// A Commands palette action (Cmd-Shift-P) the host runs (`app.action`); `detail` is its section.
  | { type: "action"; id: string; title: string; detail?: string; keycaps?: string[] }
  /// The text as a prompt to `harness`, named `agent` (its `model` when known).
  | { type: "ask"; text: string; harness: string; agent: string; model?: string }
  /// A create action (cx-ag5.7): New terminal, New browser tab or New chat, as under the field.
  /// `strip`: drawn in the quiet strip under the rows, not as a row; still in the arrow keys' order.
  | { type: "create"; kind: CreateKind; strip?: true };

/// What a create row opens, in the order the rows list them.
export type CreateKind = "terminal" | "browser" | "chat";

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

/// The popover's rows. Empty text and `!`: none. Then the top hit (what Return takes, see
/// SuggestionOrder), the matching open tabs, workspaces and visited pages, and the web search
/// last (none for a local file): a fallback, never the default while an agent can be asked. With
/// no agent, plain text searches. One row per page: a page an open tab shows is that tab ("Switch
/// to tab"), and addresses compare without their tracking parameters. The create actions (Leo
/// 2026-10-18: one Down or one click away while the list shows) end the list outside the cap:
/// `chat` lists all three as rows; `intent` lists the ones the text names ("new", "term") as rows
/// and the others as `strip` rows, one quiet line under the rows; `minimal` none.
export function screenRows(
  text: string,
  context: {
    omnibar: OmnibarContext;
    home?: string;
    ask?: ScreenAsk;
    create?: readonly CreateKind[];
    /// The create actions' names in the pane's language (English when unset).
    createNames?: Partial<Record<CreateKind, string>>;
    order?: SuggestionOrder;
  },
): ScreenRow[] {
  const rows = navigationRows(text, context);
  if (!rows.length) return rows;
  const order = context.order ?? DEFAULT_SUGGESTION_ORDER;
  const create = order === "minimal" ? [] : (context.create ?? []);
  if (order === "chat") return [...rows, ...create.map((kind): ScreenRow => ({ type: "create", kind }))];
  const named = create.filter((kind) => namesCreate(text, kind, context.createNames?.[kind]));
  return [
    ...rows,
    ...named.map((kind): ScreenRow => ({ type: "create", kind })),
    ...create.filter((kind) => !named.includes(kind)).map((kind): ScreenRow => ({ type: "create", kind, strip: true })),
  ];
}

/// Whether `row` is drawn in the strip under the rows.
export function inStrip(row: ScreenRow): boolean {
  return row.type === "create" && row.strip === true;
}

function navigationRows(
  text: string,
  context: { omnibar: OmnibarContext; home?: string; ask?: ScreenAsk; order?: SuggestionOrder },
): ScreenRow[] {
  const intent = classifyNewTabInput(text, context.home ? { home: context.home } : {});
  // A pairing link offers nothing: no search, no Ask, no address, no create row (they carry the text).
  if (intent.kind === "none" || intent.kind === "terminal" || intent.kind === "refused") return [];
  const order = context.order ?? DEFAULT_SUGGESTION_ORDER;
  const query = text.trim();
  const search: ScreenRow[] =
    intent.kind === "url" && intent.url.startsWith("file:") ? [] : [{ type: "search", text: query }];
  const ask: ScreenRow[] = context.ask ? [{ type: "ask", text: query, ...context.ask }] : [];
  const open: ScreenRow[] = intent.kind === "url" ? [{ type: "open", url: intent.url, text: query }] : [];
  const completed = completions(query, context.omnibar);
  const found = suggestions([...open, ...completed, ...matches(query, context.omnibar)], context.omnibar);
  // What leads above Ask: the address, the page a site's whole name or a host-like word completes
  // ("reddit", "reddit.c"; "reddi" or "app" ask), or a tab or workspace named exactly that.
  const top = open.length || namesSite(query, completed[0]) ? found[0] : exactMatch(query, found, context.omnibar);
  const rest = found.filter((row) => row !== top);
  const cap = order === "minimal" ? MINIMAL_MATCH_ROWS : MAX_MATCH_ROWS;
  const fit = (lead: ScreenRow[]) =>
    ranked(rest).slice(0, Math.min(cap, MAX_SUGGESTIONS - lead.length - search.length));
  // No agent to ask: a question or a word is searched, an address still opens first.
  if (!ask.length) {
    if (!top) return [...search, ...fit(search), ...actionRows(query, context.omnibar)];
    return [top, ...fit([top]), ...actionRows(query, context.omnibar), ...search];
  }
  const lead = top ? (order === "chat" ? [...ask, top] : [top, ...ask]) : ask;
  return [...lead, ...fit(lead), ...actionRows(query, context.omnibar), ...search];
}

/// The Commands palette actions the text names, best match first (the palette's order breaks
/// ties): a title or keyword starting with it, or for 3+ characters containing it.
export function actionRows(query: string, omnibar: OmnibarContext, limit = MAX_ACTION_ROWS): ScreenRow[] {
  const actions = omnibar.actions ?? [];
  if (!actions.length || !query) return [];
  return actions
    .map((action, index) => ({ action, index, score: matchScore(query, action.title, ...action.keywords) }))
    .filter((entry) => entry.score >= 2 || (entry.score > 0 && query.length >= SUBSTRING_MATCH_LENGTH))
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, limit)
    .map(({ action }): ScreenRow => ({
      type: "action",
      id: action.id,
      title: action.title,
      ...(action.detail ? { detail: action.detail } : {}),
      ...(action.keycaps ? { keycaps: action.keycaps } : {}),
    }));
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

/// Whether the text starts the create action's name (`name`, else English) or a word of it ("new",
/// "term", "brow"). The English name always counts.
function namesCreate(text: string, kind: CreateKind, name?: string): boolean {
  const query = text.trim();
  if (query.length < 2) return false;
  return matchScore(query, name, translateNewTab(CREATE_KEYS[kind], {}, "en")) >= 2;
}

const CREATE_KEYS = { terminal: "create.terminal", browser: "create.browser", chat: "create.chat" } as const;

/// The row Return takes before Down or Ctrl-N: the top one, what the text reads as. A question
/// with no agent to ask has the web search on top, and Return takes it.
export function defaultSelection(rows: readonly ScreenRow[]): number {
  return rows[0] ? 0 : -1;
}

/// The inline address completion accepted by Right or End. Only a top row that is an address and
/// extends the typed prefix qualifies: an open result (the typed address or a top site) or a visited
/// page (history, as Chrome's omnibox completes it). Prompt, search, tab and workspace rows stay
/// explicit picks. Accepting only fills the field; Enter or Send still opens it. Keeping this pure
/// lets the New Tab field and its tests share the same safety rule.
export function inlineCompletion(text: string, rows: readonly ScreenRow[]): string | undefined {
  const query = text.trim();
  const row = rows[0];
  const completion = row?.type === "open" ? row.text : row?.type === "history" ? canonicalAddress(row.url) : undefined;
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

/// Open tabs, then workspaces, then pages to open; the order inside each kind stays.
function ranked(rows: ScreenRow[]): ScreenRow[] {
  const rank = (row: ScreenRow) => (row.type === "tab" ? 0 : row.type === "workspace" ? 1 : 2);
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => rank(a.row) - rank(b.row) || a.index - b.index)
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
  const children = indexChildren(sessions, device, now, t);
  return cards.map((card) => withChildren(card, children));
}

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
  return {
    sessionId: session.sessionId,
    title: session.displayTitle ?? session.sessionId,
    ...(session.agentSessionId ? { chatId: session.agentSessionId } : {}),
    ...(session.harness ? { harness: session.harness } : {}),
    age: ageLabel(activityTime(session), now, t),
    ...(session.preview ? { message: session.preview } : {}),
    state: session.indicator === "failed" ? "failed" : (sessionMark(session, false) ?? "idle"),
  };
}

/// Child rows indexed once per snapshot, so each visible card does not rescan every session.
type ChildCard = { parent: string; at: number; card: ChatCard };

function indexChildren(
  sessions: AcpmuxSnapshot["sessions"],
  device: DeviceChat[],
  now: number,
  t: Translate,
): Map<string, ChildCard[]> {
  const indexed = new Map<string, ChildCard[]>();
  for (const raw of sessions) {
    const session = normalizedSessionEntry(raw as Parameters<typeof normalizedSessionEntry>[0]);
    if (!session.spawnedBy || !listed(session) || sessionMark(session, false) === "input") continue;
    const child = { parent: session.spawnedBy, at: activityTime(session) ?? 0, card: sessionCard(session, now, t) };
    indexed.set(session.spawnedBy, [...(indexed.get(session.spawnedBy) ?? []), child]);
  }
  for (const chat of device) {
    if (!chat.parent) continue;
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
