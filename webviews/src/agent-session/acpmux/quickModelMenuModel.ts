import { type SessionAuth } from "./sessionAuth";
import { useEffect, useRef, useState } from "react";
import { agentBrand, hasAgentMark } from "../shared/AgentMark";
import type { ChatAccountList, ChatAccounts } from "./chatAccounts";
import { type Choice } from "./composerPickerModel";
import { type ReasoningSliderStyle, type HarnessPlacement } from "./composerSettings";
import { harnessIcon } from "../shared/harnessIcons";

/// What the model button's menu lists (Leo 2026-10-20: every composer's one model control): the
/// harness's top models, numbered, then Effort, More models and Account submenus, then Fast mode.
export type QuickMenu = {
  /// The numbered rows: this harness's top models, with the running one among them.
  models: readonly Omit<QuickModel, "family">[];
  current?: string;
  onModel(id: string): void;
  onModelEffort?(id: string, effort: string): void;
  /** Opt in to inline model/effort segments; omitted or false keeps the Effort submenu. */
  inlineEffort?: boolean;
  /// A model's effort is a side dropdown at the row's trailing edge, its levels in a vertical
  /// column (Leo 2026-10-30: "we dont like horizontal text for effort. just make it vertical. hell,
  /// why not do a vertical slider?"), never a row of effort words. `list` (the default) the levels
  /// one per line with the model's recommended one named; `plain` the levels alone; `slider` a
  /// vertical slider from Low to the model's highest.
  effortLook?: EffortLook;
  /// The reasoning levels; absent when the model offers no choice.
  effort?: {
    levels: Choice[];
    current?: string;
    onPick(value: string): void;
    /// The optional stepped slider is opt-in; the Effort submenu remains the default.
    slider?: boolean;
    sliderStyle?: ReasoningSliderStyle;
  };
  /// The chat's accounts (acpmux routes); absent for a chat with no session yet or off this Mac.
  account?: { sessionId: string; accounts: ChatAccounts };
  /// The chat's harness picks its own model (the Chief, `picksOwnModel`): the menu says so in place
  /// of its model list, and offers no More models, refresh or account.
  ownModel?: boolean;
  /// Account presentation alternatives for the gallery; the compact submenu is the default. Every
  /// layout but inline lists Cmux routers under a Provider heading inside the Account choices.
  routeLayout?: "submenu" | "inline" | "grouped";
  /// How wide the menu is, for the gallery's versions; `fit` is the default (Leo 2026-11-01: "i
  /// also don't like the way this composer has so much space between stuff surely we can get more
  /// compact horizontally" / "see claude code has that"). `fit`: as wide as the open tab's rows, as
  /// Claude Code's menu is, with an effort column as wide as a level's name. `stable`: as wide as the
  /// rows every tab shows. `snug`: `stable` with tighter columns and a lower floor. Each of these
  /// keeps its widest width while open, so a tab switch never narrows it (#25796). `wide`: the fixed
  /// 480px menu with the 112px effort column (before).
  widthLook?: "fit" | "stable" | "snug" | "wide";
  /// Auth for the selected session/route only, as acpmux last verified it.
  auth?: { verdict: SessionAuth; onLogin?(): void; onRefresh?(): void };
  /// A picked model's harness being set up (harnessSetup.ts): a strip over the lists says what it is
  /// doing (`busy`: a spinner), with the last installer line under it and its actions (Sign In,
  /// Try Again, Cancel). It shows whatever tab or search the menu shows.
  setup?: QuickSetup;
  /// Fast mode: the menu's last checkbox row, its one place. Absent where the running model has
  /// none; the model button owns it for every harness.
  fast?: { checked: boolean; onChange(on: boolean): void };
  /// The rail beside the list: Starred (when any), then each harness. Without it the menu lists
  /// `models` alone and More models opens the full picker.
  families?: QuickFamilies;
  /// The chat's agent CLI has an update (hq#2569 #12): a quiet footer under the list starts it, apart
  /// from the model choices and their held height.
  update?: { text: string; run(): void };
  /// Search (Lawrence 2026-10-22: "spacing + needs search"): the models a typed query finds, with
  /// the full picker's matching (ModelPicker's `searchModels`), and the pick of one, which lands
  /// the effort and fast mode the query named. Without it typing opens the full picker.
  search?: {
    find(query: string): QuickModel[];
    pick(model: QuickModel): void;
  };
  /// When the search field shows (gallery versions): `always` (the default), `typed` (only once
  /// a key is typed), or `long` (when the list holds more than LONG_LIST models, or once typed).
  searchField?: QuickSearchField;
  /// How a model several providers serve offers them (gallery versions; Lawrence 2026-10-22,
  /// OpenCode's DeepSeek rows): `row` (the default) lists it once and adds a Provider row for the
  /// running one, `submenu` makes its row a submenu of providers, `expanded` lists its providers
  /// under its name.
  providers?: QuickProviderLook;
  /// How a search with a rail lists its matches (gallery versions; Lawrence, via Leo 2026-10-28:
  /// "search feels confusing here in the model picker"): `harness` (the default) heads each
  /// harness's matches with its name and keeps only those harnesses on the rail, `flat` is one list
  /// whose rows name their harness beside the provider.
  searchGroups?: QuickSearchGroups;
  harnessPlacement?: HarnessPlacement;
};

