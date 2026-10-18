import { useCallback, useContext, useEffect, useState } from "react";
import { Dialog } from "../../ui/Dialog";
import { Keycap } from "./Keycap";
import { useT, type StringKey } from "./i18n";
import { labOn, useLab } from "./labs";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";
import { HEADER_ACTIONS, type ChatMenuItem } from "./header/ChatHeaderTools";
import { useComposerSettings } from "./composerSettings";
import "./shortcutsHelp.css";

const CONVERSATION: readonly [string, StringKey][] = [
  [SHORTCUT_ACTIONS.permissionAllowOnce, "permission.allowOnce"],
  [SHORTCUT_ACTIONS.permissionAllowChat, "permission.allowChat"],
  [SHORTCUT_ACTIONS.permissionDeny, "permission.deny"],
  [SHORTCUT_ACTIONS.permissionExpand, "permission.expand"],
  [SHORTCUT_ACTIONS.permissionRetry, "permission.checkRetry"],
  [SHORTCUT_ACTIONS.permissionRevoke, "permission.revoke"],
  [SHORTCUT_ACTIONS.permissionRefresh, "permission.refresh"],
  [SHORTCUT_ACTIONS.copyTabLink, "chatMenu.copyLink"],
  [HEADER_ACTIONS.changes, "header.changes"],
  [HEADER_ACTIONS.rename, "chatMenu.rename"],
  [HEADER_ACTIONS.pin, "chatMenu.pin"],
];
const NAVIGATION: readonly [string, StringKey][] = [
  [SHORTCUT_ACTIONS.newAgentChat, "sidebar.newChat"],
  ["agentPane.searchChats", "sidebar.search"],
  [HEADER_ACTIONS.terminal, "header.terminal"],
  [HEADER_ACTIONS.splitDown, "header.splitDown"],
  [HEADER_ACTIONS.browser, "header.browser"],
  [HEADER_ACTIONS.moveRight, "chatMenu.moveRight"],
  [HEADER_ACTIONS.newWorkspace, "chatMenu.newWorkspace"],
  [HEADER_ACTIONS.newWindow, "chatMenu.newWindow"],
  [HEADER_ACTIONS.close, "chatMenu.close"],
];

/// The same live labels as the header and mic, with the composer's own fixed editing keys
/// (Lucas 2026-10-18). An unbound host action has no stale default here.
export function ShortcutsHelp({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const enabled = useLab("shortcutsHelp");
  const t = useT();
  const shortcuts = useContext(ShortcutsContext);
  const { showDictation } = useComposerSettings();
  const bound = (actions: readonly [string, StringKey][]) =>
    actions.flatMap(([action, label]) =>
      shortcuts[action] ? [{ id: action, label: t(label), key: shortcuts[action]! }] : [],
    );
  const groups = [
    {
      title: t("shortcutsHelp.composer"),
      entries: [
        { id: "send", label: t("composer.send"), key: "↩" },
        { id: "newline", label: t("shortcutsHelp.newLine"), key: "⇧↩" },
        { id: "steer", label: t("composer.steerLabel"), key: "⌘↩" },
        { id: "stop", label: t("composer.stop"), key: "esc" },
        ...bound(showDictation ? [[SHORTCUT_ACTIONS.toggleDictation, "dictation.start"]] : []),
      ],
    },
    { title: t("shortcutsHelp.conversation"), entries: bound(CONVERSATION) },
    {
      title: t("shortcutsHelp.navigation"),
      entries: bound(NAVIGATION),
    },
  ];
  if (!enabled) return null;
  return (
    <Dialog open={open} onOpenChange={onOpenChange} label={t("shortcutsHelp.title")} className="acpmux-shortcuts-help">
      <div className="acpmux-shortcuts-help__heading">
        <h2>{t("shortcutsHelp.title")}</h2>
        <button type="button" onClick={() => onOpenChange(false)}>
          {t("find.close")}
        </button>
      </div>
      {groups
        .filter((group) => group.entries.length > 0)
        .map((group) => (
          <section key={group.title} aria-label={group.title}>
            <h3>{group.title}</h3>
            <dl>
              {group.entries.map((entry) => (
                <div key={entry.id}>
                  <dt>{entry.label}</dt>
                  <dd>
                    <span className="acpmux-shortcuts-help__spoken">{entry.key}</span>
                    <Keycap>{entry.key}</Keycap>
                  </dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
    </Dialog>
  );
}

/// Menu and bridge commands open one dialog (Lucas 2026-10-18).
export function useShortcutsHelp() {
  const enabled = useLab("shortcutsHelp");
  const t = useT();
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!enabled) setOpen(false);
  }, [enabled]);
  const command = useCallback((name: string): boolean => {
    if (name !== "shortcutsHelp" || !labOn("shortcutsHelp")) return false;
    setOpen(true);
    return true;
  }, []);
  const menu: ChatMenuItem | undefined = enabled
    ? {
        key: "shortcutsHelp",
        label: t("shortcutsHelp.title"),
        icon: "keyboard",
        onSelect: () => {
          command("shortcutsHelp");
        },
      }
    : undefined;
  return { command, menu, dialog: enabled ? <ShortcutsHelp open={open} onOpenChange={setOpen} /> : null };
}
