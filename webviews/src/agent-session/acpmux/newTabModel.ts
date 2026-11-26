import { seedLastPicks } from "./lastPick";
import type { AcpmuxSnapshot } from "./model";
import { MAX_NEW_TAB_ENTRIES, omnibarContext, type OmnibarContext, type OmnibarRow } from "./omnibar";
import {
  activityTime,
  folded,
  listed,
  normalizedSessionEntry,
  sessionMark,
  type AcpmuxSessionEntry,
} from "./sessionList";
import { type StringKey, type Translate, translate } from "./i18n";
import { wholeNewTab } from "./newtab/sharedPart";
import { parseNewTabTemplate, type NewTabTemplate } from "./newtab/templates";
import { suggestionOrder, type SuggestionOrder } from "./newtab/suggestionOrder";
import { readClockStyle, type NewTabClockStyle } from "./newtab/clockModel";
import { isCloudPick, isStartableProject } from "./newtab/startedProject";
import { seedWarmNewTab } from "./newtab/warmSnapshot";
import { ageWithDate } from "./timeLabels";

/// The three things a new tab can become (#16620). Order is the switch's order and Tab's cycle.
export const TAB_KINDS = ["terminal", "browser", "agent"] as const;
export type TabKind = (typeof TAB_KINDS)[number];
/// The chat an Agent submit starts: the harness and model the page's chips show.
export type NewTabChat = { harness: string; model?: string };

/// The event the host dispatches on `window` for Focus Location Bar (Cmd-L).
export const FOCUS_LOCATION_EVENT = "acpmux-focus-location";

/// New tab page copy: keys of the pane's string table.
export const NEW_TAB_LABELS = {
  kinds: {
    terminal: "newTabPage.kind.terminal",
    browser: "newTabPage.kind.browser",
    agent: "newTabPage.kind.agent",
  } satisfies Record<TabKind, StringKey>,
  placeholder: {
    terminal: (t: Translate, folder: string) =>
      folder ? t("newTabPage.placeholder.terminalIn", { folder }) : t("newTabPage.placeholder.terminal"),
    browser: (t: Translate) => t("newTabPage.placeholder.browser"),
    agent: (t: Translate, agent: string) => t("newTabPage.placeholder.agent", { agent }),
  } satisfies Record<TabKind, (t: Translate, name: string) => string>,
  switchLabel: "newTabPage.switchLabel",
  /// `{kind}` is a tab kind's name, `{keys}` its shortcut.
  editShortcut: "newTabPage.editShortcut",
  open: "newTabPage.open",
  /// A refused open, by the kind that did not open.
  openFailedKind: {
    terminal: "newTabPage.openFailed.terminal",
    browser: "newTabPage.openFailed.browser",
    agent: "newTabPage.openFailed.agent",
  } satisfies Record<TabKind, StringKey>,
  openRetry: "retry.action",
  suggestions: "newTabPage.suggestions",
  rows: {
    tab: "newTabPage.row.tab",
    workspace: "newTabPage.row.workspace",
    session: "newTabPage.row.session",
    folder: "newTabPage.row.folder",
    command: "newTabPage.row.command",
    history: "newTabPage.row.history",
    run: "newTabPage.row.run",
    open: "newTabPage.row.open",
  } satisfies Record<Exclude<OmnibarRow["type"], "ask">, StringKey>,
  ask: "newTabPage.ask",
  allSessions: "newTabPage.allSessions",
  thisMac: "newTabPage.thisMac",
} as const;

