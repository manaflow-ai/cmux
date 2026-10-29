import React, { useContext, useEffect, useRef, useState } from "react";
import type { ChatAccountList, ChatAccounts } from "./chatAccounts";
import type { Choice } from "./ComposerPickers";
import type { HarnessPlacement, ReasoningSliderStyle } from "./composerSettings";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { useOpenSide } from "../../ui/openSide";
import { useNativePopup, type NativePopupDescription, type NativePopupEvent, type NativePopupRow } from "../../ui/nativePopup";
import { OnNewTab } from "./newTabComposer";

/// What the model button's menu lists (Leo 2026-10-20: every composer's one model control): the
/// harness's top models, numbered, then Effort, More models and Account submenus, then Fast mode.
export type QuickMenu = {
  /// The numbered rows: this harness's top models, with the running one among them.
  models: readonly Omit<QuickModel, "family">[];
  current?: string;
  onModel(id: string): void;
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
  harnessPlacement?: HarnessPlacement;
};

export type QuickSearchField = "always" | "typed" | "long";

/// How many models (the tab's rows and More models) make a list long enough for the `long`
/// version's search field.
const LONG_LIST = 8;

export type QuickProviderLook = "row" | "submenu" | "expanded";

/// A model row of any harness: `family` is the rail tab (harness) it belongs to. A searched row
/// names its harness, effort and fast mode in `hint`, and lands `effort` and `fast` when picked. A
/// model several providers serve is one row (modelVariants.ts): it lands its own `id`, and `offers`
/// holds every provider's row; `tag` is a note its name carried ("New").
export type QuickModel = {
  id: string;
  name: string;
  family: string;
  disabled?: boolean;
  hint?: string;
  effort?: string;
  fast?: boolean;
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
  /// A started chat's other harness: offer Fork to it in place of models.
  fork?: boolean;
};

export type QuickFamilies = {
  list: QuickFamily[];
  /// The chat's harness: its tab opens first, and only it shows Effort and Account.
  current?: string;
  onPick(model: QuickModel): void;
  /// Add harness…, the last row of More models.
  onAddHarness?(): void;
  onLaunch?(id: string): void;
  onFork?(id: string): void;
  forkReady?: boolean;
};

/// Keys 1 to 9 pick a tab's first rows; this does not limit the visible model list.
const FILTER_ROWS = 9;
const EFFORT_SLIDER_KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);

const rowValue = (model: Pick<QuickModel, "family" | "id">) => `${model.family}\u0000${model.id}`;
/// The running model's row when several providers serve it: the running offer may be another
/// provider's than the row lands, when the running one is unavailable.
const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);

/// What the composer hands the model picker for its compact menu; the picker adds the models.
export type QuickMenuExtras = Pick<QuickMenu, "effort" | "account" | "fast" | "searchField" | "providers">;

