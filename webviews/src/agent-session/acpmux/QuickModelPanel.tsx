import { authText, canSessionLogin } from "./sessionAuth";
import React, { Fragment, useContext, useId, useLayoutEffect, useRef, useState } from "react";
import { AgentMark, hasAgentMark } from "../shared/AgentMark";
import { SearchIcon } from "./ComposerPickers";
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

import { AccountRows, useAccountList, type QuickFamily, type QuickMenu, type QuickModel } from "./QuickModelMenu";

/// How many models (the tab's rows and More models) make a list long enough for the `long`
/// version's search field.
const LONG_LIST = 8;

/// Keys 1 to 9 pick a tab's first rows; this does not limit the visible model list.
const FILTER_ROWS = 9;

const rowValue = (model: Pick<QuickModel, "family" | "id">) => `${model.family}\u0000${model.id}`;
/// The running model's row when several providers serve it: the running offer may be another
/// provider's than the row lands, when the running one is unavailable.
const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);

/// Claude's and Codex's tabs show four models, as T3 Code's do (Lucas 2026-10-30: "show a little less
/// of the chatgpt models"); the rest wait under More models. The running model stays among the four.
/// A router harness (OpenCode) keeps its whole list: its open models fill the room (Lucas 2026-10-29).
const FIRST_PARTY_ROWS = 4;
function firstPartyTop(
  family: QuickFamily | undefined,
  chatHarness: string | undefined,
  current: string | undefined,
): QuickFamily | undefined {
  if (!family || family.starred || (family.mark !== "claude" && family.mark !== "codex")) return family;
  const all = [...family.models, ...family.more];
  // The running model, wherever the tab lists it: an older one waits under More models otherwise.
  const running =
    family.id === chatHarness ? all.find((model) => model.id === current || runsOffers(model, current)) : undefined;
  let top = family.models.slice(0, FIRST_PARTY_ROWS);
  if (running && !top.includes(running)) top = [...top.slice(0, FIRST_PARTY_ROWS - 1), running];
  if (top.length === family.models.length && top.every((model, index) => model === family.models[index])) return family;
  return { ...family, models: top, more: all.filter((model) => !top.includes(model)) };
}

