import { authLoginText, authText, canSessionLogin, type SessionAuth } from "./sessionAuth";
import React, {
  Fragment,
  useCallback,
  useContext,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { AgentMark, agentBrand, hasAgentMark } from "../shared/AgentMark";
import type { ChatAccountList, ChatAccounts } from "./chatAccounts";
import { isModelRouterKind } from "./routerKinds";
import { SearchIcon, reasoningChoices, type Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
import { useComposerSettings, type ReasoningSliderStyle, type HarnessPlacement } from "./composerSettings";
import { harnessIcon } from "../shared/harnessIcons";
import { useT } from "./i18n";
import { CHAT_COLUMN } from "./modelPickerLayout";
import { useOpenSide } from "../../ui/openSide";
import { OnNewTab } from "./newTabComposer";
import {
  Menu,
  MenuButton,
  MenuCheckboxItem,
  MenuGroup,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  Submenu,
} from "../../ui/Menu";

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
function symbolOf(family: { mark?: string }): boolean {
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
function initialOf(name: string): string {
  return (name.match(/\p{L}|\p{N}/u)?.[0] ?? "?").toLocaleUpperCase();
}

export type QuickSearchField = "always" | "typed" | "long";

/// How many models (the tab's rows and More models) make a list long enough for the `long`
/// version's search field.
const LONG_LIST = 8;

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
  offers?: (QuickModel & { provider: string })[];
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
  /// A distinctly named launch configuration; choosing it changes the harness.
  launch?: boolean;
  /// The harness's probe failed (its catalog entry is unavailable): its catalog rows are stale, so
  /// a launch entry keeps its one-click launch tab instead of listing them.
  unavailable?: boolean;
  /// A started chat's other harness: offer Fork to it in place of models.
  fork?: boolean;
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
const groupKey = (family: Pick<QuickFamily, "id" | "group" | "starred" | "mark">) =>
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
function leadRoute(tab: QuickTab, running: string | undefined): QuickFamily {
  const listsModels = (route: QuickFamily) =>
    !route.launch && !route.note && [...route.models, ...route.more].some((model) => !model.disabled);
  return (
    tab.routes.find((route) => route.id === running) ??
    tab.routes.find(listsModels) ??
    tab.routes.find((route) => !route.launch && !route.note) ??
    tab.routes[0]!
  );
}

export type QuickFamilies = {
  list: QuickFamily[];
  /// The chat's harness: its tab opens first, and only it shows Effort and Account.
  current?: string;
  onPick(model: QuickModel): void;
  /// Add harness…, the last item in the harness strip.
  onAddHarness?(): void;
  onLaunch?(id: string): void;
  onFork?(id: string): void;
  forkReady?: boolean;
  /// Starred models: each row's star at its trailing edge shows and toggles it (the Starred tab
  /// lists them). Absent: no stars on the rows.
  stars?: { has(model: QuickModel): boolean; toggle(model: QuickModel): void };
};

/// Keys 1 to 9 pick a tab's first rows; this does not limit the visible model list.
const FILTER_ROWS = 9;
const EFFORT_SLIDER_KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);

const rowValue = (model: Pick<QuickModel, "family" | "id">) => `${model.family}\u0000${model.id}`;

/// One harness's search matches under its name. Groups keep the rail's order; Starred is never one,
/// since every starred model also sits under its own harness.
export type QuickSearchGroup = { id: string; name: string; rows: QuickModel[] };

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
    groups.set(tab.key, { id: tab.key, name: tab.name, rows: [], lead: leadRoute(tab, running).id, seen: new Map() });
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
  return [...groups.values()]
    .filter((group) => group.rows.length > 0)
    .map(({ id, name, rows }) => ({ id, name, rows }));
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
const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);

/// What the composer hands the model picker for its compact menu; the picker adds the models.
export type QuickMenuExtras = Pick<
  QuickMenu,
  "effort" | "account" | "auth" | "fast" | "searchField" | "providers" | "searchGroups" | "harnessPlacement"
>;

/// The compact model menu keeps numbered rows, Effort and Account flyouts, and Fast mode.
/// Its search field filters models in place using the full picker's matching.
export function QuickModelMenu({
  open,
  onOpenChange,
  trigger,
  chip,
  menu,
  onMore,
  children,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  /// Holds the chip (the menu's button), where the full picker anchors.
  trigger: React.RefObject<HTMLButtonElement | null>;
  chip: { "data-menu": string; label: string; title: string };
  menu: QuickMenu;
  /// Opens the full picker, searching for `query` when one was typed.
  onMore(query?: string): void;
  /// The chip's face.
  children: React.ReactNode;
}) {
  const t = useT();
  const settings = useComposerSettings();
  const placement = menu.harnessPlacement ?? settings.harnessPlacement;
  // On New Tab the menu opens down, shows no key hints and opens More models in place (newTabComposer.ts).
  const newTab = useContext(OnNewTab);
  // Choose once for the compact menu's possible height; shorter tabs then stay by the same edge
  // of the chip. This is only a side decision: the surface still fits its visible content.
  const { open: sideOpen, setOpen: setSideOpen, side } = useOpenSide(trigger, newTab ? "bottom" : "top", 320);
  if (sideOpen !== open) setSideOpen(open);
  const { models, current, effort, auth, fast, ownModel } = menu;
  const account = ownModel ? undefined : menu.account;
  const families = menu.families;
  const currentFamily = families?.list.find((family) => family.id === families.current);
  const currentModels = currentFamily ? [...currentFamily.models, ...currentFamily.more] : models;
  const currentModel = currentModels
    .flatMap((model) => [model, ...(model.offers ?? [])])
    .find((model) => model.id === current);
  // Explicitly unsupported effort overrides session options, including the standalone fallback.
  // An absent capability still permits the live session to supply its own choices.
  const levels =
    currentModel?.efforts?.length === 0 ? [] : (effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? []);
  const level = levels.find((choice) => choice.id === effort?.current);
  const accounts = useAccountList(open, account);
  // The rail's tab and the typed filter start over with each opening.
  const [tab, setTab] = useState(families?.current);
  const [query, setQuery] = useState("");
  // On New Tab, More models is a row that shows the tab's other models in place, as T3 Code's
  // model menu does, not a submenu: the rail tab it was opened on.
  const [moreFor, setMoreFor] = useState<string | undefined>();
  // Fast mode for a tab other than the chat's (Leo 2026-10-31: "WHY THE FUCK IS THERE NO FUCKING
  // FAST MODE FOR FUCKIGN CODEX"): nothing runs there yet, so the row holds the choice and a model
  // picked from that tab lands with it. Off each time the menu opens; the chat's own tab keeps the
  // session's option. It holds the family tab it was turned on for: only that tab's picks take it.
  const [heldFast, setHeldFast] = useState<string | undefined>();
  const moreListId = useId();
  // Reset as the menu opens, in render: the composer re-renders while it is open (a streaming
  // reply), and an effect on the families would throw away the tab and the typed filter.
  const [scrolled, setScrolled] = useState(false);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
      setQuery("");
      setMoreFor(undefined);
      setHeldFast(undefined);
      setScrolled(false);
    }
  }
  // Typing can unmount the focused row (Effort, Account, a model it filters out); keyboard focus
  // goes to the first row left, so the next key, Enter and Escape still reach the menu. A
  // re-render with the same filter (a streaming reply hands over new families) keeps the row the
  // keyboard moved to, so Enter picks it.
  // With a search field the keyboard sits in it from the moment the menu opens, and a key typed
  // on a row goes back to it.
  const popup = useRef<HTMLDivElement | null>(null);
  // A changed tab or filter starts with its first model in view.
  const body = useRef<HTMLDivElement | null>(null);
  const rail = useRef<HTMLFieldSetElement | null>(null);
  useLayoutEffect(() => {
    const selected = rail.current?.querySelector<HTMLElement>('[aria-pressed="true"]');
    selected?.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  }, [open, tab]);
  // A compact width never narrows while the menu is open: a tab switch keeps the
  // menu's width and the rail's place (#25796), though each tab's rows (Account and Effort show only
  // on the chat's tab) want their own. The floor is the widest the menu has been since it opened;
  // the observer goes with the rail, so it ends when the menu closes.
  const railWidth = useRef<ResizeObserver | null>(null);
  const holdsWidth = menu.widthLook !== "wide";
  const railRef = useCallback(
    (node: HTMLFieldSetElement | null) => {
      rail.current = node;
      railWidth.current?.disconnect();
      railWidth.current = null;
      const popupNode = node?.closest<HTMLElement>(".ui-popup");
      if (!popupNode || !holdsWidth || typeof ResizeObserver === "undefined") return;
      let widest = 0;
      popupNode.style.minWidth = "";
      const observer = new ResizeObserver(() => {
        const width = popupNode.getBoundingClientRect().width;
        if (width <= widest) return;
        widest = width;
        // Never past the room the pane gives (min-width beats max-width): a pane that narrows while
        // the menu is open, or a first reading before the boundary applies, keeps it inside.
        popupNode.style.minWidth = `min(${width}px, var(--available-width, calc(100vw - 24px)))`;
      });
      observer.observe(popupNode);
      railWidth.current = observer;
    },
    [holdsWidth],
  );
  const toTop = () => {
    if (body.current) body.current.scrollTop = 0;
    setScrolled(false);
  };
  const focusedFor = useRef<string | undefined>(undefined);
  const search = menu.search;
  const field = useRef<HTMLInputElement | null>(null);
  const shown = families?.list.find((family) => family.id === tab);
  const look = menu.searchField ?? "always";
  // How many models the list holds, More models included (an empty query finds every one).
  const listed =
    look !== "long"
      ? 0
      : families
        ? shown
          ? shown.models.length + shown.more.length
          : 0
        : (search?.find("").length ?? 0);
  const showField = !!search && (look === "always" || query !== "" || (look === "long" && listed > LONG_LIST));
  useLayoutEffect(() => {
    const input = field.current;
    const node = input?.closest<HTMLElement>(".ui-popup") ?? popup.current;
    if (!open || !node || !(families || search)) {
      focusedFor.current = undefined;
      return;
    }
    const active = node.ownerDocument.activeElement;
    const typed = query !== focusedFor.current;
    focusedFor.current = query;
    if (input) {
      // A search's rows can arrive a render after its text: a row the arrows reached in between
      // is replaced, and the keyboard stays in the list, on its first row, not back in the field.
      const row =
        query && !typed && !node.contains(active)
          ? node.querySelector<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]:not([data-disabled])')
          : null;
      if (row) row.focus({ preventScroll: true });
      else if ((query && typed && active !== input) || !node.contains(active)) {
        input.focus({ preventScroll: true });
        input.setSelectionRange(input.value.length, input.value.length);
      }
    } else if ((query && typed) || !node.contains(active)) {
      const first = node.querySelector<HTMLElement>('[role^="menuitem"]:not([data-disabled])');
      (first ?? node).focus({ preventScroll: true });
    }
  }, [query, open, families, search, showField, tab, moreFor]);
  const onChatTab = !families || tab === families.current;
  const forkTab = !query && shown?.fork ? shown : undefined;
  // Another tab whose models honor Fast mode draws the same Fast mode row the chat's tab does.
  const tabFast =
    !query &&
    !onChatTab &&
    !forkTab &&
    !shown?.launch &&
    !!shown &&
    !shown.starred &&
    [...shown.models, ...shown.more].some((model) => model.canFast && !model.disabled);
  const inlineMore = newTab && families !== undefined;
  // The symbols layout names a harness's other models Legacy models with their count, as the
  // reference picker does (Leo 2026-10-30, "like this, but symbols at the top").
  const moreLabel = (count: number) =>
    placement === "symbols" ? (
      <span className="acpmux-quick-label acpmux-quick-legacy">
        <span className="acpmux-menu-label">{t("picker.legacyModels")}</span>
        <span className="acpmux-quick-value">{t("picker.modelCount", { n: count })}</span>
      </span>
    ) : (
      <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
    );
  const moreShown = inlineMore && !query && moreFor !== undefined && moreFor === tab;
  // What the list draws: the search's matches, else the tab's top models. With a rail, the matches
  // sit under their harness's name, in rail order (Lawrence, via Leo 2026-10-28: "search feels
  // confusing here in the model picker"), and the rows keep that order, so Enter picks the top one.
  const found = useMemo(() => (query && search ? search.find(query) : undefined), [query, search]);
  const groupLook = menu.searchGroups ?? "harness";
  const groups = useMemo(
    () =>
      found && families && groupLook === "harness" ? searchGroups(found, families.list, families.current) : undefined,
    [found, families, groupLook],
  );
  const rows: QuickModel[] = groups
    ? groups.flatMap((group) => group.rows)
    : (found ?? (!families ? models.map((model) => ({ ...model, family: "" })) : (shown?.models ?? [])));
  // While a search shows, the rail keeps only the harnesses it found models in (all of them when it
  // found none, so a harness is a click away).
  const railTabs = useMemo(() => {
    if (!families || !groups?.length) return families?.list ?? [];
    const matched = new Set(groups.map((group) => group.id));
    return families.list.filter((family) => matched.has(groupKey(family)));
  }, [families, groups]);
  // One tab per model family; its routes are an Account choice, never tabs of their own.
  const tabs = useMemo(() => familyTabs(railTabs), [railTabs]);
  const shownTab = tabs.find((entry) => entry.routes.some((route) => route.id === tab));
  const routes = shownTab && !shownTab.routes[0]?.starred ? shownTab.routes : [];
  // Rows whose name and detail read the same within one harness also show their model id.
  const twins = useMemo(() => twinRows(groups ?? (found ? [{ id: "", name: "", rows: found }] : [])), [groups, found]);
  const providerLook = menu.providers ?? "row";
  // The running model's row when several providers serve it: the Provider row switches among them.
  const runningRow = onChatTab
    ? (families ? shown?.models : models)?.find((model) => runsOffers(model, current))
    : undefined;
  const runningProvider = runningRow?.offers?.find((offer) => offer.id === current)?.provider;
  const valueOf = (model: Pick<QuickModel, "family" | "id">) => (families ? rowValue(model) : model.id);
  const providerRow = (offer: QuickModel & { provider: string }, className = "acpmux-quick-item") => (
    <MenuRadioItem
      key={valueOf(offer)}
      value={valueOf(offer)}
      closeOnClick
      disabled={offer.disabled}
      className={className}
    >
      <span className="acpmux-menu-label">{offer.provider}</span>
    </MenuRadioItem>
  );
  const pickRow = (picked: QuickModel) => {
    if (picked.disabled) return;
    onOpenChange(false);
    // Another tab's model lands with the Fast mode its tab's row holds.
    const row =
      heldFast !== undefined &&
      !query &&
      families &&
      // Held per family tab: switching its route in the Account row keeps it.
      shownTab?.key === heldFast &&
      shownTab.routes.some((route) => route.id === picked.family) &&
      picked.family !== families.current &&
      picked.canFast &&
      !picked.fast
        ? { ...picked, fast: true }
        : picked;
    const running = (!families || row.family === families.current) && row.id === current;
    if (running && !row.effort && !row.fast) return;
    if (query && search) search.pick(row);
    else if (!families && row.effort && menu.onModelEffort) menu.onModelEffort(row.id, row.effort);
    else if (!families) menu.onModel(row.id);
    else families.onPick(row);
  };
  const effortChoices = (model: QuickModel) => {
    const running = (!families || model.family === families.current) && model.id === current;
    // Inline effort controls are opt-in. Other compact-menu callers may expose a combined
    // callback for the full picker while retaining the standalone Effort submenu here.
    if (menu.inlineEffort !== true || (!families && !menu.onModelEffort)) return [];
    // The opt-in slider owns the running model's effort control; do not render a duplicate
    // segmented control beside it while its standalone Effort row is openable below.
    if (running && effort?.slider) return [];
    // An explicit empty list must not inherit session choices, including Ultracode.
    if (model.efforts?.length === 0) return [];
    const advertised = running
      ? levels
      : model.efforts !== undefined
        ? reasoningChoices(
            model.efforts.map((value) => ({ value })),
            { efforts: model.efforts, ...(model.defaultEffort ? { defaultEffort: model.defaultEffort } : {}) },
            t,
          )
        : [];
    // Ultracode is a session-specific option. It may be reported on the harness effort
    // option even when the catalog model's own list predates it; keep it in the inline
    // row as well as in the Effort submenu so the combined picker does not remove it.
    const ultracode = effort?.levels.find((choice) => choice.id === "ultracode");
    if (running && ultracode && !advertised.some((choice) => choice.id === "ultracode")) {
      return [...advertised, ultracode];
    }
    return advertised;
  };
  const withEffort = (model: QuickModel, name: React.ReactNode) => {
    const choices = effortChoices(model);
    const stars = families?.stars;
    // A row's star, beside its effort column: a plain button, not a menu item, so it is no stop for
    // Up and Down and a click on it never picks the model. It has no key: ⌘D is Split Right, and the
    // open menu never takes an app shortcut it does not show on a row.
    const starred = stars?.has(model) ?? false;
    const star = stars ? (
      <button
        type="button"
        className="acpmux-quick-star"
        tabIndex={-1}
        aria-pressed={starred}
        aria-label={`${t(starred ? "picker.unstar" : "picker.star")}: ${model.name}`}
        title={t(starred ? "picker.unstar" : "picker.star")}
        onPointerDown={(event) => event.stopPropagation()}
        onClick={(event) => {
          event.stopPropagation();
          stars.toggle(model);
        }}
      >
        <StarIcon filled={starred} />
      </button>
    ) : null;
    if (choices.length === 0)
      return star ? (
        <div className="acpmux-quick-model-effort" key={valueOf(model)}>
          {name}
          {star}
        </div>
      ) : (
        name
      );
    const running = (!families || model.family === families.current) && model.id === current;
    const pickEffort = (value: string) => {
      // The current model is already selected. Apply its effort through the reported
      // option so the harness updates the same config as the Effort submenu. A different
      // model still uses the combo path, which waits for that model to be reported first.
      if (running && effort?.onPick) {
        onOpenChange(false);
        effort.onPick(value);
        // A searched combo can also ask for Fast. It goes through the combo path, which maps "fast"
        // onto the option's plain tier (the Fast toggle would restore a remembered higher one); the
        // effort went through the reported option above, so a session-only level (Ultracode) lands too.
        if (model.fast) pickRow({ ...model, effort: undefined });
        return;
      }
      pickRow({ ...model, effort: value });
    };
    const look = menu.effortLook ?? "list";
    // A row that does not run names the level a pick lands (the model's recommended one), as the
    // running row names its own, on every tab: a blank column until pointed at hid that each model
    // has an effort choice at all (https://github.com/manaflow-ai/cmux/issues/29915).
    const shown = running
      ? choices.find((choice) => choice.id === effort?.current)
      : choices.find((choice) => choice.recommended);
    const held = !running && !!shown;
    // The row stays one line: the model, then its effort item at the trailing edge (the running
    // model's level and a chevron). Pointing at it or ArrowRight opens the model's levels as a side
    // dropdown beside the row, a vertical list in its own popup (never clipped by the list's scroll,
    // never over the next row), and a level lands the model and its effort together.
    return (
      <div
        className="acpmux-quick-model-effort"
        key={valueOf(model)}
        data-effort-look={look}
        data-running={running ? "" : undefined}
        data-held={held ? "" : undefined}
      >
        {name}
        <Submenu
          className="acpmux-quick-item acpmux-quick-effort-trigger"
          popupClassName="acpmux-quick-menu acpmux-quick-submenu acpmux-quick-effort-menu"
          disabled={model.disabled}
          label={
            <span className="acpmux-quick-effort-now">
              {shown?.name}
              <span className="sr-only">{`${model.name} · ${t("effort.title")}`}</span>
            </span>
          }
        >
          {look === "slider" ? (
            <div className="acpmux-quick-effort-vertical" data-effort-look="slider">
              <EffortTrack
                efforts={choices}
                current={running ? effort?.current : undefined}
                fallback={choices.find((choice) => choice.recommended)?.id}
                sliderStyle={effort?.sliderStyle}
                onPick={pickEffort}
                onRangeKey={(event) => {
                  if (EFFORT_SLIDER_KEYS.has(event.key)) event.stopPropagation();
                }}
                focusOnMount
              />
            </div>
          ) : (
            <MenuRadioGroup value={running ? (effort?.current ?? "") : ""} onValueChange={pickEffort}>
              {choices.map((choice) => (
                <MenuRadioItem
                  key={choice.id}
                  className="acpmux-quick-item acpmux-quick-effort-segment"
                  label={`${model.name} · ${choice.name}`}
                  value={choice.id}
                  closeOnClick
                >
                  {/* One grid cell for the name and its badge, as a model row's label: the check
                      keeps the trailing column and the row stays one line. */}
                  <span className="acpmux-quick-label">
                    <span className="acpmux-menu-label">{choice.name}</span>
                    {look === "list" && choice.recommended && (
                      <span className="acpmux-quick-effort-badge">{t("picker.modeRecommended")}</span>
                    )}
                  </span>
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          )}
        </Submenu>
        {star}
      </div>
    );
  };
  /// The field's editing keys stay in it: Base UI's typeahead and the menu's own keys never see
  /// them. Digits on an empty field still pick a row, and Left and Right move along the rail.
  const fieldKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.nativeEvent.isComposing || event.keyCode === 229) {
      event.stopPropagation();
      return;
    }
    const { key } = event;
    // Down lands on the first model row at once, before the menu's own keys see it: left to the
    // menu, a Down right after typing could stay in the field and the next went to the row's
    // effort item, so a keyboard pick from a search never reached a model.
    if (key === "ArrowDown" && !event.shiftKey) {
      const first = event.currentTarget
        .closest(".acpmux-quick-menu")
        ?.querySelector<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]:not([data-disabled])');
      if (first) {
        event.preventDefault();
        event.stopPropagation();
        first.focus();
        return;
      }
    }
    if (!query && (/^[1-9]$/.test(key) || key === "ArrowLeft" || key === "ArrowRight")) return;
    if (key.length === 1 || ["Backspace", "Delete", "Home", "End", "ArrowLeft", "ArrowRight"].includes(key))
      event.stopPropagation();
  };
  const activeAccount = accounts.list?.accounts.find((choice) => choice.id === accounts.list?.active);
  const accountValue = accounts.switchFailed
    ? t("picker.accountSwitchFailed")
    : accounts.list
      ? (activeAccount?.name ?? t("picker.harnessLogin"))
      : undefined;
  const routeRows = account && (
    <AccountRows
      list={accounts.list}
      failed={accounts.failed}
      switchFailed={accounts.switchFailed}
      grouped={menu.routeLayout !== "inline"}
      onPick={(routeId) => {
        onOpenChange(false);
        accounts.pick(routeId);
      }}
    />
  );
  // The Account row: the family's routes when it has several, and the running route's accounts.
  const chatRouteAccounts = onChatTab && !!account;
  const accountShown = routes.length > 1 || chatRouteAccounts;
  const routeName = routes.length > 1 ? shown?.name : undefined;
  const accountLabel =
    [routeName, chatRouteAccounts ? accountValue : undefined].filter(Boolean).join(" · ") || undefined;
  const familyRoutes =
    routes.length > 1 ? (
      <MenuRadioGroup
        value={tab ?? ""}
        onValueChange={(id) => {
          const route = routes.find((candidate) => candidate.id === id);
          if (!route) return;
          // A route with no models of its own starts its harness, as its tab did.
          if (route.launch && !route.note) {
            if (families?.forkReady === false) return;
            onOpenChange(false);
            families?.onLaunch?.(route.id);
            return;
          }
          setTab(route.id);
          toTop();
        }}
      >
        {routes.map((route) => (
          <MenuRadioItem
            key={route.id}
            value={route.id}
            closeOnClick={false}
            disabled={route.launch && families?.forkReady === false}
            className="acpmux-quick-item acpmux-quick-route"
          >
            <span className="acpmux-quick-label">
              <span className="acpmux-menu-label">{route.name}</span>
              {route.note && <span className="acpmux-quick-value">{route.note}</span>}
            </span>
          </MenuRadioItem>
        ))}
      </MenuRadioGroup>
    ) : null;
  const chatAccounts = chatRouteAccounts ? (
    <>
      {familyRoutes && <MenuSeparator />}
      {routeRows}
    </>
  ) : null;
  const keyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    // ⌘1 to ⌘9 pick a row as 1 to 9 do, also while a search shows (where a bare digit is text).
    const commandDigit = event.metaKey && !event.ctrlKey && !event.altKey && /^[1-9]$/.test(event.key);
    if (
      (event.metaKey && !commandDigit) ||
      event.ctrlKey ||
      event.altKey ||
      event.nativeEvent.isComposing ||
      event.keyCode === 229
    )
      return;
    // Only the menu's own keys, not a submenu's (React carries those up through the portal).
    if (!event.currentTarget.contains(event.target as Node)) return;
    popup.current = event.currentTarget;
    // Left and Right move along the rail (its tabs are not rows, so Up and Down stay in the list).
    // In the search field they move along the rail only while it is empty (fieldKeyDown).
    if (families && !query && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      const stops = tabs.filter(
        (entry) => !entry.routes.every((route) => route.launch) || families.forkReady !== false,
      );
      const add = rail.current?.querySelector<HTMLButtonElement>(".acpmux-quick-rail-add");
      const fromAdd = event.target === add;
      const count = stops.length + (add ? 1 : 0);
      if (!count) return;
      const at = fromAdd ? stops.length : stops.findIndex((entry) => entry === shownTab);
      const index = (at + (event.key === "ArrowRight" ? 1 : -1) + count) % count;
      event.preventDefault();
      if (index === stops.length) add?.focus();
      else {
        setTab(leadRoute(stops[index]!, families.current).id);
        if (fromAdd) {
          const button =
            rail.current?.querySelectorAll<HTMLButtonElement>(".acpmux-quick-rail-tab")[tabs.indexOf(stops[index]!)];
          (field.current ?? button)?.focus();
        }
        toTop();
      }
      return;
    }
    if (
      event.target === rail.current?.querySelector(".acpmux-quick-rail-add") &&
      (event.key === "Enter" || event.key === " ")
    )
      return;
    // While filtering, a digit is part of the name ("gpt 5"); Enter picks the highlighted match.
    const filters = !!(families || search);
    if (/^[1-9]$/.test(event.key) && (commandDigit || !(filters && query))) {
      const choice = rows[Number(event.key) - 1];
      if (!choice) return;
      event.preventDefault();
      pickRow(choice);
    } else if (event.target === field.current) {
      // The field edits its own text (fieldKeyDown). Enter there picks the highlighted row (the
      // pointer's or the arrows'), else the first match.
      if (event.key !== "Enter") return;
      if (!query && shown?.launch && !shown.note && families?.forkReady !== false) {
        event.preventDefault();
        onOpenChange(false);
        families?.onLaunch?.(shown.id);
        return;
      }
      const highlighted = event.currentTarget.querySelector<HTMLElement>('[role^="menuitem"][data-highlighted]');
      if (highlighted) {
        event.preventDefault();
        highlighted.click();
      } else if (query && rows[0]) {
        event.preventDefault();
        pickRow(rows[0]);
      }
    } else if (filters && event.key === "Backspace" && query) {
      event.preventDefault();
      setQuery(query.slice(0, -1));
      toTop();
    } else if (event.key.length === 1 && (/\S/.test(event.key) || (filters && query))) {
      event.preventDefault();
      // Typing filters the list in place, Claude Code style; without a rail it searches the full picker.
      if (filters) {
        setQuery(query + event.key);
        toTop();
      } else {
        onOpenChange(false);
        onMore(event.key);
      }
    }
  };
  const currentValue = families ? rowValue({ family: families.current ?? "", id: current ?? "" }) : (current ?? "");
  // Keep the model menu's normal state as a compact list. A typed query remains labelled so the
  // filtered context is visible, while the static "Model · this session" caption adds no
  // information beyond the trigger and is intentionally omitted.
  const modelRows = (
    <>
      <MenuRadioGroup
        value={currentValue}
        onValueChange={(value) => {
          const row = rows
            .flatMap((choice) => [choice, ...(choice.offers ?? [])])
            .find((choice) => valueOf(choice) === value);
          if (row) pickRow(row);
        }}
      >
        {(groups ?? [{ id: "", name: "", rows }]).map((group, groupIndex) => {
          const before = groups ? groups.slice(0, groupIndex).reduce((sum, prior) => sum + prior.rows.length, 0) : 0;
          const items = group.rows.map((choice, offset) => {
            const index = before + offset;
            const value = valueOf(choice);
            // The provider the row lands, at its trailing edge. A searched row with no harness heading
            // over it names its harness there too.
            const detail =
              [groups ? undefined : choice.harness, choice.hint ?? choice.provider].filter(Boolean).join(" · ") ||
              undefined;
            const twin = twins.has(choice);
            const label = (
              <>
                {twin ? (
                  <span className="acpmux-quick-twin">
                    <span className="acpmux-menu-label">{choice.name}</span>
                    <span className="acpmux-quick-id">{choice.id}</span>
                  </span>
                ) : (
                  <span className="acpmux-menu-label">{choice.name}</span>
                )}
                {choice.tag && <span className="acpmux-quick-tag">{choice.tag}</span>}
              </>
            );
            // A searched row names itself whole on hover: its model, harness, provider and id.
            const fullName = query
              ? [choice.name, choice.harness, choice.hint ?? choice.provider, choice.id].filter(Boolean).join(" · ")
              : newTab
                ? detail
                  ? `${choice.name} · ${detail}`
                  : choice.name
                : undefined;
            if (choice.offers && providerLook === "submenu")
              return (
                <Submenu
                  key={value}
                  className="acpmux-quick-item acpmux-quick-sub"
                  popupClassName="acpmux-quick-menu acpmux-quick-submenu"
                  label={
                    <>
                      {label}
                      {detail && <span className="acpmux-quick-value">{detail}</span>}
                    </>
                  }
                >
                  <MenuRadioGroup
                    value={currentValue}
                    onValueChange={(next) => {
                      const offer = choice.offers?.find((candidate) => valueOf(candidate) === next);
                      if (offer) pickRow(offer);
                    }}
                  >
                    {choice.offers.map((offer) => providerRow(offer))}
                  </MenuRadioGroup>
                </Submenu>
              );
            if (choice.offers && providerLook === "expanded")
              return (
                <Fragment key={value}>
                  <MenuItem disabled className="acpmux-quick-item acpmux-quick-model-head">
                    <span className="acpmux-quick-label">{label}</span>
                  </MenuItem>
                  {choice.offers.map((offer) => providerRow(offer, "acpmux-quick-item acpmux-quick-offer"))}
                </Fragment>
              );
            return withEffort(
              choice,
              <MenuRadioItem
                key={value}
                value={value}
                closeOnClick
                disabled={choice.disabled}
                className={`acpmux-quick-item${query ? " acpmux-quick-found" : ""}`}
                // tooltip-allow: New Tab's menu keeps its width, so a long model name ends in "…"; the tooltip names it whole, and a searched row's names its harness, provider and id.
                {...(fullName ? { title: fullName } : {})}
                shortcut={
                  !newTab && !query && index < FILTER_ROWS && value !== currentValue
                    ? `${placement === "symbols" ? "⌘" : ""}${index + 1}`
                    : undefined
                }
              >
                <span className="acpmux-quick-label">
                  {label}
                  {detail && <span className="acpmux-quick-value">{detail}</span>}
                </span>
              </MenuRadioItem>,
            );
          });
          return groups ? (
            <MenuGroup key={group.id} label={group.name}>
              {items}
            </MenuGroup>
          ) : (
            <Fragment key="rows">{items}</Fragment>
          );
        })}
      </MenuRadioGroup>
      {rows.length === 0 && (
        <MenuItem disabled className="acpmux-quick-item acpmux-quick-note">
          {query
            ? t(families ? "picker.noMatchesFor" : "picker.noMatchesForQuery", { query })
            : (shown?.note ?? (ownModel ? t("picker.chiefOwnModel") : t("picker.noModels")))}
        </MenuItem>
      )}
      {!query && shown?.note && shown.logIn && (
        <MenuItem className="acpmux-quick-item" onSelect={() => shown.logIn?.()}>
          <span className="acpmux-menu-label">{t("harness.logIn")}</span>
        </MenuItem>
      )}
    </>
  );
  const list = (
    <>
      {forkTab ? (
        <MenuGroup label={forkTab.name}>
          <MenuItem
            className="acpmux-quick-item acpmux-quick-fork"
            disabled={!families?.forkReady}
            onSelect={() => families?.onFork?.(forkTab.id)}
          >
            <span className="acpmux-menu-label">{t("picker.forkTo", { harness: forkTab.name })}</span>
          </MenuItem>
        </MenuGroup>
      ) : query && !groups ? (
        <MenuGroup label={`“${query}”`}>{modelRows}</MenuGroup>
      ) : query ? (
        modelRows
      ) : (
        <>
          {modelRows}
          {inlineMore && shown && shown.more.length > 0 && (
            <MenuItem
              className="acpmux-quick-item acpmux-quick-sub acpmux-quick-disclosure"
              closeOnClick={false}
              expanded={moreShown}
              {...(moreShown ? { controls: moreListId } : {})}
              onSelect={() => setMoreFor(moreShown ? undefined : tab)}
            >
              {moreLabel(shown.more.length)}
              <span className="ui-submenu-chevron" aria-hidden="true" />
            </MenuItem>
          )}
          {/* Its own short scroll area, so Effort, Account and Fast mode stay in view under it. */}
          {moreShown && shown && (
            <fieldset
              id={moreListId}
              className="acpmux-quick-more-list"
              aria-label={t("picker.moreModels")}
              data-single={shown.more.length === 1 ? "" : undefined}
            >
              <MenuRadioGroup
                value={currentValue}
                onValueChange={(value) => {
                  const row = shown.more.find((choice) => rowValue(choice) === value);
                  if (row) pickRow(row);
                }}
              >
                {shown.more.map((choice) =>
                  withEffort(
                    choice,
                    <MenuRadioItem
                      key={choice.id}
                      value={rowValue(choice)}
                      closeOnClick
                      disabled={choice.disabled}
                      className="acpmux-quick-item"
                      // tooltip-allow: a long model name ends in "…" at the menu's width; the tooltip names it whole.
                      title={choice.provider ? `${choice.name} · ${choice.provider}` : choice.name}
                    >
                      <QuickModelLabel model={choice} />
                    </MenuRadioItem>,
                  ),
                )}
              </MenuRadioGroup>
            </fieldset>
          )}
        </>
      )}
      {!query &&
        onChatTab &&
        effort &&
        levels.length > 1 &&
        (effort.slider ||
          !rows.some(
            (row) =>
              row.id === current &&
              effortChoices(row).length > 0 &&
              // Provider submenus and expanded provider rows bypass withEffort; keep the
              // standalone Effort row unless the current row visibly has segments.
              (!row.offers || providerLook === "row"),
          )) && (
          <>
            <MenuSeparator />
            <Submenu
              className="acpmux-quick-item acpmux-quick-sub"
              popupClassName="acpmux-quick-menu acpmux-quick-submenu"
              label={<QuickRowLabel label={t("effort.title")} value={level?.name} />}
            >
              {effort.slider ? (
                <div className="acpmux-quick-effort-slider">
                  <EffortTrack
                    efforts={levels}
                    current={effort.current}
                    fallback={levels.find((choice) => choice.recommended)?.id}
                    sliderStyle={effort.sliderStyle}
                    onPick={effort.onPick}
                    onRangeKey={(event) => {
                      if (EFFORT_SLIDER_KEYS.has(event.key)) event.stopPropagation();
                    }}
                    focusOnMount
                  />
                </div>
              ) : (
                <MenuRadioGroup value={effort.current ?? ""} onValueChange={(value) => effort.onPick(value)}>
                  {levels.map((choice) => (
                    <MenuRadioItem key={choice.id} value={choice.id} closeOnClick className="acpmux-quick-item">
                      <span className="acpmux-menu-label">{choice.name}</span>
                    </MenuRadioItem>
                  ))}
                </MenuRadioGroup>
              )}
            </Submenu>
          </>
        )}
      {!query && runningRow?.offers && providerLook === "row" && !(effort && levels.length > 1) && <MenuSeparator />}
      {!query && runningRow?.offers && providerLook === "row" && (
        <Submenu
          className="acpmux-quick-item acpmux-quick-sub"
          popupClassName="acpmux-quick-menu acpmux-quick-submenu"
          label={<QuickRowLabel label={t("picker.provider")} value={runningProvider} />}
        >
          <MenuRadioGroup
            value={currentValue}
            onValueChange={(next) => {
              const offer = runningRow.offers?.find((candidate) => valueOf(candidate) === next);
              if (offer) pickRow(offer);
            }}
          >
            {runningRow.offers.map((offer) => providerRow(offer))}
          </MenuRadioGroup>
        </Submenu>
      )}
      {!query && (!forkTab || accountShown) && (!inlineMore || accountShown) && <MenuSeparator />}
      {!query && !ownModel && !inlineMore && families && (shown?.more.length ?? 0) > 0 && (
        <Submenu
          align="start"
          className="acpmux-quick-item acpmux-quick-sub"
          popupClassName="acpmux-quick-menu acpmux-quick-submenu acpmux-quick-more"
          label={moreLabel(shown?.more.length ?? 0)}
        >
          {shown && shown.more.length > 0 && (
            <>
              <MenuRadioGroup
                value={currentValue}
                onValueChange={(value) => {
                  const row = shown.more.find((choice) => rowValue(choice) === value);
                  if (row) pickRow(row);
                }}
              >
                {shown.more.map((choice) =>
                  withEffort(
                    choice,
                    <MenuRadioItem
                      key={choice.id}
                      value={rowValue(choice)}
                      closeOnClick
                      disabled={choice.disabled}
                      className="acpmux-quick-item"
                    >
                      <QuickModelLabel model={choice} />
                    </MenuRadioItem>,
                  ),
                )}
              </MenuRadioGroup>
            </>
          )}
        </Submenu>
      )}
      {!query && !families && !ownModel && (
        <MenuItem className="acpmux-quick-item acpmux-quick-sub" onSelect={() => onMore()}>
          <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
          <span className="ui-submenu-chevron" aria-hidden="true" />
        </MenuItem>
      )}
      {auth && authText(auth.verdict, t) && (
        <>
          <MenuSeparator />
          <MenuItem disabled className="acpmux-quick-item acpmux-quick-note">
            <span className="acpmux-menu-label">{authText(auth.verdict, t)}</span>
          </MenuItem>
          {canSessionLogin(auth.verdict) && auth.onLogin && (
            <MenuItem className="acpmux-quick-item" onSelect={() => auth.onLogin?.()}>
              <span className="acpmux-menu-label">{authLoginText(auth.verdict, t)}</span>
            </MenuItem>
          )}
          {auth.onRefresh && (
            <MenuItem className="acpmux-quick-item" onSelect={() => auth.onRefresh?.()}>
              <span className="acpmux-menu-label">{t("harnesses.checkAgain")}</span>
            </MenuItem>
          )}
        </>
      )}
      {!query &&
        accountShown &&
        (menu.routeLayout === "inline" ? (
          <MenuGroup label={t("picker.account")}>
            {familyRoutes}
            {chatAccounts}
          </MenuGroup>
        ) : (
          // The composer's account switcher (Leo, 2026-10-29: "Why the fuck did you remove the
          // fucking account switcher?"; 2026-10-31: "WHERE IS THE FUCKING ACCOUNTS"); #27151 had
          // renamed it Provider. It lists the family's routes (the transports, logins and launch
          // setups that run its models), then the running route's own accounts.
          <Submenu
            className="acpmux-quick-item acpmux-quick-sub acpmux-quick-account"
            popupClassName="acpmux-quick-menu acpmux-quick-submenu"
            label={<QuickRowLabel label={t("picker.account")} value={accountLabel} />}
          >
            {familyRoutes}
            {chatAccounts}
          </Submenu>
        ))}
      {((!query && onChatTab && fast) || tabFast) && (
        <>
          <MenuSeparator />
          <MenuCheckboxItem
            className="acpmux-quick-item acpmux-quick-fast"
            checked={tabFast ? heldFast !== undefined && heldFast === shownTab?.key : !!fast?.checked}
            onCheckedChange={(on) => (tabFast ? setHeldFast(on ? shownTab?.key : undefined) : fast?.onChange(on))}
          >
            <span className="acpmux-menu-label">{t("picker.fastMode")}</span>
            <span className="acpmux-quick-fast-toggle" aria-hidden="true">
              <span />
            </span>
          </MenuCheckboxItem>
        </>
      )}
    </>
  );
  // Keep the compact surface's intrinsic width stable while switching harness tabs. The probe is
  // zero-height and hidden, but its widest model plus inline effort segments still participates in
  // the popup's max-content measurement. This prevents a tab change from moving the rail or
  // pushing the segments past the narrow chat boundary.
  const widthProbe = families ? (
    <div className="acpmux-quick-width-probe" aria-hidden="true">
      {((menu.widthLook ?? "fit") !== "fit" || !shownTab ? families.list : shownTab.routes)
        // The rows a tab shows, never its Legacy models: the longest model name of any harness's
        // Legacy list sized the whole menu, so every row's keys sat far from its name.
        .flatMap((family) => (menu.widthLook === "wide" ? [...family.models, ...family.more] : family.models))
        .map((model) => (
          <div className="acpmux-quick-width-probe-row" key={`${model.family}\u0000${model.id}`}>
            <span className="acpmux-menu-label">{model.name}</span>
            {/* The effort column: its fixed width (CSS), never the levels side by side. */}
            {menu.inlineEffort === true && <span className="acpmux-quick-width-probe-efforts" />}
            {/* The star and the ⌘N key after it, so every tab's rows fit whichever tab shows. */}
            <span
              className={`acpmux-quick-width-probe-trail${families.stars ? " acpmux-quick-width-probe-starred" : ""}`}
            />
          </div>
        ))}
    </div>
  ) : null;
  return (
    <Menu open={open} onOpenChange={onOpenChange}>
      <MenuButton className="acpmux-picker-button" aria-haspopup="menu" buttonRef={trigger} {...chip}>
        {children}
      </MenuButton>
      <MenuPopup
        side={side}
        flip={false}
        align="start"
        label={t("picker.model")}
        className={`acpmux-quick-menu acpmux-quick-placement-${placement} acpmux-quick-width-${menu.widthLook ?? "fit"}${families ? " acpmux-quick-railed" : ""}${newTab ? " acpmux-quick-newtab" : ""}`}
        boundary={CHAT_COLUMN}
        // A native menu panel cannot draw the harness strip or the More models scroll area.
        // Keep this combined surface inside the window in both directions.
        escapes={!families}
        // ui-allow: 1 to 9 pick a row in place and typing filters the list, as in Claude Code's model menu.
        onKeyDown={keyDown}
      >
        {widthProbe}
        {showField && (
          <div className="acpmux-quick-search">
            <SearchIcon size={14} />
            <input
              ref={field}
              type="search"
              aria-label={t("picker.search")}
              placeholder={t("picker.search")}
              autoComplete="off"
              spellCheck={false}
              value={query}
              onChange={(event) => {
                setQuery(event.target.value);
                toTop();
              }}
              onKeyDown={fieldKeyDown}
            />
          </div>
        )}
        {families ? (
          <div className="acpmux-quick-layout">
            {/* One harness strip at the chip-facing edge: its position stays put as rows change. */}
            <fieldset ref={railRef} className="acpmux-quick-rail" aria-label={t("picker.harness")}>
              {tabs.map((entry) => {
                const family = entry === shownTab ? shown! : leadRoute(entry, families.current);
                const name = entry.name;
                return (
                  <button
                    key={entry.key}
                    type="button"
                    aria-label={name}
                    // While a search shows, no tab is the list's: the matches are every harness's.
                    aria-pressed={!query && entry === shownTab}
                    disabled={entry.routes.every((route) => route.launch) && families.forkReady === false}
                    // tooltip-allow: the rail tab draws only the harness's mark (its symbol, else its
                    // name's initial), never a machine or session initial; its accessible name and
                    // title identify the harness.
                    title={family.note ? `${name} · ${family.note}` : name}
                    className="acpmux-quick-rail-tab"
                    // ui-allow: the rail is no row of the menu; ArrowLeft and ArrowRight move along it, so Up and Down stay in the list.
                    tabIndex={-1}
                    onClick={() => {
                      if (entry.routes.length === 1 && family.launch && !family.note) {
                        onOpenChange(false);
                        families.onLaunch?.(family.id);
                        return;
                      }
                      setTab(family.id);
                      setQuery("");
                      toTop();
                    }}
                  >
                    {family.starred ? (
                      <StarIcon />
                    ) : symbolOf(family) ? (
                      <AgentMark agent={family.mark} size={16} tint={placement === "symbols"} />
                    ) : placement === "symbols" ? (
                      <span className="acpmux-quick-rail-initial" aria-hidden="true">
                        {initialOf(name)}
                      </span>
                    ) : null}
                    {/* The symbols row is marks only, never text on a tab (Leo 2026-10-31: "NOBODY
                      FUCKING ASKED FOR THE HARNESSES TO HAVE FUCKING LABELED FUCKING TEXT ON THEM
                      THAT'S THE POINT"): the name is the tab's accessible name and its tooltip. */}
                    <span className={`acpmux-quick-harness-name${placement === "symbols" ? " sr-only" : ""}`}>
                      {name}
                    </span>
                  </button>
                );
              })}
              {families.onAddHarness && (
                <button
                  type="button"
                  className="acpmux-quick-rail-tab acpmux-quick-rail-add"
                  tabIndex={-1}
                  aria-label={t("modelPicker.addHarness")}
                  title={t("modelPicker.addHarness")}
                  onClick={() => {
                    onOpenChange(false);
                    families.onAddHarness?.();
                  }}
                >
                  <span aria-hidden="true" className="acpmux-quick-rail-add-icon">
                    +
                  </span>
                  <span className="sr-only">{t("modelPicker.addHarness")}</span>
                </button>
              )}
            </fieldset>
            <div
              className="acpmux-quick-body"
              ref={body}
              data-scrolled={scrolled ? "" : undefined}
              onScroll={(event) => setScrolled(event.currentTarget.scrollTop > 0)}
            >
              <div className="acpmux-quick-list">{list}</div>
            </div>
          </div>
        ) : (
          list
        )}
        {menu.update && (
          <div className="acpmux-quick-update">
            <span>{menu.update.text}</span>
            <MenuItem
              className="acpmux-quick-update-action"
              onSelect={() => {
                menu.update?.run();
                onOpenChange(false);
              }}
            >
              {t("harness.update")}
            </MenuItem>
          </div>
        )}
      </MenuPopup>
    </Menu>
  );
}