/// What the host's handshake says about a tab opened as a new tab page.
export type NewTabHost = {
  inputToken?: string;
  hotkeys: Partial<Record<TabKind, string>>;
  initialKind: TabKind;
  cwd?: string;
  host?: string;
  location?: string;
  /// What a new chat of this window left when its tab opened another chat (cmux#32276): the
  /// field's draft, taken once; nothing sends it.
  draft?: string;
  /// Project folders found by the host scan, before session-derived folders.
  projects?: string[];
  omnibar?: OmnibarContext;
  /// The workspace's tabs a split's page offers to move into its pane (cx-jfo7).
  openTabs?: OmnibarContext["tabs"];
  /// Which design (Debug Settings `newTab.layout`): "b" the one-input screen (default),
  /// "a" this Terminal | Browser | Agent page, kept until B passes dogfood (decision Q6).
  layout: "a" | "b";
  /// The extension that draws in the slot over the composer (`tabs.newTabApp`: an app id with `cmux.newtab/1`,
  /// newtab/NewTabAppSlot.tsx); unset leaves the slot out. It never replaces the page.
  app?: string;
  /// The New Tab clock over the composer (`tabs.newTabClock.*`, newtab/NewTabClock.tsx); unset draws none.
  clock?: NewTabClockStyle;
  /// The saved template (`tabs.newTabTemplate`); unset follows `layout` (newtab/templates.ts).
  template?: NewTabTemplate;
  /// The agent last picked (decision Q3).
  lastAgent?: string;
  /// The project of the chat the person last picked and started (newtab/startedProject.ts).
  startedProject?: string;
  /// The folder or GitHub repository the person last started a Cloud chat in (newtab/startedProject.ts).
  cloudStartedProject?: string;
  /// The home folder, so `~/path` reads as a folder.
  home?: string;
  /// false: leave the field unfocused (Cmd-L opened the page for the omnibar, cx-e2aa).
  focusesField?: boolean;
  /// The page is agent history (the sidebar's History dot, cx-zlnl), not the New Tab page.
  history?: boolean;
  /// The page lists only its own connection's chats, not the store every page shares (another
  /// machine's page, newtab/chatStore.ts).
  privateChatLists?: boolean;
  /// The page's chats start on another machine (an inherited SSH or Cloud context: AgentPaneNewTab
  /// `warmedOnThisMac(false)`), known from the first render, before its client connects: a send naming
  /// `@computer-use` holds as that machine's, never this Mac's setup (CMUX-682).
  startsRemote?: boolean;
  /// false: Show All Chats on New Tab is off (`sidebar.showChats`): the page lists the recent chats
  /// only, never All chats. Unset lists All chats where the template does.
  allChats?: false;
  /// How the rows under the field rank (newtab/screenModel.ts SuggestionOrder); unset is the default.
  suggestionOrder?: SuggestionOrder;
  /// Where the page's new chat starts as the app already knows it (AgentPaneNewTabStart): drawn on
  /// the first frame; the handshake's answer from the store replaces it only when it differs.
  start?: NewTabStart;
};

/// A new chat's start before the store's answer: its folder, or none with Choose Folder… offered.
export type NewTabStart = { cwd?: string; chooseFolder: boolean };

function readNewTabStart(value: unknown): NewTabStart | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const { cwd, chooseFolder } = value as { cwd?: unknown; chooseFolder?: unknown };
  return {
    ...(typeof cwd === "string" && cwd.startsWith("/") ? { cwd } : {}),
    chooseFolder: chooseFolder === true,
  };
}

/// The app that draws in this New Tab page's slot (`tabs.newTabApp`): none on history, and none for the visit
/// (`adoptions`, one per Cmd-T adopt) whose app page could not show (`goneAt`). The next adopt tries
/// again, also on a parked spare that keeps its screen because its context did not change.
export function pickedNewTabApp(host: NewTabHost | undefined, goneAt: number | undefined, adoptions: number) {
  return host && !host.history && host.app && goneAt !== adoptions ? host.app : undefined;
}

const withClock = (clock: NewTabClockStyle | undefined) => (clock ? { clock } : {});