export type QuickSearchGroups = "harness" | "flat";

/// How a model's effort side dropdown draws its levels (`QuickMenu.effortLook`).
export type EffortLook = "list" | "plain" | "slider";

/// Whether a rail tab draws its harness's own symbol: a mark the AgentMark set has, never a
/// monogram (a machine or session initial says nothing about the harness).
export function symbolOf(family: { mark?: string }): boolean {
  const mark = family.mark;
  if (!mark || !hasAgentMark(mark)) return false;
  // As AgentMark picks: a harness's own icon wins over its brand, but a glyph draws the brand's
  // mark, so a glyph with no brand behind it draws nothing and the tab needs its name.
  const own = harnessIcon(mark);
  if (own && (own.source === "profile" || !agentBrand(mark)) && own.kind !== "glyph") return own.kind !== "monogram";
  return !!agentBrand(mark);
}

/// A harness with no symbol of its own draws its name's first letter as a mark in the symbols row,
/// so every tab there is a mark and none is text.
export function initialOf(name: string): string {
  return (name.match(/\p{L}|\p{N}/u)?.[0] ?? "?").toLocaleUpperCase();
}

export type QuickSearchField = "always" | "typed" | "long";

export type QuickProviderLook = "row" | "submenu" | "expanded";

/// A model row of any harness: `family` is the rail tab (harness) it belongs to. A searched row
/// names its provider, effort and fast mode in `hint`, and lands `effort` and `fast` when picked. A
/// model several providers serve is one row (modelVariants.ts): it lands its own `id`, and `offers`
/// holds every provider's row; `tag` is a note its name carried ("New").
export type QuickModel = {
  id: string;
  name: string;
  family: string;
  disabled?: boolean;
  /// A searched row's harness name: the heading its matches sit under (or, with no rail, its detail).
  harness?: string;
  hint?: string;
  effort?: string;
  /** Only levels advertised for this model; [] means no reasoning control. */
  efforts?: readonly string[];
  /** The catalog's recommended level, which the row's effort column names before a pick. */
  defaultEffort?: string;
  fast?: boolean;
  /// The model honors Fast mode (its catalog entry says so): on a tab other than the chat's own,
  /// the menu's Fast mode row lands it with Fast on.
  canFast?: boolean;
  tag?: string;
  /// The provider the row lands, named at its trailing edge (a harness that routes to several).
  provider?: string;
  /// Where a search lists the row's family: 0 (unset) its harness is set up here, 1 a pick sets it
  /// up first (installs or signs it in), 2 that harness lists the feed's models until it runs.
  rank?: number;
  /// Why a pick sets the row's harness up first ("Not installed", "Signed out"): its search
  /// heading says so.
  setupNote?: string;
  offers?: (QuickModel & { provider: string })[];
};

/// The setup strip's text and its buttons (QuickMenuProps `setup`).
export type QuickSetup = {
  text: string;
  detail?: string;
  busy: boolean;
  actions: { label: string; run(): void }[];
};