/// The rail's Starred tab: an outline star.
function StarIcon({ filled = false }: { filled?: boolean }) {
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M8 1.8l1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z"
        fill={filled ? "currentColor" : "none"}
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/// A submenu row: its name, then the current value in secondary text before the chevron.
/// A More models row: the model's name, its tag, and the provider it lands at the trailing edge.
function QuickModelLabel({ model }: { model: Pick<QuickModel, "name" | "tag" | "provider"> }) {
  return (
    <span className="acpmux-quick-label">
      <span className="acpmux-menu-label">{model.name}</span>
      {model.tag && <span className="acpmux-quick-tag">{model.tag}</span>}
      {model.provider && <span className="acpmux-quick-value">{model.provider}</span>}
    </span>
  );
}

function QuickRowLabel({ label, value }: { label: string; value?: string }) {
  return (
    <>
      <span className="acpmux-menu-label">{label}</span>
      {value && <span className="acpmux-quick-value">{value}</span>}
    </>
  );
}

/// The Account submenu: the harness's own login (the chat's default binding), then each route
/// for a direct account serving this chat, plus its current binding when that is a transport or
/// an older route without a kind. A chat bound by its workspace or family checks that route, and CLI login
/// is disabled: unbinding the chat would leave it on that route. With no routes it lists CLI login
/// alone, with no note about route files (Leo 2026-10-28: "add accounts as route files in whatever.
/// I feel like that's just weird"); a switch acpmux refused says so first.
function AccountRows({
  list,
  failed,
  switchFailed,
  onPick,
  grouped = false,
}: {
  list?: ChatAccountList;
  failed: boolean;
  switchFailed: boolean;
  onPick(routeId: string | null): void;
  grouped?: boolean;
}) {
  const t = useT();
  const refused = switchFailed && (
    <MenuItem disabled className="acpmux-quick-item acpmux-quick-note">
      {t("picker.accountSwitchFailed")}
    </MenuItem>
  );
  if (!list)
    return (
      <>
        {refused}
        <MenuItem disabled>{failed ? t("picker.accountFailed") : "…"}</MenuItem>
      </>
    );
  // "" is the harness login: the chat follows its default binding, or none.
  const value = list.active ?? "";
  // The session-scoped list has already removed other harness families. Cmux is a provider
  // choice here, never a harness tab. Preserve the current binding even for older route kinds.
  const choices = list.accounts.filter(
    (choice) =>
      choice.kind === "direct-subscription" ||
      choice.kind === "direct-api-key" ||
      isModelRouterKind(choice.kind) ||
      choice.id === list.active,
  );
  const choiceRows = (rows: typeof choices) =>
    rows.map((choice) => (
      <MenuRadioItem key={choice.id} value={choice.id} closeOnClick className="acpmux-quick-item">
        <span className="acpmux-menu-label">{choice.name}</span>
      </MenuRadioItem>
    ));
  const routers = choices.filter((choice) => isModelRouterKind(choice.kind));
  return (
    <>
      {refused}
      <MenuRadioGroup value={value} onValueChange={(next) => next !== value && onPick(next || null)}>
        {/* Back to the default only unbinds the chat; a workspace or family route still applies. */}
        <MenuRadioItem
          value=""
          closeOnClick
          className="acpmux-quick-item"
          disabled={list.scope !== "chat" && !!list.active}
        >
          <span className="acpmux-menu-label">{t("picker.harnessLogin")}</span>
        </MenuRadioItem>
        {grouped ? (
          <>
            {choiceRows(choices.filter((choice) => !isModelRouterKind(choice.kind)))}
            {routers.length > 0 && <MenuGroup label={t("picker.provider")}>{choiceRows(routers)}</MenuGroup>}
          </>
        ) : (
          choiceRows(choices)
        )}
      </MenuRadioGroup>
    </>
  );
}

/// The chat's accounts, read each time the menu opens (acpmux holds them; nothing polls), and a
/// pick that switches the chat. A refused switch (acpmux's route.unavailable, a route of another
/// family) stays named on the Account row until a switch succeeds or the chat changes.
function useAccountList(open: boolean, account: QuickMenu["account"]) {
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