/// Reads `newTab` from the handshake: `true`, or `{hotkeys, kind, cwd, host}`. Nil for a plain chat.
/// A context that comes as the page's own part is joined with its shared part first (newtab/sharedPart.ts).
export function newTabHost(handshake: { newTab?: unknown; cwd?: unknown }): NewTabHost | undefined {
  const value = wholeNewTab(handshake.newTab);
  if (value !== true && (typeof value !== "object" || value === null)) return undefined;
  const object = (typeof value === "object" ? value : {}) as Record<string, unknown>;
  // The app's copy of the last picks: this page's own storage did not outlive the launch.
  seedLastPicks(object.lastPicks);
  // The chats a page of this Mac listed last: the Chats list's first frame (newtab/warmSnapshot.ts).
  seedWarmNewTab(object.warm);
  const keys = (typeof object.hotkeys === "object" && object.hotkeys !== null ? object.hotkeys : {}) as Record<
    string,
    unknown
  >;
  const hotkeys: Partial<Record<TabKind, string>> = {};
  for (const kind of TAB_KINDS) if (typeof keys[kind] === "string" && keys[kind]) hotkeys[kind] = keys[kind] as string;
  const initialKind = TAB_KINDS.includes(object.kind as TabKind) ? (object.kind as TabKind) : "agent";
  const cwd =
    typeof object.cwd === "string" ? object.cwd : typeof handshake.cwd === "string" ? handshake.cwd : undefined;
  const omnibar = omnibarContext(object.omnibar);
  const openTabs = Array.isArray(object.openTabs) ? omnibarContext({ tabs: object.openTabs })?.tabs : undefined;
  const template = parseNewTabTemplate(object.template);
  const order = suggestionOrder(object.suggestionOrder);
  const start = readNewTabStart(object.start);
  return {
    hotkeys,
    initialKind,
    ...(cwd ? { cwd } : {}),
    ...(typeof object.host === "string" ? { host: object.host } : {}),
    ...(typeof object.location === "string" && object.location ? { location: object.location } : {}),
    ...(typeof object.draft === "string" && object.draft.trim() ? { draft: object.draft } : {}),
    ...(omnibar ? { omnibar } : {}),
    ...(openTabs?.length ? { openTabs } : {}),
    ...(Array.isArray(object.projects)
      ? {
          projects: object.projects
            .filter((path): path is string => typeof path === "string" && path.length > 0)
            .slice(0, MAX_NEW_TAB_ENTRIES),
        }
      : {}),
    layout: object.layout === "a" ? "a" : "b",
    ...(template ? { template } : {}),
    // `tabs.newTabApp`, which the app sends only when it is an app id by the manifest's own
    // pattern (Swift NewTabAppSetting.isValidID), so the page does not check the rule again.
    ...(typeof object.app === "string" && object.app ? { app: object.app } : {}),
    ...withClock(readClockStyle(object.clock)),
    ...(typeof object.lastAgent === "string" && object.lastAgent ? { lastAgent: object.lastAgent } : {}),
    ...(isStartableProject(typeof object.startedProject === "string" ? object.startedProject : undefined)
      ? { startedProject: object.startedProject as string }
      : {}),
    ...(isCloudPick(typeof object.cloudStartedProject === "string" ? object.cloudStartedProject : undefined)
      ? { cloudStartedProject: object.cloudStartedProject as string }
      : {}),
    ...(typeof object.home === "string" && object.home.startsWith("/") ? { home: object.home } : {}),
    ...(typeof object.inputToken === "string" && object.inputToken ? { inputToken: object.inputToken } : {}),
    ...(object.focusesField === false ? { focusesField: false } : {}),
    ...(object.history === true ? { history: true } : {}),
    ...(object.privateChatLists === true ? { privateChatLists: true } : {}),
    ...(object.startsRemote === true ? { startsRemote: true } : {}),
    ...(object.allChats === false ? { allChats: false as const } : {}),
    ...(order ? { suggestionOrder: order } : {}),
    ...(start ? { start } : {}),
  };
}

/// How many recent sessions the page shows (two rows of three).
export const RECENT_COUNT = 6;

/// A leading character that switches the field to a kind as it is typed, as `!` does in
/// Claude Code: `!` runs a command in a terminal, `?` asks the agent. `@` is left to the
/// agent composer, which uses it for file mentions.
export const KIND_PREFIXES: Readonly<Record<string, TabKind>> = { "!": "terminal", "?": "agent" };

/// The kind a field edit switches to and the text it keeps: typing a prefix into an
/// empty field switches and consumes it; anything else stays as typed.
export function prefixedEdit(previous: string, next: string): { kind: TabKind; text: string } | undefined {
  if (previous !== "" || next.length === 0) return undefined;
  const kind = KIND_PREFIXES[next[0]!];
  return kind ? { kind, text: next.slice(1) } : undefined;
}

/// `value` as literal text in the field's Markdown: every ASCII punctuation mark escaped, line
/// breaks kept (the New Tab screen's location escaping).
export function cycleKind(kind: TabKind, step = 1): TabKind {
  const index = TAB_KINDS.indexOf(kind);
  return TAB_KINDS[(index + step + TAB_KINDS.length) % TAB_KINDS.length]!;
}

