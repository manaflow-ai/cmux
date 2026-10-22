import React, { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import { AgentMark } from "../shared/AgentMark";
import type { ChatAccountList, ChatAccounts } from "./chatAccounts";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { CHAT_COLUMN } from "./modelPickerLayout";
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
  models: readonly { id: string; name: string }[];
  current?: string;
  onModel(id: string): void;
  /// The reasoning levels; absent when the model offers no choice.
  effort?: { levels: Choice[]; current?: string; onPick(value: string): void };
  /// The chat's accounts (acpmux routes); absent for a chat with no session yet or off this Mac.
  account?: { sessionId: string; accounts: ChatAccounts };
  /// Fast mode (Claude Code's Fast Mode): the menu's last checkbox row, its one place. Absent where
  /// the running model has none, and for Codex, whose bolt left of the mic is its control
  /// (FastToggle.tsx, Leo 2026-10-21).
  fast?: { checked: boolean; onChange(on: boolean): void };
  /// The rail beside the list: Starred (when any), then each harness. Without it the menu lists
  /// `models` alone and More models opens the full picker.
  families?: QuickFamilies;
  /// The chat's agent CLI has an update (hq#2569 #12): the last row starts it.
  update?: { text: string; run(): void };
};

/// A model row of any harness: `family` is the rail tab (harness) it belongs to.
export type QuickModel = { id: string; name: string; family: string; disabled?: boolean };

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
};

export type QuickFamilies = {
  list: QuickFamily[];
  /// The chat's harness: its tab opens first, and only it shows Effort and Account.
  current?: string;
  onPick(model: QuickModel): void;
  /// Add harness…, the last row of More models.
  onAddHarness?(): void;
};

/// How many rows a filtered list shows (keys 1 to 9 pick them).
const FILTER_ROWS = 9;

/// The models whose name, or whose harness's name, holds every typed word. Starred repeats other
/// tabs' models, so it is not searched.
function filtered(families: QuickFamily[], query: string): (QuickModel & { hint: string })[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const rows: (QuickModel & { hint: string })[] = [];
  for (const family of families) {
    if (family.starred || family.note) continue;
    for (const model of [...family.models, ...family.more]) {
      const text = `${model.name} ${family.name}`.toLowerCase();
      if (words.every((word) => text.includes(word))) rows.push({ ...model, hint: family.name });
    }
  }
  return rows.slice(0, FILTER_ROWS);
}

const rowValue = (model: Pick<QuickModel, "family" | "id">) => `${model.family}\u0000${model.id}`;

/// What one rail tab's unfiltered list draws, in rows and separators (the group label is in every
/// tab). The menu opens above its chip, so a taller or shorter tab moved the rail under the pointer;
/// the list keeps the tallest tab's height for the whole opening (QuickMenuSpacer).
export type TabExtent = { rows: number; separators: number };

/// Mirrors the unfiltered `list` in QuickModelMenu row for row: keep the two in step.
export function tabExtent(
  family: QuickFamily,
  menu: Pick<QuickMenu, "account" | "fast" | "update"> & { families: QuickFamilies; levels: number },
): TabExtent {
  const chat = family.id === menu.families.current;
  const models = Math.min(family.models.length, FILTER_ROWS);
  let rows = models || 1;
  let separators = 1;
  if (family.note && family.logIn) rows += 1;
  if (chat && menu.levels > 1) {
    rows += 1;
    separators += 1;
  }
  if (family.more.length > 0 || menu.families.onAddHarness) rows += 1;
  if (chat && menu.account) rows += 1;
  if (chat && menu.fast) {
    rows += 1;
    separators += 1;
  }
  if (menu.update) {
    rows += 1;
    separators += 1;
  }
  return { rows, separators };
}

/// One row of any tab, for the width probe: its label, its secondary value, and whether it opens a
/// submenu (a chevron) or shows a number key.
export type ProbeRow = { label: string; value?: string; sub?: boolean; shortcut?: boolean };

/// The tallest tab's rows and separators, unseen in the list's grid cell under the real rows, so
/// switching tabs or typing never changes the menu's height while it is open. `widths` is every
/// tab's rows at no height: the cell is as wide as the widest tab, so its width holds too.
function QuickMenuSpacer({ rows, separators, widths }: TabExtent & { widths: ProbeRow[] }) {
  return (
    <div className="acpmux-quick-spacer" aria-hidden="true" inert>
      <div className="acpmux-quick-probe">
        {widths.map((row, index) => (
          <div key={index} className={`ui-menu-item acpmux-quick-item${row.sub ? " acpmux-quick-sub" : ""}`}>
            <span className="acpmux-menu-label">{row.label}</span>
            {row.value && <span className="acpmux-quick-value">{row.value}</span>}
            {row.sub && <span className="ui-submenu-chevron" />}
            {row.shortcut && <span className="ui-menu-shortcut">9</span>}
          </div>
        ))}
      </div>
      <div className="ui-menu-group-label">{"\u00a0"}</div>
      {/* A separator after each of the first rows: back to back, their margins would collapse. */}
      {Array.from({ length: rows }, (_, index) => (
        <Fragment key={index}>
          <div className="ui-menu-item acpmux-quick-item" />
          {index < separators && <div className="ui-separator" />}
        </Fragment>
      ))}
    </div>
  );
}