/// A rail tab: its harness's top models (numbered), the rest under More models, or a `note` in
/// their place (a signed-out harness). `mark` is the AgentMark brand; without one the tab draws
/// the name's initial.
export type QuickFamily = {
  id: string;
  name: string;
  mark?: string;
  starred?: boolean;
  models: QuickModel[];
  more: QuickModel[];
  note?: string;
  /// Runs a signed-out harness's login (its Log In row).
  logIn?(): void;
  /// Sets up a harness this machine does not have (its Install… row).
  setUp?(): void;
  /// A distinctly named launch configuration; choosing it changes the harness.
  launch?: boolean;
  /// The harness's probe failed (its catalog entry is unavailable): its catalog rows are stale, so
  /// a launch entry keeps its one-click launch tab instead of listing them.
  unavailable?: boolean;
  /// The acpmux family an account added from this tab serves ("claude", "codex", "opencode").
  accountFamily?: string;
  /// The model family the entry runs ("claude", "openai"): entries of one family share one tab,
  /// and each is a route of it (its transport, login or launch setup) the Account row chooses
  /// (Leo 2026-10-31: "FUCKING HELL WHY DO YOU GUYS STILLLLLLLLLLLLLLLLLLLLLL SHOW THESE AS
  /// SEPARATE HARNESSES" / "THE FUCKING APP SERVER THE FUCKING SR" / "WHERE IS THE FUCKING
  /// ACCOUNTS"). Absent: the entry is its own family.
  group?: string;
};

/// The tab a rail entry sits under: its model family (its `group`, else the brand its mark draws:
/// Claude Code, claude-sr2 and a work login are all Claude; Codex and its app server are OpenAI),
/// or itself when it has neither.
export const groupKey = (family: Pick<QuickFamily, "id" | "group" | "starred" | "mark">) =>
  family.starred ? family.id : (family.group ?? agentBrand(family.mark ?? family.id) ?? family.id);

/// One tab of the symbols row: a model family and its routes (transports, logins, launch setups),
/// never a tab per route.
export type QuickTab = { key: string; name: string; routes: QuickFamily[] };

/// The rail's tabs: one per model family, in the order its first route comes. A family's name is
/// its first route's without a launch setup's "(suffix)".
export function familyTabs(list: readonly QuickFamily[]): QuickTab[] {
  const tabs = new Map<string, QuickTab>();
  for (const family of list) {
    const key = groupKey(family);
    const tab = tabs.get(key);
    if (tab) tab.routes.push(family);
    else tabs.set(key, { key, name: family.name, routes: [family] });
  }
  for (const tab of tabs.values())
    if (tab.routes.length > 1) {
      const lead = tab.routes.find((route) => !route.launch) ?? tab.routes[0]!;
      tab.name = lead.name.replace(/\s*\([^)]*\)\s*$/, "") || lead.name;
    }
  return [...tabs.values()];
}

/// The route a family's tab opens on: the chat's own when it runs this family, else the first
/// that lists models, else the first.
export function leadRoute(tab: QuickTab, running: string | undefined): QuickFamily {
  const listsModels = (route: QuickFamily) =>
    !route.launch && !route.note && [...route.models, ...route.more].some((model) => !model.disabled);
  return (
    tab.routes.find((route) => route.id === running) ??
    tab.routes.find(listsModels) ??
    tab.routes.find((route) => !route.launch && !route.note) ??
    tab.routes[0]!
  );
}

/// How the menus mark what a started chat ran, beside a held pick of another harness's model
/// (UsedMark): `glyph` ships; `dot` and `caption` are the gallery's other versions.
export type UsedLook = "glyph" | "dot" | "caption";

export type QuickFamilies = {
  list: QuickFamily[];
  /// The chat's harness: its tab opens first, and only it shows Effort and Account.
  current?: string;
  onPick(model: QuickModel): void;
  /// Add harness…, the last item in the harness strip.
  onAddHarness?(): void;
  onLaunch?(id: string): void;
  /// A started chat's pick of another harness's model (or launch route, `id` absent), held as its
  /// next message's target (forkHold.ts): its row is the checked one and its tab opens first, and
  /// the columns' settings show its `effort` and `fast`.
  held?: { family: string; id?: string; effort?: string; fast?: boolean };
  /// A started chat with another harness's model held: the chat's own tab and running model (and
  /// its provider) carry the "used here" mark (UsedMark) in this look. Absent while nothing is
  /// held, where the running row's check already says it.
  used?: UsedLook;
  /// Starred models: each row's star at its trailing edge shows and toggles it (the Starred tab
  /// lists them). Absent: no stars on the rows.
  stars?: { has(model: QuickModel): boolean; toggle(model: QuickModel): void };
};

/// The tab a held pick of another harness opens the menu on, when the rail lists it.
export function heldTab(families: QuickFamilies | undefined): string | undefined {
  const held = families?.held;
  return held && families.list.some((family) => family.id === held.family) ? held.family : undefined;
}

/// One harness's search matches under its name. Groups keep the rail's order; Starred is never one,
/// since every starred model also sits under its own harness.
/// One harness family's matches; `note` says a pick sets the harness up first ("Not installed").
export type QuickSearchGroup = { id: string; name: string; note?: string; rows: QuickModel[] };

