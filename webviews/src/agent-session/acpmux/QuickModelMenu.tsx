import React, { Fragment, useContext, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { AgentMark } from "../shared/AgentMark";
import type { ChatAccountList, ChatAccounts } from "./chatAccounts";
import { SearchIcon, type Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
import type { ReasoningSliderStyle } from "./composerSettings";
import { useT } from "./i18n";
import { CHAT_COLUMN } from "./modelPickerLayout";
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
  /// The harness accounts shown in its Account submenu.
  accounts?: QuickAccount[];
  /// The account the tab runs or starts on.
  account?: string;
  /// A started chat's other harness: offer Fork to it in place of models.
  fork?: boolean;
};

/// One account of a harness, by profile id.
export type QuickAccount = { id: string; name: string; disabled?: boolean };

export type QuickFamilies = {
  list: QuickFamily[];
  /// The chat's harness: its tab opens first, and only it shows Effort and Account.
  current?: string;
  onPick(model: QuickModel): void;
  /// Add harness…, the last row of More models.
  onAddHarness?(): void;
  onAccount?(id: string): void;
  onFork?(id: string): void;
  forkReady?: boolean;
};

/// How many rows a list shows at once (keys 1 to 9 pick a tab's rows).
const FILTER_ROWS = 9;
const EFFORT_SLIDER_KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);

const rowValue = (model: Pick<QuickModel, "family" | "id">) => `${model.family}\u0000${model.id}`;
/// The running model's row when several providers serve it: the running offer may be another
/// provider's than the row lands, when the running one is unavailable.
const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);

/// What one rail tab's unfiltered list draws, in rows and separators (the group label is in every
/// tab). The menu opens above its chip, so a taller or shorter tab moved the rail under the pointer;
/// the list keeps the tallest tab's height for the whole opening (QuickMenuSpacer).
export type TabExtent = { rows: number; separators: number };

/// Mirrors the unfiltered `list` in QuickModelMenu row for row: keep the two in step.
export function tabExtent(
  family: QuickFamily,
  menu: Pick<QuickMenu, "account" | "fast" | "current" | "providers"> & { families: QuickFamilies; levels: number },
): TabExtent {
  const chat = family.id === menu.families.current;
  const look = menu.providers ?? "row";
  const listed = family.models.slice(0, FILTER_ROWS);
  const models = listed.reduce(
    (count, model) => count + 1 + (look === "expanded" ? (model.offers?.length ?? 0) : 0),
    0,
  );
  let rows = models || 1;
  let separators = 1;
  if (family.note && family.logIn) rows += 1;
  if (chat && menu.levels > 1) {
    rows += 1;
    separators += 1;
  }
  // The Provider row, after Effort, for a running model several providers serve.
  if (chat && look === "row" && listed.some((model) => runsOffers(model, menu.current))) {
    rows += 1;
    if (menu.levels <= 1) separators += 1;
  }
  if (family.more.length > 0 || menu.families.onAddHarness) rows += 1;
  if ((chat && menu.account) || (menu.families.onAccount && (family.accounts?.length ?? 0) > 1)) rows += 1;
  if (chat && menu.fast) {
    rows += 1;
    separators += 1;
  }
  return { rows, separators };
}

/// One row of any tab, for the width probe: its label, its secondary value, and whether it opens a
/// submenu (a chevron), shows a number key, or shows the chosen model's check (wider: it has its own
/// leading padding).
export type ProbeRow = { label: string; value?: string; sub?: boolean; shortcut?: boolean; check?: boolean };