/// What the composer hands the model picker for its compact menu; the picker adds the models.
export type QuickMenuExtras = Pick<QuickMenu, "effort" | "account" | "fast">;

/// The Claude Code style model menu (Leo 2026-10-18): a short rounded menu headed "Model · this
/// session". Keys 1 to 9 pick a model in place, its check sits at the row's trailing edge, Effort
/// and Account open beside their rows, and More models opens the full picker (the harness rail and
/// search). Typing a letter opens that picker searching for it. Fast mode is the last row, a
/// checkbox (Leo 2026-10-20), never a radio group inside Effort.
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
  const { models, current, effort, account, fast } = menu;
  const levels = effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? [];
  const level = levels.find((choice) => choice.id === effort?.current);
  const accounts = useAccountList(open, account);
  const families = menu.families;
  // The rail's tab and the typed filter start over with each opening.
  const [tab, setTab] = useState(families?.current);
  const [query, setQuery] = useState("");
  // Reset as the menu opens, in render: the composer re-renders while it is open (a streaming
  // reply), and an effect on the families would throw away the tab and the typed filter.
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
      setQuery("");
    }
  }
  // Typing can unmount the focused row (Effort, Account, a model it filters out); keyboard focus
  // goes to the first row left, so the next key, Enter and Escape still reach the menu. A
  // re-render with the same filter (a streaming reply hands over new families) keeps the row the
  // keyboard moved to, so Enter picks it.
  const popup = useRef<HTMLDivElement | null>(null);
  // Another tab or filter starts at its top: the held height keeps a tall tab's scroll range, which
  // could leave a short tab's rows above the view.
  const body = useRef<HTMLDivElement | null>(null);
  const toTop = () => {
    if (body.current) body.current.scrollTop = 0;
  };
  const focusedFor = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    const node = popup.current;
    if (!open || !node || !families) {
      focusedFor.current = undefined;
      return;
    }
    const active = node.ownerDocument.activeElement;
    const typed = query !== focusedFor.current;
    focusedFor.current = query;
    if ((query && typed) || !node.contains(active)) {
      const first = node.querySelector<HTMLElement>('.acpmux-quick-body [role^="menuitem"]:not([data-disabled])');
      (first ?? node).focus({ preventScroll: true });
    }
  }, [query, open, families]);
  const shown = families?.list.find((family) => family.id === tab);
  const onChatTab = !families || tab === families.current;
  // What the list draws: the typed filter's matches, else the tab's top models.
  const rows: (QuickModel & { hint?: string })[] = !families
    ? models.map((model) => ({ ...model, family: "" }))
    : query
      ? filtered(families.list, query)
      : (shown?.models.slice(0, FILTER_ROWS) ?? []);
  const pickRow = (row: QuickModel) => {
    if (row.disabled) return;
    onOpenChange(false);
    if (!families) {
      if (row.id !== current) menu.onModel(row.id);
    } else if (!(row.family === families.current && row.id === current)) families.onPick(row);
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
    if (/^[1-9]$/.test(event.key) && !(families && query)) {
      const choice = rows[Number(event.key) - 1];
      if (!choice) return;
      event.preventDefault();
      pickRow(choice);
    } else if (families && event.key === "Backspace" && query) {
      event.preventDefault();
      setQuery(query.slice(0, -1));
      toTop();
    } else if (event.key.length === 1 && (/\S/.test(event.key) || (families && query))) {
      event.preventDefault();
      // Typing filters the list in place, Claude Code style; without a rail it searches the full picker.
      if (families) {
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
        update: menu.update,
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
          ...family.models.slice(0, FILTER_ROWS).map((model) => ({ label: model.name, shortcut: true })),
          ...(family.note && family.models.length === 0 ? [{ label: family.note }] : []),
          ...(family.note && family.logIn ? [{ label: t("harness.logIn") }] : []),
        ]),
        ...(effort && levels.length > 1 ? [{ label: t("effort.title"), value: level?.name, sub: true }] : []),
        { label: t("picker.moreModels"), sub: true },
        ...(account ? [{ label: t("picker.account"), value: accountValue, sub: true }] : []),
        ...(fast ? [{ label: t("picker.fastMode") }] : []),
        ...(menu.update ? [{ label: menu.update.text, value: t("harness.update") }] : []),
      ]
    : [];
  const currentValue = families ? rowValue({ family: families.current ?? "", id: current ?? "" }) : (current ?? "");
  const list = (
    <>
      <MenuGroup label={query ? `“${query}”` : t("picker.modelThisSession")}>
        <MenuRadioGroup
          value={currentValue}
          onValueChange={(value) => {
            const row = rows.find((choice) => (families ? rowValue(choice) : choice.id) === value);
            if (row) pickRow(row);
          }}
        >
          {rows.map((choice, index) => {
            const value = families ? rowValue(choice) : choice.id;
            return (
              <MenuRadioItem
                key={value}
                value={value}
                closeOnClick
                disabled={choice.disabled}
                className="acpmux-quick-item"
                shortcut={!query && index < FILTER_ROWS && value !== currentValue ? String(index + 1) : undefined}
              >
                <span className="acpmux-menu-label">{choice.name}</span>
                {choice.hint && <span className="acpmux-quick-value">{choice.hint}</span>}
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
      </MenuGroup>
      {!query && onChatTab && effort && levels.length > 1 && (
        <>
          <MenuSeparator />
          <Submenu
            className="acpmux-quick-item acpmux-quick-sub"
            popupClassName="acpmux-quick-menu"
            label={<QuickRowLabel label={t("effort.title")} value={level?.name} />}
          >
            <MenuRadioGroup value={effort.current ?? ""} onValueChange={(value) => effort.onPick(value)}>
              {levels.map((choice) => (
                <MenuRadioItem key={choice.id} value={choice.id} closeOnClick className="acpmux-quick-item">
                  <span className="acpmux-menu-label">{choice.name}</span>
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          </Submenu>
        </>
      )}
      {!query && <MenuSeparator />}
      {!query && families && ((shown?.more.length ?? 0) > 0 || families.onAddHarness) && (
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
                    <span className="acpmux-menu-label">{choice.name}</span>
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
      {!query && onChatTab && account && (
        <Submenu
          className="acpmux-quick-item acpmux-quick-sub"
          popupClassName="acpmux-quick-menu"
          label={<QuickRowLabel label={t("picker.account")} value={accountValue} />}
        >
          <AccountRows
            list={accounts.list}
            failed={accounts.failed}
            switchFailed={accounts.switchFailed}
            onPick={(routeId) => {
              onOpenChange(false);
              accounts.pick(routeId);
            }}
          />
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
          </MenuCheckboxItem>
        </>
      )}
      {!query && menu.update && (
        <>
          <MenuSeparator />
          <MenuItem className="acpmux-quick-item acpmux-quick-update" onSelect={() => menu.update?.run()}>
            <span className="acpmux-menu-label min-w-0 flex-1 truncate">{menu.update.text}</span>
            <span className="acpmux-quick-value">{t("harness.update")}</span>
          </MenuItem>
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
        side="bottom"
        align="start"
        label={t("picker.model")}
        className={families ? "acpmux-quick-menu acpmux-quick-railed" : "acpmux-quick-menu"}
        boundary={CHAT_COLUMN}
        // ui-allow: 1 to 9 pick a row in place and typing filters the list, as in Claude Code's model menu.
        onKeyDown={keyDown}
      >
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
                  // tooltip-allow: the rail tab draws only the harness's mark or initial, never its name.
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
                    <span aria-hidden="true" className="acpmux-quick-rail-initial">
                      {family.name.trim().charAt(0).toUpperCase()}
                    </span>
                  )}
                </button>
              ))}
            </fieldset>
            <div className="acpmux-quick-body" ref={body}>
              <div className="acpmux-quick-list">{list}</div>
              <QuickMenuSpacer {...tallest} widths={widths} />
            </div>
          </div>
        ) : (
          list
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
function QuickRowLabel({ label, value }: { label: string; value?: string }) {
  return (
    <>
      <span className="acpmux-menu-label">{label}</span>
      {value && <span className="acpmux-quick-value">{value}</span>}
    </>
  );
}

/// The Account submenu: the harness's own login (the chat's default binding), then each route
/// that serves this chat. A chat bound by its workspace or family checks that route, and CLI login
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
        {list.accounts.map((choice) => (
          <MenuRadioItem key={choice.id} value={choice.id} closeOnClick className="acpmux-quick-item">
            <span className="acpmux-menu-label">{choice.name}</span>
          </MenuRadioItem>
        ))}
      </MenuRadioGroup>
      {list.accounts.length === 0 && (
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
        ? { ...old, ...(routeId ? { active: routeId, scope: "chat" } : { active: undefined, scope: undefined }) }
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
