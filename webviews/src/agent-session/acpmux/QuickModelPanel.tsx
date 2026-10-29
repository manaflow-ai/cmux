import { authText, canSessionLogin } from "./sessionAuth";
import React, { Fragment, useContext, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { AgentMark, hasAgentMark } from "../shared/AgentMark";
import type { ChatAccountList } from "./chatAccounts";
import { isModelRouterKind } from "./routerKinds";
import { SearchIcon } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
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

import type { QuickMenu, QuickModel } from "./QuickModelMenu";

/// How many models (the tab's rows and More models) make a list long enough for the `long`
/// version's search field.
const LONG_LIST = 8;

/// Keys 1 to 9 pick a tab's first rows; this does not limit the visible model list.
const FILTER_ROWS = 9;
const EFFORT_SLIDER_KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);

const rowValue = (model: Pick<QuickModel, "family" | "id">) => `${model.family}\u0000${model.id}`;
/// The running model's row when several providers serve it: the running offer may be another
/// provider's than the row lands, when the running one is unavailable.
const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);

/// The Prototype look's model menu (composerLook.ts `prototype`, Lucas 2026-10-29): a short root menu
/// (Model, Effort, Provider, Fast mode) whose Model row opens a panel beside it: an icon rail
/// (Starred, then each harness), the search field and the models, More models in place. Every other
/// look draws QuickModelMenu.tsx.
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
  const { models, current, effort, account, auth, fast } = menu;
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
  const [scrolled, setScrolled] = useState(false);
  const [panelOpen, setPanelOpen] = useState(false);
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
  // Typing can unmount the focused row (Effort, Account, a model it filters out); keyboard focus
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
  }, [open, tab, panelOpen]);
  const toTop = () => {
    if (bodyRef.current) bodyRef.current.scrollTop = 0;
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
    // The panel's keys are its own: while it is closed (or closing) nothing pulls focus into it.
    if (!open || !panelOpen || !node || !(families || search)) {
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
  }, [query, open, families, search, showField, tab, moreFor, panelOpen]);
  const forkTab = !query && shown?.fork ? shown : undefined;
  // The Model panel is a submenu already: More models shows its models in place, never a third level.
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
        // In the Model panel, ArrowLeft would close the submenu: the rail keeps it.
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
  // The Model panel's list: a fork offer, the search's matches, or the tab's top models with More
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
                <QuickModelLabel
                  model={oneProvider ? { name: choice.name, ...(choice.tag ? { tag: choice.tag } : {}) } : choice}
                />
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
      {!families && (
        <MenuItem className="acpmux-quick-item acpmux-quick-sub" onSelect={() => onMore()}>
          <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
          <span className="ui-submenu-chevron" aria-hidden="true" />
        </MenuItem>
      )}
    </>
  );
  // The root rows set the chat's own harness: Effort, Provider, the account, its sign-in, Fast mode.
  const effortRow = effort && levels.length > 1 && (
    <Submenu
      key="effort"
      className="acpmux-quick-item acpmux-quick-sub"
      popupClassName="acpmux-quick-menu acpmux-quick-proto"
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
  );
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
        <MenuSeparator key="auth-sep" />,
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
        <MenuSeparator key="fast-sep" />,
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
  const runningName = [...(chatFamily?.models ?? []), ...(chatFamily?.more ?? []), ...(families ? [] : models)].find(
    (model) => model.id === current || runsOffers(model, current),
  )?.name;
  // The Model row (Lucas 2026-10-29): its panel opens beside the menu, an icon rail (Starred, then
  // each harness), search and the models, at a fixed height so a short tab never hides the rail.
  const modelRow = (
    <Submenu
      key="model"
      className="acpmux-quick-item acpmux-quick-sub"
      popupClassName={`acpmux-quick-menu acpmux-quick-proto acpmux-quick-panel${families ? " acpmux-quick-railed" : ""}`}
      onPopupKeyDown={keyDown}
      // Starts at its row (Lucas 2026-10-29: never above "Model"), never slid along the window to
      // fit: it grows away from the row and takes the room there.
      pinned
      // Opens on a click, Enter or the arrow only: a pointer passing over it on its way to Fast mode
      // opens nothing, so Base UI's hover safe area never blocks the rows next to it.
      openOnHover={false}
      // The rail's first tile is one space step in from the panel's top: it lines up with this row.
      firstRowInset={4}
      onOpenChange={(next) => {
        setPanelOpen(next);
        if (!next) return;
        setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
        setQuery("");
        setMoreFor(undefined);
        setScrolled(false);
        requestAnimationFrame(() => field.current?.focus({ preventScroll: true }));
      }}
      label={
        <>
          <span className="acpmux-menu-label">{t("picker.model")}</span>
          <span className="acpmux-quick-value acpmux-quick-model-value">
            {chatFamily?.mark && hasAgentMark(chatFamily.mark) && <AgentMark agent={chatFamily.mark} size={14} />}
            {runningName}
          </span>
        </>
      }
    >
      {families ? (
        <div className="acpmux-quick-layout">
          <fieldset ref={rail} className="acpmux-quick-rail" aria-label={t("picker.harness")}>
            {families.list.map((family) => (
              <button
                key={family.id}
                type="button"
                aria-label={family.name}
                aria-pressed={family.id === tab}
                disabled={family.launch && families.forkReady === false}
                // tooltip-allow: the rail draws only the harness mark; its title names the harness.
                title={family.note ? `${family.name} · ${family.note}` : family.name}
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
                  <StarIcon />
                ) : family.mark && hasAgentMark(family.mark) && harnessIcon(family.mark)?.kind !== "monogram" ? (
                  <AgentMark agent={family.mark} size={18} />
                ) : (
                  <span className="acpmux-quick-rail-initial" aria-hidden="true">
                    {family.name.slice(0, 1)}
                  </span>
                )}
                <span className="acpmux-quick-harness-name sr-only">{family.name}</span>
              </button>
            ))}
          </fieldset>
          <div className="acpmux-quick-column">
            {searchField}
            {body}
          </div>
        </div>
      ) : (
        <>
          {searchField}
          {modelPart}
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
    </Submenu>
  );
  const rootKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.nativeEvent.isComposing || event.keyCode === 229)
      return;
    // Only the root's own keys, not the panel's (React carries those up through the portal).
    if (!event.currentTarget.contains(event.target as Node)) return;
    if (/^[1-9]$/.test(event.key)) {
      const choice = rows[Number(event.key) - 1];
      if (!choice) return;
      event.preventDefault();
      pickRow(choice);
    } else if (!families && event.key.length === 1 && /\S/.test(event.key)) {
      event.preventDefault();
      onOpenChange(false);
      onMore(event.key);
    }
  };
  // Read from the chip: Model first, then what sets it. A menu that opens up reverses the order, so
  // Model stays next to the chip.
  const rootRows = [modelRow, effortRow, offersRow, accountRow, ...authRows, ...fastRows].filter(Boolean);
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
        className={`acpmux-quick-menu acpmux-quick-proto acpmux-quick-root${newTab ? " acpmux-quick-newtab" : ""}`}
        boundary={CHAT_COLUMN}
        // A native menu panel cannot draw the Model panel's rail or its scroll area.
        escapes={!families}
        // ui-allow: 1 to 9 pick the running harness's rows from the root too; typing in a chat with
        // no rail opens the full picker, as the compact menu does.
        onKeyDown={rootKeyDown}
      >
        {side === "top" ? [...rootRows].reverse() : rootRows}
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