/// The tallest tab's rows and separators, unseen in the list's grid cell under the real rows, so
/// switching tabs or typing never changes the menu's height while it is open. `widths` is every
/// tab's rows at no height: the cell is as wide as the widest tab, so its width holds too.
function QuickMenuSpacer({
  rows,
  separators,
  widths,
  holdHeight = true,
}: TabExtent & {
  widths: ProbeRow[];
  /// False holds the width alone: New Tab's menu opens down, so its top and rail stay put as its
  /// height follows the rows, and it never shows empty rows under them.
  holdHeight?: boolean;
}) {
  return (
    <div className="acpmux-quick-spacer" aria-hidden="true" inert>
      <div className="acpmux-quick-probe">
        {widths.map((row, index) => (
          <div key={index} className={`ui-menu-item acpmux-quick-item${row.sub ? " acpmux-quick-sub" : ""}`}>
            <span className="acpmux-menu-label">{row.label}</span>
            {row.value && <span className="acpmux-quick-value">{row.value}</span>}
            {row.check && <span className="ui-menu-check">✓</span>}
            {row.sub && <span className="ui-submenu-chevron" />}
            {row.shortcut && <span className="ui-menu-shortcut">9</span>}
          </div>
        ))}
      </div>
      {/* A separator after each of the first rows: back to back, their margins would collapse. */}
      {Array.from({ length: holdHeight ? rows : 0 }, (_, index) => (
        <Fragment key={index}>
          <div className="ui-menu-item acpmux-quick-item" />
          {index < separators && <div className="ui-separator" />}
        </Fragment>
      ))}
    </div>
  );
}