/// The Prototype look's model menu (composerLook.ts `prototype`): the chip opens the model panel
/// itself, as T3 Code's does (Lucas 2026-10-30): an icon rail (Starred, then each harness), the
/// search field and the models, More models in place. Under the list, a short footer sets the chat's
/// Provider and account and names its sign-in. Effort and Fast mode are the effort chip's
/// (EffortPicker, ComposerPickers.tsx); the menu draws Fast mode only when the composer passes it
/// (a model with no levels has no effort chip). Every other look draws QuickModelMenu.tsx.
export function QuickModelPanelMenu({
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
  // Choose once for the compact menu's possible height; shorter tabs then stay by the same edge
  // of the chip. This is only a side decision: the surface still fits its visible content.
  const { open: sideOpen, setOpen: setSideOpen, side } = useOpenSide(trigger, newTab ? "bottom" : "top", 320);
  if (sideOpen !== open) setSideOpen(open);
  const { models, current, account, auth, fast } = menu;
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
  const [scrolled, setScrolled] = useState(false);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
      setQuery("");
      setMoreFor(undefined);
      setScrolled(false);
    }
  }
  // Typing can unmount the focused row (a footer row, a model it filters out); keyboard focus
  // goes to the first row left, so the next key, Enter and Escape still reach the menu. A
  // re-render with the same filter (a streaming reply hands over new families) keeps the row the
  // keyboard moved to, so Enter picks it.
  // With a search field the keyboard sits in it from the moment the menu opens, and a key typed
  // on a row goes back to it.
  const popup = useRef<HTMLDivElement | null>(null);
  // A changed tab or filter starts with its first model in view.
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const rail = useRef<HTMLFieldSetElement | null>(null);
  useLayoutEffect(() => {
    const selected = rail.current?.querySelector<HTMLElement>('[aria-pressed="true"]');
    selected?.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  }, [open, tab]);
  const toTop = () => {
    if (bodyRef.current) bodyRef.current.scrollTop = 0;
    setScrolled(false);
  };
  const focusedFor = useRef<string | undefined>(undefined);
  const search = menu.search;
  const field = useRef<HTMLInputElement | null>(null);
  const shown = firstPartyTop(
    families?.list.find((family) => family.id === tab),
    families?.current,
    current,
  );
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
  const forkTab = !query && shown?.fork ? shown : undefined;
  // More models shows its models in place, never a submenu.
  const inlineMore = families !== undefined;
  const moreShown = inlineMore && !query && moreFor !== undefined && moreFor === tab;
  // What the list draws: the search's matches, else the tab's top models.
  const rows: QuickModel[] =
    query && search
      ? search.find(query)
      : !families
        ? models.map((model) => ({ ...model, family: "" }))
        : (shown?.models ?? []);
  const providerLook = menu.providers ?? "row";
  // The running model's row when several providers serve it: the Provider row switches among them.
  const chatFamily = families?.list.find((family) => family.id === families.current);
  const runningRow = (families ? chatFamily?.models : models)?.find((model) => runsOffers(model, current));
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
    if (event.nativeEvent.isComposing || event.keyCode === 229) {
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
  const routeRows = account && (
    <AccountRows
      list={accounts.list}
      failed={accounts.failed}
      switchFailed={accounts.switchFailed}
      grouped={menu.routeLayout === "grouped"}
      onPick={(routeId) => {
        onOpenChange(false);
        accounts.pick(routeId);
      }}
    />
  );
  const keyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.nativeEvent.isComposing || event.keyCode === 229)
      return;
    // Only the menu's own keys, not a submenu's (React carries those up through the portal).
    if (!event.currentTarget.contains(event.target as Node)) return;
    popup.current = event.currentTarget;
    // Left and Right move along the rail (its tabs are not rows, so Up and Down stay in the list).
    // In the search field they move along the rail only while it is empty (fieldKeyDown).
    if (families && !query && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      const tabs = families.list.filter((family) => !family.launch || families.forkReady !== false);
      const at = tabs.findIndex((family) => family.id === tab);
      const next = tabs[(at + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length];
      if (next) {
        event.preventDefault();
        // Base UI's own Left and Right (a submenu's) never see them: the rail keeps them.
        (event as unknown as { preventBaseUIHandler?: () => void }).preventBaseUIHandler?.();
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
  const tabRows = query ? rows : [...rows, ...(shown?.more ?? [])];
  const oneProvider = tabRows.length > 1 && tabRows.every((row) => row.provider === tabRows[0]!.provider);
  // The harness each row belongs to, for its second line: a Starred row names its own.
  const owners = new Map<string, QuickFamily>();
  for (const family of families?.list ?? []) {
    if (family.starred) continue;
    owners.set(family.id, family);
    for (const variant of family.variants ?? [])
      owners.set(variant.id, { ...variant, mark: variant.mark ?? family.mark });
  }
  /// A model row, as T3 Code's (Leo on #27849, Lucas 2026-10-30): the name, under it the harness's
  /// mark and name (or the provider it lands, or a searched row's hint) in secondary text, then its
  /// number key and a star that adds it to Starred.
  const modelRow = (choice: QuickModel, key?: number) => {
    const owner = owners.get(choice.family) ?? (shown && !shown.starred ? shown : undefined);
    const sub = choice.hint ?? choice.provider ?? owner?.name ?? choice.harness;
    const starred = menu.favorites?.has(choice.id) ?? false;
    // The star's press is its own: the row under it never sees it, so it neither picks nor closes.
    const own = (event: React.SyntheticEvent) => event.stopPropagation();
    return (
      <MenuRadioItem
        key={valueOf(choice)}
        value={valueOf(choice)}
        closeOnClick
        disabled={choice.disabled}
        className="acpmux-quick-item acpmux-quick-two"
        // tooltip-allow: a long model name ends in "…" at the menu's width; the tooltip names it whole.
        title={sub ? `${choice.name} · ${sub}` : choice.name}
      >
        <span className="acpmux-quick-two-text">
          <span className="acpmux-quick-label">
            <span className="acpmux-menu-label">{choice.name}</span>
            {choice.tag && <span className="acpmux-quick-tag">{choice.tag}</span>}
          </span>
          {sub && (
            <span className="acpmux-quick-two-sub">
              {owner?.mark && hasAgentMark(owner.mark) && <AgentMark agent={owner.mark} size={12} />}
              <span className="acpmux-menu-label">{sub}</span>
            </span>
          )}
        </span>
        {/* The running row's check takes its number's place, so the keys form one column. */}
        {key !== undefined && valueOf(choice) !== currentValue && <kbd className="acpmux-quick-key">{key}</kbd>}
        {menu.favorites && (
          // ui-allow: the star is a control inside the row, as the full picker's is; the keyboard stars in the full picker.
          <button
            type="button"
            tabIndex={-1}
            className="acpmux-quick-star"
            aria-label={t(starred ? "picker.unstar" : "picker.star")}
            aria-pressed={starred}
            data-on={starred ? "" : undefined}
            onPointerDown={own}
            onPointerUp={own}
            onMouseDown={own}
            onMouseUp={own}
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              menu.favorites?.toggle(choice.id);
            }}
          >
            <StarIcon filled={starred} size={13} />
          </button>
        )}
      </MenuRadioItem>
    );
  };
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
          // A tab whose rows share one provider names none: it would repeat on every row.
          const detail = choice.hint ?? (oneProvider ? undefined : choice.provider);
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
                popupClassName="acpmux-quick-menu acpmux-quick-proto"
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
          return modelRow(choice, !query && index < FILTER_ROWS ? index + 1 : undefined);
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
  // The panel's list: a fork offer, the search's matches, or the tab's top models with More
  // models in place.
  const modelPart = forkTab ? (
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
            {shown.more.map((choice) => modelRow(choice))}
          </MenuRadioGroup>
        </fieldset>
      )}
      {/* A harness's other launch configurations (a second account's profile): start or fork to one. */}
      {shown?.variants && shown.variants.length > 0 && (
        <MenuGroup label={shown.name}>
          {shown.variants.map((variant) => (
            <MenuItem
              key={variant.id}
              className="acpmux-quick-item acpmux-quick-variant"
              disabled={families?.forkReady === false}
              closeOnClick
              onSelect={() => {
                if (variant.logIn) variant.logIn();
                else families?.onLaunch?.(variant.id);
              }}
            >
              <span className="acpmux-menu-label">
                {families?.onFork ? t("picker.forkTo", { harness: variant.name }) : variant.name}
              </span>
            </MenuItem>
          ))}
        </MenuGroup>
      )}
      {inlineMore && families.onAddHarness && (moreShown || !shown?.more.length) && (
        <MenuItem className="acpmux-quick-item" onSelect={() => families.onAddHarness?.()}>
          <span className="acpmux-menu-label">{t("modelPicker.addHarness")}</span>
        </MenuItem>
      )}
      {!families && (
        <MenuItem className="acpmux-quick-item acpmux-quick-sub" onSelect={() => onMore()}>
          <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
          <span className="ui-submenu-chevron" aria-hidden="true" />
        </MenuItem>
      )}
    </>
  );
  // The footer's rows set the chat's own harness: Provider, the account, its sign-in, and Fast mode
  // when the composer draws no effort chip.
  const offersRow = runningRow?.offers && providerLook === "row" && (
    <Submenu
      key="offers"
      className="acpmux-quick-item acpmux-quick-sub"
      popupClassName="acpmux-quick-menu acpmux-quick-proto"
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
  );
  const accountRow =
    account &&
    (menu.routeLayout === "inline" ? (
      <MenuGroup key="account" label={t("picker.provider")}>
        {routeRows}
      </MenuGroup>
    ) : (
      <Submenu
        key="account"
        className="acpmux-quick-item acpmux-quick-sub"
        popupClassName="acpmux-quick-menu acpmux-quick-proto"
        label={<QuickRowLabel label={t("picker.provider")} value={accountValue} />}
      >
        {routeRows}
      </Submenu>
    ));
  const authNote = auth && authText(auth.verdict, t);
  const authRows = authNote
    ? [
        <MenuItem key="auth" disabled className="acpmux-quick-item acpmux-quick-note">
          <span className="acpmux-menu-label">{authNote}</span>
        </MenuItem>,
        ...(canSessionLogin(auth.verdict) && auth.onLogin
          ? [
              <MenuItem key="auth-login" className="acpmux-quick-item" onSelect={() => auth.onLogin?.()}>
                <span className="acpmux-menu-label">{t("harness.logIn")}</span>
              </MenuItem>,
            ]
          : []),
        ...(auth.onRefresh
          ? [
              <MenuItem key="auth-refresh" className="acpmux-quick-item" onSelect={() => auth.onRefresh?.()}>
                <span className="acpmux-menu-label">{t("harnesses.checkAgain")}</span>
              </MenuItem>,
            ]
          : []),
      ]
    : [];
  const fastRows = fast
    ? [
        <MenuCheckboxItem
          key="fast"
          className="acpmux-quick-item acpmux-quick-fast"
          checked={fast.checked}
          onCheckedChange={(on) => fast.onChange(on)}
        >
          <span className="acpmux-menu-label">{t("picker.fastMode")}</span>
          <span className="acpmux-quick-fast-toggle" aria-hidden="true">
            <span />
          </span>
        </MenuCheckboxItem>,
      ]
    : [];
  const footRows = [offersRow, accountRow, ...authRows, ...fastRows].filter(Boolean);
  const foot = footRows.length > 0 && (
    <div className="acpmux-quick-foot">
      <MenuSeparator />
      {footRows}
    </div>
  );
  const searchField = showField && (
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
  );
  const body = (
    <div
      className="acpmux-quick-body"
      ref={bodyRef}
      data-scrolled={scrolled ? "" : undefined}
      onScroll={(event) => setScrolled(event.currentTarget.scrollTop > 0)}
    >
      <div className="acpmux-quick-list">{modelPart}</div>
    </div>
  );
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
        className={`acpmux-quick-menu acpmux-quick-proto acpmux-quick-panel${families ? " acpmux-quick-railed" : ""}${newTab ? " acpmux-quick-newtab" : ""}`}
        boundary={CHAT_COLUMN}
        // A native menu panel cannot draw the rail or its scroll area.
        escapes={!families}
        // ui-allow: the panel's own keys: 1 to 9 pick its rows, typing filters, Left and Right move along the rail.
        onKeyDown={keyDown}
      >
        {families ? (
          <div className="acpmux-quick-layout">
            <fieldset ref={rail} className="acpmux-quick-rail" aria-label={t("picker.harness")}>
              {families.list.map((family) => (
                <Fragment key={family.id}>
                  <button
                    type="button"
                    aria-label={family.name}
                    aria-pressed={family.id === tab}
                    disabled={family.launch && families.forkReady === false}
                    // tooltip-allow: the rail draws only the harness mark; its title names the harness.
                    title={family.note && !family.starred ? `${family.name} · ${family.note}` : family.name}
                    className="acpmux-quick-rail-tab"
                    // ui-allow: the rail is no row of the menu; ArrowLeft and ArrowRight move along it, so Up and Down stay in the list.
                    tabIndex={-1}
                    onClick={() => {
                      if (family.launch && !family.note) {
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
                      <StarIcon filled size={16} />
                    ) : family.mark && hasAgentMark(family.mark) && harnessIcon(family.mark)?.kind !== "monogram" ? (
                      <AgentMark agent={family.mark} size={18} />
                    ) : (
                      <span className="acpmux-quick-rail-initial" aria-hidden="true">
                        {family.name.slice(0, 1)}
                      </span>
                    )}
                    <span className="acpmux-quick-harness-name sr-only">{family.name}</span>
                  </button>
                  {/* Starred stands apart from the harnesses, as T3 Code's rail does. */}
                  {family.starred && <span className="acpmux-quick-rail-rule" aria-hidden="true" />}
                </Fragment>
              ))}
            </fieldset>
            <div className="acpmux-quick-column">
              {searchField}
              {body}
              {foot}
            </div>
          </div>
        ) : (
          <>
            {searchField}
            {modelPart}
            {foot}
          </>
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

/// The rail's Starred tab (an outline star), and a row's star (filled once starred).
function StarIcon({ filled = false, size = 15 }: { filled?: boolean; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
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
function QuickRowLabel({ label, value }: { label: string; value?: string }) {
  return (
    <>
      <span className="acpmux-menu-label">{label}</span>
      {value && <span className="acpmux-quick-value">{value}</span>}
    </>
  );
}