export function recentSessions(
  sessions: AcpmuxSnapshot["sessions"],
  count = RECENT_COUNT,
  fold = true,
): AcpmuxSessionEntry[] {
  // Snapshots already carry normalized entries from the direct client. Keep their identity so a
  // New Tab render does not allocate and normalize every recent chat again. Gallery and older
  // callers may still provide raw summaries, so retain the normalization fallback for those.
  // The page shows `count` chats of every chat the daemon lists (closed ones too: 10K at Leo's
  // scale), and every New Tab page (a tab's, the prewarmed spare) reads this again on each change
  // of any chat. So it keeps the best `count` in one pass instead of sorting them all: a pass is
  // the list's length with a cheap key, a sort was that times log n calls to `sessionMark` (Leo
  // 2026-11-18, "typing in the composer still slow 😞 there must be a lot of open stuff?";
  // bench/session-scale-typing.bench.ts).
  const all: Ranked[] = [];
  for (const session of sessions) {
    const entry = normalizedSessionEntry(session as AcpmuxSessionEntry & Record<string, unknown>);
    // A chat nothing was sent in yet (a New Tab's chip pick starts one) is no recent chat.
    if (!listed(entry) || entry.unsent) continue;
    all.push({ entry, urgency: sessionMark(entry, false) === "input" ? 0 : 1, at: activityTime(entry) ?? 0 });
  }
  if (!fold) return best(all, count, () => true);
  // A child folds only under a parent this list shows; under one past the cut it lists on its own.
  const shown = best(all, count, (entry) => !entry.spawnedBy);
  const parents = new Set(shown.map((entry) => entry.sessionId));
  return best(all, count, (entry) => !folded(entry, parents));
}

type Ranked = { entry: AcpmuxSessionEntry; urgency: number; at: number };

/// Chats asking for input first, then the newest. Chats reported in the same millisecond tie on
/// their durable ids, so a snapshot's arrival order cannot make the rows trade places.
const before = (a: Ranked, b: Ranked) =>
  a.urgency - b.urgency || b.at - a.at || a.entry.sessionId.localeCompare(b.entry.sessionId);

/// The first `count` of `all` that `keep` keeps, in `before` order: what sorting `all` and taking
/// the first `count` kept ones gives, in a pass that holds only `count` at a time.
function best(all: readonly Ranked[], count: number, keep: (entry: AcpmuxSessionEntry) => boolean) {
  const top: Ranked[] = [];
  if (count <= 0) return [];
  for (const ranked of all) {
    if (top.length === count && before(ranked, top[count - 1]!) >= 0) continue;
    if (!keep(ranked.entry)) continue;
    let at = top.length === count ? count - 1 : top.length;
    top[at] = ranked;
    while (at > 0 && before(top[at]!, top[at - 1]!) < 0) {
      [top[at - 1], top[at]] = [top[at]!, top[at - 1]!];
      at -= 1;
    }
  }
  return top.map((ranked) => ranked.entry);
}

/// "now", "5m", "3h", "2d": the card's age, as compact as the sidebar's.
export function ageLabel(updatedAt: number | undefined, now = Date.now(), t: Translate = translate): string {
  return ageWithDate(
    updatedAt,
    now,
    (_, translate, elapsedMs) => {
      // Rounded, as this card's age always was; the date switch is ageWithDate's.
      const minutes = Math.round(elapsedMs / 60_000);
      if (minutes < 1) return translate("age.now");
      if (minutes < 60) return translate("age.minutes", { n: minutes });
      const hours = Math.round(minutes / 60);
      return hours < 24 ? translate("age.hours", { n: hours }) : translate("age.days", { n: Math.round(hours / 24) });
    },
    t,
  );
}

const AGE_MINUTE = 60_000;
const AGE_DATE_AFTER_MINUTES = 7 * 24 * 60;

/// The first shared wall-clock minute where `ageLabel(updatedAt, …)` says something else (clock.ts
/// useLabelClock): a minute that keeps its "3h" wakes no label. Past a week the date never changes.
export function nextAgeLabel(updatedAt: number, now: number): number {
  if (!Number.isFinite(updatedAt) || !updatedAt) return Infinity;
  const elapsed = Math.max(0, now - updatedAt);
  if (Math.floor(elapsed / AGE_MINUTE) >= AGE_DATE_AFTER_MINUTES) return Infinity;
  // ageLabel's rounded minutes, hours and days; `round(x / size) >= n` once x reaches (n - 0.5) * size.
  const minutes = Math.round(elapsed / AGE_MINUTE);
  const hours = Math.round(minutes / 60);
  const nextMinutes =
    minutes < 60 ? minutes + 1 : hours < 24 ? 60 * hours + 30 : 60 * (24 * Math.round(hours / 24) + 12) - 30;
  const change = Math.min((nextMinutes - 0.5) * AGE_MINUTE, AGE_DATE_AFTER_MINUTES * AGE_MINUTE);
  return Math.max(now + AGE_MINUTE, Math.ceil((updatedAt + change) / AGE_MINUTE) * AGE_MINUTE);
}