/// What the composer hands the model picker for its compact menu; the picker adds the models.
export type QuickMenuExtras = Pick<QuickMenu, "effort" | "account" | "fast" | "searchField" | "providers">;

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
  // On New Tab the menu opens down, shows no key hints and opens More models in place (newTabComposer.ts).
  const newTab = useContext(OnNewTab);
  const { models, current, effort, account, fast } = menu;
  const levels = effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? [];
  const level = levels.find((choice) => choice.id === effort?.current);
  const accounts = useAccountList(open, account);
  const families = menu.families;
  // The rail's tab and the typed filter start over with each opening.
  const [tab, setTab] = useState(families?.current);
  const [query, setQuery] = useState("");
  // On New Tab, More models is a row that shows the tab's other models in place, as T3 Code's
  // model menu does, not a submenu: the rail tab it was opened on.
  const [moreFor, setMoreFor] = useState<string | undefined>();
  const moreListId = useId();
  // Reset as the menu opens, in render: the composer re-renders while it is open (a streaming
  // reply), and an effect on the families would throw away the tab and the typed filter.
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
      setQuery("");
      setMoreFor(undefined);
    }
  }
  // Typing can unmount the focused row (Effort, Account, a model it filters out); keyboard focus
  // goes to the first row left, so the next key, Enter and Escape still reach the menu. A
  // re-render with the same filter (a streaming reply hands over new families) keeps the row the
  // keyboard moved to, so Enter picks it.
  // With a search field the keyboard sits in it from the moment the menu opens, and a key typed
  // on a row goes back to it.
  const popup = useRef<HTMLDivElement | null>(null);
  // Another tab or filter starts at its top: the held height keeps a tall tab's scroll range, which
  // could leave a short tab's rows above the view.
  const body = useRef<HTMLDivElement | null>(null);
  const toTop = () => {
    if (body.current) body.current.scrollTop = 0;
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
      if ((query && typed && active !== input) || !node.contains(active)) {
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
  const inlineMore = newTab && families !== undefined;
  const moreShown = inlineMore && !query && moreFor !== undefined && moreFor === tab;
  const profiles = families?.onAccount && (shown?.accounts?.length ?? 0) > 1 ? shown?.accounts : undefined;
  const profile = shown?.account ?? shown?.id;
  // What the list draws: the search's matches, else the tab's top models.
  const rows: QuickModel[] =
    query && search
      ? search.find(query).slice(0, FILTER_ROWS)
      : !families
        ? models.map((model) => ({ ...model, family: "" }))
        : (shown?.models.slice(0, FILTER_ROWS) ?? []);
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
  const pickRow = (row: QuickModel) => {
    if (row.disabled) return;
    onOpenChange(false);
    const running = (!families || row.family === families.current) && row.id === current;
    if (running && !row.effort && !row.fast) return;
    if (query && search) search.pick(row);
    else if (!families) menu.onModel(row.id);
    else families.onPick(row);
  };
  /// The field's editing keys stay in it: Base UI's typeahead and the menu's own keys never see
  /// them. Digits on an empty field still pick a row, and Left and Right move along the rail.
  const fieldKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.nativeEvent.isComposing) {
      event.stopPropagation();
      return;
    }
    const { key } = event;
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
  const keyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.nativeEvent.isComposing) return;
    // Only the menu's own keys, not a submenu's (React carries those up through the portal).
    if (!event.currentTarget.contains(event.target as Node)) return;
    popup.current = event.currentTarget;
    // Left and Right move along the rail (its tabs are not rows, so Up and Down stay in the list).
    // In the search field they move along the rail only while it is empty (fieldKeyDown).
    if (families && !query && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      const tabs = families.list;
      const at = tabs.findIndex((family) => family.id === tab);
      const next = tabs[(at + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length];
      if (next) {
        event.preventDefault();
        setTab(next.id);
        toTop();
      }
      return;
    }
    // While filtering, a digit is part of the name ("gpt 5"); Enter picks the highlighted match.
    const filters = !!(families || search);
    if (/^[1-9]$/.test(event.key) && !(filters && query)) {
      const choice = rows[Number(event.key) - 1];
      if (!choice) return;
      event.preventDefault();
      pickRow(choice);
    } else if (event.target === field.current) {
      // The field edits its own text (fieldKeyDown). Enter there picks the highlighted row (the
      // pointer's or the arrows'), else the first match.
      if (event.key !== "Enter") return;
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
  const tallest = (families?.list ?? []).reduce<TabExtent>(
    (most, family) => {
      const extent = tabExtent(family, {
        families: families!,
        levels: levels.length,
        account,
        fast,
        current,
        providers: menu.providers,
      });
      return { rows: Math.max(most.rows, extent.rows), separators: Math.max(most.separators, extent.separators) };
    },
    // A typed filter: up to FILTER_ROWS matches from every searched tab (or its one note row), no
    // separators. It can be taller than any one tab's list.
    {
      rows: Math.max(
        1,
        Math.min(
          FILTER_ROWS,
          (families?.list ?? [])
            .filter((family) => !family.starred && !family.note)
            .reduce((count, family) => count + family.models.length + family.more.length, 0),
        ),
      ),
      separators: 0,
    },
  );
  // Every tab's unfiltered rows, for the width the menu holds while open.
  const widths: ProbeRow[] = families
    ? [
        ...families.list.flatMap((family): ProbeRow[] => [
          ...family.models.slice(0, FILTER_ROWS).flatMap((model): ProbeRow[] => {
            // The tag and the provider take the row's width too.
            const label = model.tag ? `${model.name} ${model.tag}` : model.name;
            const value = model.provider ? { value: model.provider } : {};
            return [
              family.id === families.current && model.id === current
                ? { label, ...value, check: true }
                : { label, ...value, shortcut: true },
              ...(family.id === families.current && runsOffers(model, current)
                ? [
                    {
                      label: t("picker.provider"),
                      value: model.offers?.find((offer) => offer.id === current)?.provider,
                      sub: true,
                    },
                  ]
                : []),
            ];
          }),
          ...(family.note && family.models.length === 0 ? [{ label: family.note }] : []),
          ...(family.note && family.logIn ? [{ label: t("harness.logIn") }] : []),
          ...(family.fork ? [{ label: t("picker.forkTo", { harness: family.name }) }] : []),
          ...(families.onAccount && family.accounts && family.accounts.length > 1
            ? [
                {
                  label: t("picker.account"),
                  value: family.accounts.find((choice) => choice.id === family.account)?.name,
                  sub: true,
                },
              ]
            : []),
        ]),
        ...(effort && levels.length > 1 ? [{ label: t("effort.title"), value: level?.name, sub: true }] : []),
        { label: t("picker.moreModels"), sub: true },
        ...(account ? [{ label: t("picker.account"), value: accountValue, sub: true }] : []),
        ...(fast ? [{ label: t("picker.fastMode") }] : []),
      ]
    : [];
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
        {rows.map((choice, index) => {
          const value = valueOf(choice);
          // The provider the row lands, at its trailing edge, where a searched row names its harness.
          const detail = choice.hint ?? choice.provider;
          const label = (
            <>
              <span className="acpmux-menu-label">{choice.name}</span>
              {choice.tag && <span className="acpmux-quick-tag">{choice.tag}</span>}
            </>
          );
          if (choice.offers && providerLook === "submenu")
            return (
              <Submenu
                key={value}
                className="acpmux-quick-item acpmux-quick-sub"
                popupClassName="acpmux-quick-menu"
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
          return (
            <MenuRadioItem
              key={value}
              value={value}
              closeOnClick
              disabled={choice.disabled}
              className="acpmux-quick-item"
              // tooltip-allow: New Tab's menu keeps its width, so a long model name ends in "…"; the tooltip names it whole.
              {...(newTab ? { title: detail ? `${choice.name} · ${detail}` : choice.name } : {})}
              shortcut={
                !newTab && !query && index < FILTER_ROWS && value !== currentValue ? String(index + 1) : undefined
              }
            >
              <span className="acpmux-quick-label">
                {label}
                {detail && <span className="acpmux-quick-value">{detail}</span>}
              </span>
            </MenuRadioItem>
          );
        })}
      </MenuRadioGroup>
      {rows.length === 0 && (
        <MenuItem disabled className="acpmux-quick-item acpmux-quick-note">
          {query ? t("picker.noMatches") : (shown?.note ?? t("picker.noMatches"))}
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
      ) : query ? (
        <MenuGroup label={`“${query}”`}>{modelRows}</MenuGroup>
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
              <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
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
                {shown.more.map((choice) => (
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
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
            </fieldset>
          )}
          {inlineMore && families.onAddHarness && (moreShown || !shown?.more.length) && (
            <MenuItem className="acpmux-quick-item" onSelect={() => families.onAddHarness?.()}>
              <span className="acpmux-menu-label">{t("modelPicker.addHarness")}</span>
            </MenuItem>
          )}
        </>
      )}
      {!query && onChatTab && effort && levels.length > 1 && (
        <>
          <MenuSeparator />
          <Submenu
            className="acpmux-quick-item acpmux-quick-sub"
            popupClassName="acpmux-quick-menu"
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
          popupClassName="acpmux-quick-menu"
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
      {!query && !(forkTab && !profiles) && (!inlineMore || (onChatTab && account) || profiles) && <MenuSeparator />}
      {!query && !inlineMore && families && ((shown?.more.length ?? 0) > 0 || families.onAddHarness) && (
        <Submenu
          className="acpmux-quick-item acpmux-quick-sub"
          popupClassName="acpmux-quick-menu acpmux-quick-more"
          label={<span className="acpmux-menu-label">{t("picker.moreModels")}</span>}
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
                {shown.more.map((choice) => (
                  <MenuRadioItem
                    key={choice.id}
                    value={rowValue(choice)}
                    closeOnClick
                    disabled={choice.disabled}
                    className="acpmux-quick-item"
                  >
                    <QuickModelLabel model={choice} />
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
              {families.onAddHarness && <MenuSeparator />}
            </>
          )}
          {families.onAddHarness && (
            <MenuItem className="acpmux-quick-item" onSelect={() => families.onAddHarness?.()}>
              <span className="acpmux-menu-label">{t("modelPicker.addHarness")}</span>
            </MenuItem>
          )}
        </Submenu>
      )}
      {!query && !families && (
        <MenuItem className="acpmux-quick-item acpmux-quick-sub" onSelect={() => onMore()}>
          <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
          <span className="ui-submenu-chevron" aria-hidden="true" />
        </MenuItem>
      )}
      {!query && ((onChatTab && account) || profiles) && (
        <Submenu
          className="acpmux-quick-item acpmux-quick-sub"
          popupClassName="acpmux-quick-menu"
          label={
            <QuickRowLabel
              label={t("picker.account")}
              value={onChatTab ? accountValue : profiles?.find((choice) => choice.id === profile)?.name}
            />
          }
        >
          {profiles && (
            <MenuRadioGroup
              value={profile ?? ""}
              onValueChange={(id) => {
                if (id === profile) return;
                onOpenChange(false);
                families?.onAccount?.(id);
              }}
            >
              {profiles.map((choice) => (
                <MenuRadioItem
                  key={choice.id}
                  value={choice.id}
                  closeOnClick
                  disabled={choice.disabled}
                  className="acpmux-quick-item acpmux-quick-profile"
                >
                  <span className="acpmux-menu-label">{choice.name}</span>
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          )}
          {profiles && onChatTab && account && <MenuSeparator />}
          {onChatTab && account && (
            <AccountRows
              list={accounts.list}
              failed={accounts.failed}
              switchFailed={accounts.switchFailed}
              onPick={(routeId) => {
                onOpenChange(false);
                accounts.pick(routeId);
              }}
            />
          )}
        </Submenu>
      )}
      {!query && onChatTab && fast && (
        <>
          <MenuSeparator />
          <MenuCheckboxItem
            className="acpmux-quick-item acpmux-quick-fast"
            checked={fast.checked}
            onCheckedChange={(on) => fast.onChange(on)}
          >
            <span className="acpmux-menu-label">{t("picker.fastMode")}</span>
            {/* Its state in words at the trailing edge, as Effort and Account name theirs (Leo
                2026-10-21): Off in secondary ink, On in the theme accent. */}
            <span className="acpmux-quick-value">{t(fast.checked ? "picker.on" : "picker.off")}</span>
          </MenuCheckboxItem>
        </>
      )}
    </>
  );
  return (
    <Menu open={open} onOpenChange={onOpenChange}>
      <MenuButton className="acpmux-picker-button" aria-haspopup="menu" buttonRef={trigger} {...chip}>
        {children}
      </MenuButton>
      <MenuPopup
        side={newTab ? "bottom" : "top"}
        align="start"
        label={t("picker.model")}
        className={`acpmux-quick-menu${families ? " acpmux-quick-railed" : ""}${newTab ? " acpmux-quick-newtab" : ""}`}
        boundary={CHAT_COLUMN}
        // New Tab's rows never go to the native panel: it would drop the rail and the More models
        // scroll area (a tab with no Effort or Account submenu counts as flat, popupHost.ts). The
        // menu's max height keeps it in the window instead (modelPicker.css).
        escapes={!newTab}
        // ui-allow: 1 to 9 pick a row in place and typing filters the list, as in Claude Code's model menu.
        onKeyDown={keyDown}
      >
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
            {/* The rail: Starred (when any), then each harness; a tab shows its models in place. */}
            <fieldset className="acpmux-quick-rail" aria-label={t("picker.harness")}>
              {families.list.map((family) => (
                <button
                  key={family.id}
                  type="button"
                  aria-label={family.name}
                  aria-pressed={family.id === tab}
                  // tooltip-allow: the rail tab draws only a meaningful harness mark, never a
                  // machine/session initial; its accessible name and title identify the harness.
                  title={family.note ? `${family.name} · ${family.note}` : family.name}
                  className="acpmux-quick-rail-tab"
                  // ui-allow: the rail is no row of the menu; ArrowLeft and ArrowRight move along it, so Up and Down stay in the list.
                  tabIndex={-1}
                  onClick={() => {
                    setTab(family.id);
                    setQuery("");
                    toTop();
                  }}
                >
                  {family.starred ? (
                    <StarIcon />
                  ) : family.mark ? (
                    <AgentMark agent={family.mark} size={16} />
                  ) : (
                    <AgentMark agent={undefined} size={16} reserve />
                  )}
                </button>
              ))}
            </fieldset>
            <div className="acpmux-quick-body" ref={body}>
              <div className="acpmux-quick-list">{list}</div>
              <QuickMenuSpacer {...tallest} widths={widths} holdHeight={!newTab} />
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
function StarIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M8 1.8l1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z"
        fill="none"
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
/// is disabled: unbinding the chat would leave it on that route. With no routes it says how to add
/// one; a switch acpmux refused says so first.
function AccountRows({
  list,
  failed,
  switchFailed,
  onPick,
}: {
  list?: ChatAccountList;
  failed: boolean;
  switchFailed: boolean;
  onPick(routeId: string | null): void;
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
  // The session-scoped list has already removed other harness families. Proxies and routers are
  // transports, not more logins; keep the current binding so the checked row remains truthful.
  const choices = list.accounts.filter(
    (choice) => choice.kind === "direct-subscription" || choice.kind === "direct-api-key" || choice.id === list.active,
  );
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
        {choices.map((choice) => (
          <MenuRadioItem key={choice.id} value={choice.id} closeOnClick className="acpmux-quick-item">
            <span className="acpmux-menu-label">{choice.name}</span>
          </MenuRadioItem>
        ))}
      </MenuRadioGroup>
      {choices.length === 0 && (
        <MenuItem disabled className="acpmux-quick-item acpmux-quick-note">
          {t("picker.accountHint")}
        </MenuItem>
      )}
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