/// The compact model menu keeps numbered rows, Effort and Account flyouts, and Fast mode.
/// Its search field filters models in place using the full picker's matching.
export function QuickModelMenu({
  open, onOpenChange, trigger, chip, menu, onMore, children,
}: {
  open: boolean; onOpenChange(open: boolean): void;
  trigger: React.RefObject<HTMLButtonElement | null>;
  chip: { "data-menu": string; label: string; title: string };
  menu: QuickMenu; onMore(query?: string): void; children: React.ReactNode;
}) {
  const t = useT();
  const newTab = useContext(OnNewTab);
  const { open: sideOpen, setOpen: setSideOpen, side } = useOpenSide(trigger, newTab ? "bottom" : "top", 320);
  if (sideOpen !== open) setSideOpen(open);
  const { models, current, effort, account, fast } = menu;
  const levels = effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? [];
  const level = levels.find((choice) => choice.id === effort?.current);
  const accounts = useAccountList(open, account);
  const families = menu.families;
  const [tab, setTab] = useState(families?.current);
  const [query, setQuery] = useState("");
  const [moreFor, setMoreFor] = useState<string | undefined>();
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
      setQuery(""); setMoreFor(undefined);
    }
  }
  const search = menu.search;
  const shown = families?.list.find((family) => family.id === tab);
  const onChatTab = !families || tab === families.current;
  const forkTab = !query && shown?.fork ? shown : undefined;
  const inlineMore = newTab && families !== undefined;
  const moreShown = inlineMore && !query && moreFor !== undefined && moreFor === tab;
  const look = menu.searchField ?? "always";
  const listed = look !== "long" ? 0 : families ? (shown ? shown.models.length + shown.more.length : 0) : (search?.find("").length ?? 0);
  const showField = !!search && (look === "always" || query !== "" || (look === "long" && listed > LONG_LIST));
  const rows: QuickModel[] = query && search ? search.find(query) : !families ? models.map((model) => ({ ...model, family: "" })) : shown?.models ?? [];
  const providerLook = menu.providers ?? "row";
  const currentValue = families ? rowValue({ family: families.current ?? "", id: current ?? "" }) : (current ?? "");
  const valueOf = (model: Pick<QuickModel, "family" | "id">) => (families ? rowValue(model) : model.id);
  const runningRow = onChatTab ? (families ? shown?.models : models)?.find((model) => runsOffers(model, current)) : undefined;
  const runningProvider = runningRow?.offers?.find((offer) => offer.id === current)?.provider;
  const modelRow = (choice: QuickModel, index?: number): NativePopupRow => {
    const value = valueOf(choice);
    return {
      id: `model:${value}`, kind: choice.offers && providerLook === "submenu" ? "submenu" : choice.offers && providerLook === "expanded" ? "section" : "choice", label: choice.name,
      ...(choice.tag ? { description: choice.tag } : {}), ...(choice.hint || choice.provider ? { value: choice.hint ?? choice.provider } : {}),
      ...(choice.disabled ? { disabled: true } : {}), checked: value === currentValue,
      ...(!newTab && !query && index !== undefined && index < FILTER_ROWS && value !== currentValue ? { shortcut: String(index + 1) } : {}),
      ...(choice.offers && (providerLook === "submenu" || providerLook === "expanded") ? { children: choice.offers.map((offer) => modelRow(offer)) } : {}),
    };
  };
  const visibleRows: NativePopupRow[] = rows.map((choice, index) => modelRow(choice, index));
  if (!visibleRows.length) visibleRows.push({ kind: "text", id: "empty", label: query ? t("picker.noMatches") : (shown?.note ?? t("picker.noMatches")), disabled: true });
  if (!query && shown?.note && shown.logIn) visibleRows.push({ kind: "action", id: "login", label: t("harness.logIn") });
  if (forkTab) visibleRows.splice(0, visibleRows.length, { kind: "action", id: `fork:${forkTab.id}`, label: t("picker.forkTo", { harness: forkTab.name }), disabled: families?.forkReady === false });
  if (!query && inlineMore && shown && shown.more.length > 0) {
    const moreRows = moreShown ? shown.more.map((choice) => modelRow(choice)) : [];
    visibleRows.push({ kind: moreShown ? "section" : "action", id: "more-models", label: t("picker.moreModels"), keepOpen: true, ...(moreRows.length ? { children: moreRows } : {}) });
  }
  if (!query && inlineMore && families?.onAddHarness && (moreShown || !shown?.more.length)) visibleRows.push({ kind: "action", id: "add-harness", label: t("modelPicker.addHarness") });
  if (!query && onChatTab && effort && levels.length > 1) visibleRows.push({ kind: "submenu", id: "effort", label: t("effort.title"), value: level?.name, children: effort.slider ? [{ kind: "slider", id: "effort-slider", label: t("effort.title"), value: effort.current, minimum: 0, maximum: Math.max(0, levels.length - 1), step: 1 }] : levels.map((choice) => ({ kind: "choice" as const, id: `effort:${choice.id}`, label: choice.name, checked: choice.id === effort.current })) });
  if (!query && runningRow?.offers && providerLook === "row") visibleRows.push({ kind: "submenu", id: "provider", label: t("picker.provider"), value: runningProvider, children: runningRow.offers.map((offer) => modelRow(offer)) });
  if (!query && !forkTab && !inlineMore && families && ((shown?.more.length ?? 0) > 0 || families.onAddHarness)) visibleRows.push({ kind: "submenu", id: "more-models", label: t("picker.moreModels"), children: [...(shown?.more.map((choice) => modelRow(choice)) ?? []), ...(families.onAddHarness ? [{ kind: "action" as const, id: "add-harness", label: t("modelPicker.addHarness") }] : [])] });
  if (!query && !families) visibleRows.push({ kind: "action", id: "more-models", label: t("picker.moreModels") });
  if (!query && onChatTab && account) {
    const accountValue = accounts.switchFailed ? t("picker.accountSwitchFailed") : accounts.list ? (accounts.list.accounts.find((choice) => choice.id === accounts.list?.active)?.name ?? t("picker.harnessLogin")) : undefined;
    const accountRows: NativePopupRow[] = accounts.list ? [{ kind: "choice", id: "account:", label: t("picker.harnessLogin"), checked: !accounts.list.active, disabled: accounts.list.scope !== "chat" && !!accounts.list.active }, ...accounts.list.accounts.filter((choice) => choice.kind === "direct-subscription" || choice.kind === "direct-api-key" || choice.id === accounts.list?.active).map((choice) => ({ kind: "choice" as const, id: `account:${choice.id}`, label: choice.name, checked: choice.id === accounts.list?.active }))] : [{ kind: "text", id: "account-status", label: accounts.failed ? t("picker.accountFailed") : "…", disabled: true }];
    visibleRows.push({ kind: "submenu", id: "account", label: t("picker.account"), value: accountValue, children: accountRows });
  }
  if (!query && onChatTab && fast) visibleRows.push({ kind: "toggle", id: "fast", label: t("picker.fastMode"), checked: fast.checked });
  const rail = families?.list.map((family) => ({ kind: "action" as const, id: `family:${family.id}`, label: family.name, ...(family.mark ? { icon: family.mark } : {}), checked: family.id === tab, disabled: family.launch && families.forkReady === false }));
  const model: NativePopupDescription = { side, align: "start", width: families ? 310 : 280, title: t("picker.model"), rows: visibleRows, ...(rail ? { rail, railWidth: 44 } : {}), ...(showField ? { search: { id: "query", value: query, placeholder: t("picker.search") } } : {}), ...(menu.update ? { footer: [{ kind: "action", id: "update", label: t("harness.update"), description: menu.update.text }] } : {}) };
  const findModel = (id: string): QuickModel | undefined => [...rows, ...(shown?.more ?? []), ...(runningRow?.offers ?? []), ...rows.flatMap((choice) => choice.offers ?? [])].find((choice) => `model:${valueOf(choice)}` === id);
  const pickRow = (row: QuickModel) => {
    if (row.disabled) return;
    onOpenChange(false);
    const running = (!families || row.family === families.current) && row.id === current;
    if (running && !row.effort && !row.fast) return;
    if (query && search) search.pick(row); else if (!families) menu.onModel(row.id); else families.onPick(row);
  };
  const onEvent = (event: NativePopupEvent) => {
    const id = event.id ?? "";
    if (event.type === "search" && id === "query") { setQuery(event.value ?? ""); return; }
    if (event.type !== "pick" && event.type !== "change") return;
    if (id.startsWith("model:")) { const row = findModel(id); if (row) pickRow(row); }
    else if (id.startsWith("family:") && families) { const family = families.list.find((candidate) => `family:${candidate.id}` === id); if (!family) return; if (family.launch && !family.note) { onOpenChange(false); families.onLaunch?.(family.id); } else { setTab(family.id); setQuery(""); setMoreFor(undefined); } }
    else if (id === "more-models") { if (inlineMore) setMoreFor((value) => (value === tab ? undefined : tab)); else { onOpenChange(false); onMore(query || undefined); } }
    else if (id === "add-harness") { onOpenChange(false); families?.onAddHarness?.(); }
    else if (id === "login") { onOpenChange(false); shown?.logIn?.(); }
    else if (id.startsWith("fork:") && families) { onOpenChange(false); families.onFork?.(id.slice("fork:".length)); }
    else if (id.startsWith("effort:")) effort?.onPick(id.slice("effort:".length));
    else if (id.startsWith("account:")) { onOpenChange(false); accounts.pick(id.slice("account:".length) || null); }
    else if (id === "fast") fast?.onChange(event.value === undefined ? !fast.checked : event.value === "true");
    else if (id === "update") { onOpenChange(false); menu.update?.run(); }
  };
  const { available } = useNativePopup({ open, model, anchor: () => trigger.current, onEvent, onDismiss: () => onOpenChange(false) });
  useEffect(() => { if (open && !available) onOpenChange(false); }, [available, onOpenChange, open]);
  return <button type="button" ref={trigger} className="acpmux-picker-button" data-menu={chip["data-menu"]} aria-label={chip.label} title={chip.title} aria-haspopup="menu" aria-expanded={open} onClick={() => onOpenChange(!open)}>{children}</button>;
}

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