export function searchGroups(
  found: readonly QuickModel[],
  rail: readonly QuickFamily[],
  running?: string,
): QuickSearchGroup[] {
  // A model family's routes share one heading, the tab's: a model several routes run is listed
  // once, from the route its tab opens on, so search shows no transport as a harness either.
  const tabs = familyTabs(rail.filter((family) => !family.starred));
  const tabOf = new Map(tabs.flatMap((tab) => tab.routes.map((route) => [route.id, tab] as const)));
  const groups = new Map<string, QuickSearchGroup & { lead?: string; seen: Map<string, number> }>();
  for (const tab of tabs)
    groups.set(tab.key, {
      id: tab.key,
      name: tab.name,
      rows: [],
      lead: leadRoute(tab, running).id,
      seen: new Map(),
    });
  for (const row of found) {
    const key = tabOf.get(row.family)?.key ?? row.family;
    let group = groups.get(key);
    if (!group) groups.set(key, (group = { id: key, name: row.harness ?? row.family, rows: [], seen: new Map() }));
    const at = group.seen.get(row.id);
    if (at === undefined) {
      group.seen.set(row.id, group.rows.length);
      group.rows.push(row);
    } else if (row.family === group.lead && group.rows[at]!.family !== group.lead) group.rows[at] = row;
  }
  // A family whose harness a pick must set up first comes after the ready ones (QuickModel `rank`),
  // each in rail order.
  const rank = (group: QuickSearchGroup) => Math.min(...group.rows.map((row) => row.rank ?? 0));
  return [...groups.values()]
    .filter((group) => group.rows.length > 0)
    .map(({ id, name, rows }) => {
      const note = rows.find((row) => row.setupNote)?.setupNote;
      return { id, name, ...(note ? { note } : {}), rows };
    })
    .map((group, index) => ({ group, index, rank: rank(group) }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map(({ group }) => group);
}

/// The rows of a group that another row of it would read the same as (name and detail): they also
/// show their model id, so "GPT-6.1 Sol · OpenRouter" twice is two tellable rows.
export function twinRows(groups: readonly QuickSearchGroup[]): Set<QuickModel> {
  const twins = new Set<QuickModel>();
  for (const group of groups) {
    const seen = new Map<string, QuickModel>();
    for (const row of group.rows) {
      const key = [row.name, row.harness ?? row.family, row.hint ?? row.provider ?? ""].join("\u0000");
      const first = seen.get(key);
      if (first) twins.add(first).add(row);
      else seen.set(key, row);
    }
  }
  return twins;
}
/// The running model's row when several providers serve it: the running offer may be another
/// provider's than the row lands, when the running one is unavailable.
export const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);

/// The chat's accounts, read each time the menu opens (acpmux holds them; nothing polls), and a
/// pick that switches the chat. A refused switch (acpmux's route.unavailable, a route of another
/// family) stays named on the Account row until a switch succeeds or the chat changes.
export function useAccountList(open: boolean, account: QuickMenu["account"]) {
  const [list, setList] = useState<ChatAccountList>();
  const [failed, setFailed] = useState(false);
  const [switchFailed, setSwitchFailed] = useState(false);
  const sessionId = account?.sessionId;
  const accounts = account?.accounts;
  useEffect(() => {
    if (!open || !sessionId || !accounts) return;
    let live = true;
    setFailed(false);
    accounts.list(sessionId).then(
      (next) => live && setList(next),
      () => live && setFailed(true),
    );
    return () => {
      live = false;
    };
  }, [open, sessionId, accounts]);
  // The chat the latest pick was for: a late answer for another chat changes nothing here.
  const pickFor = useRef(sessionId);
  // Another chat's accounts never show for this one.
  useEffect(() => {
    pickFor.current = sessionId;
    setList(undefined);
    setSwitchFailed(false);
  }, [sessionId]);
  const pick = (routeId: string | null) => {
    if (!sessionId || !accounts) return;
    const forSession = sessionId;
    setList((old) =>
      old
        ? {
            ...old,
            ...(routeId ? { active: routeId, scope: "chat" } : { active: undefined, scope: undefined }),
          }
        : old,
    );
    accounts.set(sessionId, routeId).then(
      () => pickFor.current === forSession && setSwitchFailed(false),
      () => {
        if (pickFor.current !== forSession) return;
        setSwitchFailed(true);
        // The next open reads where the chat really is.
        setList(undefined);
      },
    );
  };
  return { list, failed, switchFailed, pick };
}
