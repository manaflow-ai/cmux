import React, { useEffect, useState } from "react";
import type { ChatAccountList, ChatAccounts } from "./chatAccounts";
import type { Choice } from "./ComposerPickers";
import type { SpeedSection } from "./EffortPicker";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import {
  Menu,
  MenuButton,
  MenuGroup,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  Submenu,
} from "../../ui/Menu";

/// What the compact model menu lists (the Debug Settings choice `agent.modelMenu`, compact by
/// default): the harness's top models, numbered, then Effort and Account submenus.
export type QuickMenu = {
  /// The numbered rows: this harness's top models, with the running one among them.
  models: readonly { id: string; name: string }[];
  current?: string;
  onModel(id: string): void;
  /// The reasoning levels; absent when the model offers no choice.
  /// `speed`: fast mode or Codex's service tier, as the reasoning menu offers it (the composer row's
  /// bolt leaves a narrow row, so the menu keeps it reachable).
  effort?: { levels: Choice[]; current?: string; onPick(value: string): void; speed?: SpeedSection };
  /// The chat's accounts (acpmux routes); absent for a chat with no session yet or off this Mac.
  account?: { sessionId: string; accounts: ChatAccounts };
};

/// What the composer hands the model picker for its compact menu; the picker adds the models.
export type QuickMenuExtras = Pick<QuickMenu, "effort" | "account">;

/// The Claude Code style model menu (Leo 2026-10-18): a short rounded menu headed "Model · this
/// session". Keys 1 to 9 pick a model in place, its check sits at the row's trailing edge, Effort
/// and Account open beside their rows, and More models opens the full picker (the harness rail and
/// search). Typing a letter opens that picker searching for it.
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
  const { models, current, effort, account } = menu;
  const levels = effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? [];
  const level = levels.find((choice) => choice.id === effort?.current);
  const accounts = useAccountList(open, account);
  const activeAccount = accounts.list?.accounts.find((choice) => choice.id === accounts.list?.active);
  const pick = (id: string) => {
    onOpenChange(false);
    if (id !== current) menu.onModel(id);
  };
  const keyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.nativeEvent.isComposing) return;
    // Only the menu's own keys, not a submenu's (React carries those up through the portal).
    if (!event.currentTarget.contains(event.target as Node)) return;
    if (/^[1-9]$/.test(event.key)) {
      const choice = models[Number(event.key) - 1];
      if (!choice) return;
      event.preventDefault();
      pick(choice.id);
    } else if (event.key.length === 1 && /\S/.test(event.key)) {
      event.preventDefault();
      onOpenChange(false);
      onMore(event.key);
    }
  };
  return (
    <Menu open={open} onOpenChange={onOpenChange}>
      <MenuButton className="acpmux-picker-button" aria-haspopup="menu" buttonRef={trigger} {...chip}>
        {children}
      </MenuButton>
      <MenuPopup side="top" align="start" label={t("picker.model")} className="acpmux-quick-menu" onKeyDown={keyDown}>
        <MenuGroup label={t("picker.modelThisSession")}>
          <MenuRadioGroup value={current ?? ""} onValueChange={pick}>
            {models.map((choice, index) => (
              <MenuRadioItem
                key={choice.id}
                value={choice.id}
                closeOnClick
                className="acpmux-quick-item"
                shortcut={index < 9 && choice.id !== current ? String(index + 1) : undefined}
              >
                <span className="acpmux-menu-label">{choice.name}</span>
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuGroup>
        {(levels.length > 1 || account) && <MenuSeparator />}
        {effort && levels.length > 1 && (
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
            {effort.speed && (
              <>
                <MenuSeparator />
                <MenuGroup label={effort.speed.title}>
                  <MenuRadioGroup
                    value={effort.speed.current ?? ""}
                    onValueChange={(value) => value !== effort.speed?.current && effort.speed?.onPick(value)}
                  >
                    {effort.speed.choices.map((choice) => (
                      <MenuRadioItem key={choice.id} value={choice.id} closeOnClick className="acpmux-quick-item">
                        <span className="acpmux-menu-label">{choice.name}</span>
                      </MenuRadioItem>
                    ))}
                  </MenuRadioGroup>
                </MenuGroup>
              </>
            )}
          </Submenu>
        )}
        {account && (
          <Submenu
            className="acpmux-quick-item acpmux-quick-sub"
            popupClassName="acpmux-quick-menu"
            label={
              <QuickRowLabel
                label={t("picker.account")}
                value={
                  accounts.switchFailed
                    ? t("picker.accountSwitchFailed")
                    : accounts.list
                      ? (activeAccount?.name ?? t("picker.harnessLogin"))
                      : undefined
                }
              />
            }
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
        <MenuSeparator />
        <MenuItem className="acpmux-quick-item acpmux-quick-sub" onSelect={() => onMore()}>
          <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
          <span className="ui-submenu-chevron" aria-hidden="true" />
        </MenuItem>
      </MenuPopup>
    </Menu>
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
  // Another chat's accounts never show for this one.
  useEffect(() => {
    setList(undefined);
    setSwitchFailed(false);
  }, [sessionId]);
  const pick = (routeId: string | null) => {
    if (!sessionId || !accounts) return;
    setList((old) =>
      old
        ? { ...old, ...(routeId ? { active: routeId, scope: "chat" } : { active: undefined, scope: undefined }) }
        : old,
    );
    accounts.set(sessionId, routeId).then(
      () => setSwitchFailed(false),
      () => {
        setSwitchFailed(true);
        // The next open reads where the chat really is.
        setList(undefined);
      },
    );
  };
  return { list, failed, switchFailed, pick };
}
