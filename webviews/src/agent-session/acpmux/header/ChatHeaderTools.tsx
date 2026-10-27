// The chat header's top right: the quick actions (quickActions.ts: which show, in which order, and
// whether each toggles or opens; by default Changes, while it applies, then Terminal and Browser, which
// split the pane in the chat's folder and toggle, as in T3 Chat and ChatGPT; Browser opens the chat's
// local page when there is one, the job of the Preview button a person can still show); the
// summary (Sources) button, whose popover also opens the last turn's changes; and the "..." chat menu,
// which starts with the quick actions not shown as buttons ([+] New tab, which reads Hide tabs in place,
// Files and Split Down; each while it applies). Before them, the chat branch's pull request with its
// checks (cx-tcwj, Codex desktop's PR chip; PullRequestChip.tsx), when the App found one. Every control
// renders from the first frame at its final size; data fills in place.
import { useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { tooltipProps, useShortcut } from "../shortcuts";
import { registerPicker } from "../pickerOpeners";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator, Submenu } from "../../../ui/Menu";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { headerState, useHeaderState } from "./headerState";
import { PullRequestChip } from "./PullRequestChip";
import { useWorktree, WorktreePill } from "./WorktreePill";
import type { MergeResult } from "./PullRequestMerge";
import {
  QUICK_ACTION_DEFAULTS,
  QUICK_ACTION_IDS,
  useQuickActions,
  withMode,
  withMoved,
  withShown,
  type QuickAction,
  type QuickActionId,
  type QuickActionMode,
} from "./quickActions";

/// Every header button's glyph (header.css): Claude Code desktop's top strip draws one size for all of
/// them, the Needs you inbox and the Inspector toggle included.
export const HEADER_GLYPH = 16;

/// The app actions the header runs on its tab (CmuxNextAgentPane AgentPaneModel.headerActions).
export const HEADER_ACTIONS = {
  terminal: "splitRight",
  splitDown: "splitDown",
  browser: "splitBrowserRight",
  changes: "openDiffViewer",
  /// Not an app action: the App opens the Files tree (CmuxNextApp AgentChatSplitToggles.files).
  files: "files",
  /// Not an app action: its own `pane.action` (CmuxNextAgentPane AgentPaneModel.previewAction).
  preview: "preview",
  rename: "renameTab",
  pin: "palette.toggleTabPin",
  moveRight: "moveSurfaceToPaneRight",
  newWorkspace: "palette.moveTabToNewWorkspace",
  newWindow: "tab.moveToNewWindow",
  /// Not an app action: Start Agent's panel holds the chat (CmuxNextAgentPane AgentPaneHeaderHooks.moveToFloatingChat).
  floatingChat: "floatingChat",
  close: "closeTab",
} as const;

export type ChatMenuItem =
  | "separator"
  | {
      key: string;
      label: string;
      icon: string;
      /// An app action id whose keycap the row shows.
      shortcutAction?: string;
      /// A product-level key hint when the action has no registered host shortcut (for example, the
      /// title menu's Rename R and Fork F, matching Claude Code's session menu).
      shortcutLabel?: string;
      disabled?: boolean;
      onSelect?: () => void;
      children?: ChatMenuChild[];
    };

/// The menu's groups in order, the empty ones dropped, with a separator between each two.
export const menuGroups = (...groups: ChatMenuItem[][]): ChatMenuItem[] =>
  groups.filter((group) => group.length > 0).flatMap((group, index) => (index ? ["separator", ...group] : group));

/// A preview's address as its card shows it: host, then the path and query when there is one.
function previewAddress(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.host}${parsed.pathname === "/" ? "" : parsed.pathname}${parsed.search}`;
  } catch {
    return url;
  }
}

/// A submenu row: its label, and the keycap of `shortcutAction` when it has one.
export type ChatMenuChild = {
  key: string;
  label: string;
  disabled?: boolean;
  shortcutAction?: string;
  shortcutLabel?: string;
  onSelect: () => void;
};

type ShortcutMenuItem = Exclude<ChatMenuItem, "separator"> | ChatMenuChild;

export function menuItemForShortcut(
  items: readonly (ChatMenuItem | ChatMenuChild)[],
  key: string,
): ShortcutMenuItem | undefined {
  const normalized = key.length === 1 ? key.toUpperCase() : "";
  if (!normalized) return undefined;
  return items.find(
    (item): item is ShortcutMenuItem => item !== "separator" && item.shortcutLabel?.toUpperCase() === normalized,
  );
}

/** A popup may outlive the selected chat until React commits the new view. Its callbacks must
 * remain bound to the chat that opened it, including submenu callbacks. */
export function guardedChatMenu(items: ChatMenuItem[], current: () => boolean): ChatMenuItem[] {
  const guard = (run: () => void) => () => {
    if (current()) run();
  };
  return items.map((item) =>
    item === "separator"
      ? item
      : {
          ...item,
          ...(item.onSelect && { onSelect: guard(item.onSelect) }),
          ...(item.children && {
            children: item.children.map((child) => ({ ...child, onSelect: guard(child.onSelect) })),
          }),
        },
  );
}

export function ChatHeaderTools({
  onTerminal,
  onSplitDown,
  onBrowser,
  hasChanges = false,
  onChanges,
  onFiles,
  previewUrl,
  onPreview,
  sideTabs = false,
  onSideTabs,
  onPointerEnter,
  onCustomize,
  tabTools = true,
  summary,
  menu,
  onMenuOpen,
  expand,
  onExpanded,
  pullRequestChip,
  onMergePullRequest,
  folder,
  readStatus,
  statusKey,
  onApplyWorktree,
  onRemoveWorktree,
  inspector,
  inbox,
}: {
  /// Terminal and Browser run their split with the quick action's mode: the App opens it, or for
  /// `toggle` closes the split this button opened when it is still there.
  onTerminal: (mode: QuickActionMode) => void;
  /// Split Down runs a terminal split under the chat the same way (Quick Chat's panel has none).
  onSplitDown?: (mode: QuickActionMode) => void;
  onBrowser: (mode: QuickActionMode) => void;
  /// Whether the chat edited files: Changes shows then, and while its diff is open.
  hasChanges?: boolean;
  /// Changes runs the diff viewer with the quick action's mode, as Terminal and Browser run their split.
  onChanges?: (mode: QuickActionMode) => void;
  /// Files runs the tree of the chat's folder with the quick action's mode; without it (a remote chat) Files hides.
  onFiles?: (mode: QuickActionMode) => void;
  /// The local page the chat's last turn started or mentioned: Preview shows then, and while its page is open.
  previewUrl?: string;
  /// Preview opens `url` beside the chat with the quick action's mode; a click that closes it may name none.
  onPreview?: (url: string | undefined, mode: QuickActionMode) => void;
  /// Whether the panes beside the chat show: [+] New tab reads Hide tabs, in the same spot.
  sideTabs?: boolean;
  onSideTabs?: () => void;
  /// The pointer reached the tools: the App rereads the layout, so [+] reads right before a click.
  onPointerEnter?: () => void;
  /// The right-click menu changed the quick actions: the App saves them to `agent-pane/layout.json`.
  onCustomize?: (list: readonly QuickAction[]) => void;
  /// Terminal and Browser split the chat's tab; Quick Chat's panel has none.
  tabTools?: boolean;
  summary: ReactNode;
  /// The menu's rows, read when it opens.
  menu: () => ChatMenuItem[];
  /// Runs before the menu opens; the menu shows once it settles.
  onMenuOpen?: () => Promise<unknown>;
  /// A row with children to show open (the palette's Continue In…); `onExpanded` clears it.
  expand?: string;
  onExpanded?: () => void;
  /// The pull request chip (default on); a subagent's own pane draws none: the pull request is the chat's.
  pullRequestChip?: boolean;
  /// Merge on the PR chip (cx-ncc.77.4): merges that pull request; rejects with why not.
  onMergePullRequest?: (pullRequest: { number: number; url: string }) => Promise<MergeResult>;
  /// The chat's folder on this Mac and its `git.status`: a worktree chat's branch shows (cx-lyqio.3b),
  /// read again when `statusKey` changes.
  folder?: string;
  readStatus?: (cwd: string) => Promise<unknown>;
  statusKey?: unknown;
  /// Apply on the worktree pill (cx-lyqio.4): `git.worktree.apply` for the chat's session.
  onApplyWorktree?: (key: string) => Promise<unknown>;
  /// Remove on the worktree pill (cx-lyqio.5): `git.worktree.remove` for the chat's session.
  onRemoveWorktree?: (key: string, discard: boolean) => Promise<unknown>;
  /// The Inspector's toggle (Debug Settings `agent.inspector`, inspector/ChatInspector.tsx): with it,
  /// the right-side panel's toggle in the summary's place, the first of the icons.
  inspector?: ReactNode;
  /// The Needs you inbox (needsYou/NeedsYou.tsx), right after the panel toggle, so the toggle stays
  /// the first of the top-right icons.
  inbox?: ReactNode;
}) {
  const t = useT();
  const terminalKey = useShortcut(HEADER_ACTIONS.terminal);
  const splitDownKey = useShortcut(HEADER_ACTIONS.splitDown);
  const browserKey = useShortcut(HEADER_ACTIONS.browser);
  const changesKey = useShortcut(HEADER_ACTIONS.changes);
  const { lit, pullRequest, browserOpensPreview } = useHeaderState();
  // With the Debug toggle off, the default buttons are the old ones: Preview beside Browser.
  const quick = useQuickActions();
  const actions =
    !browserOpensPreview && JSON.stringify(quick) === JSON.stringify(QUICK_ACTION_DEFAULTS)
      ? withShown(quick, "preview", true)
      : quick;
  const worktree = useWorktree(folder, readStatus, statusKey);
  // A toggle is on while the split it opened is open; in open mode each click makes another, so none is.
  const on = (action: string, mode: QuickActionMode) => (mode === "toggle" ? lit.includes(action) : undefined);
  // The right-clicked button, read as the menu opens.
  const target = useRef<QuickActionId>(undefined);
  const [menuTarget, setMenuTarget] = useState<QuickActionId>();
  // The quick actions without a button, at the top of "...": each while it would show as a button.
  // Changes is listed there with its button too.
  // Built when "..." reads its rows, after the App's tab state refresh (onMenuOpen): the props of this
  // render, and the lit splits as the App last pushed them.
  const live = useRef({
    actions,
    tabTools,
    sideTabs,
    hasChanges,
    previewUrl,
    onChanges,
    onPreview,
    onSideTabs,
    onFiles,
    onSplitDown,
  });
  live.current = {
    actions,
    tabTools,
    sideTabs,
    hasChanges,
    previewUrl,
    onChanges,
    onPreview,
    onSideTabs,
    onFiles,
    onSplitDown,
  };
  const foldedRows = (): ChatMenuItem[] => {
    const {
      actions,
      tabTools,
      sideTabs,
      hasChanges,
      previewUrl,
      onChanges,
      onPreview,
      onSideTabs,
      onFiles,
      onSplitDown,
    } = live.current;
    if (!tabTools) return [];
    const { lit } = headerState();
    const shownIds = new Set(actions.map((action) => action.id));
    const folded: ChatMenuItem[] = [];
    // Changes stays in "..." beside its button, as in the Codex and Claude apps' chat menus (hq#2569 item 4).
    if (onChanges && (hasChanges || lit.includes(HEADER_ACTIONS.changes)))
      folded.push({
        key: "quick-changes",
        label: t("header.changes"),
        icon: "diff.file",
        shortcutAction: HEADER_ACTIONS.changes,
        onSelect: () => onChanges("toggle"),
      });
    // Browser opens the chat's page itself (Debug `agentChat.browserOpensPreview`), so then Preview
    // folds only without a Browser button.
    if (
      onPreview &&
      !shownIds.has("preview") &&
      !(shownIds.has("browser") && headerState().browserOpensPreview) &&
      (previewUrl || lit.includes(HEADER_ACTIONS.preview))
    )
      folded.push({
        key: "quick-preview",
        label: t("header.preview"),
        icon: "media.play",
        onSelect: () => onPreview(previewUrl, "toggle"),
      });
    if (onSideTabs && !shownIds.has("newTab"))
      folded.push({
        key: "quick-newTab",
        label: t(sideTabs ? "header.hideTabs" : "header.newTab"),
        icon: sideTabs ? "tunable.sidebar" : "action.add",
        onSelect: onSideTabs,
      });
    if (onFiles && !shownIds.has("files"))
      folded.push({
        key: "quick-files",
        label: t("header.files"),
        icon: "folder",
        onSelect: () => onFiles("toggle"),
      });
    if (onSplitDown && !shownIds.has("splitDown"))
      folded.push({
        key: "quick-splitDown",
        label: t("header.splitDown"),
        icon: "pane.split.down",
        shortcutAction: HEADER_ACTIONS.splitDown,
        onSelect: () => onSplitDown("toggle"),
      });
    return folded;
  };
  const rows = () => menuGroups(foldedRows(), menu());
  // Browser without its own Preview button (the default): the chat's local page when it has one, so the
  // globe opens what the chat is about, not a blank tab (Leo 2026-10-20). A toggle click closes whichever
  // browser it opened: the page's preview or the plain split.
  const previewInBrowser =
    browserOpensPreview && onPreview !== undefined && !actions.some((action) => action.id === "preview");
  const browserRun = (mode: QuickActionMode) => {
    // The page goes along, as the Preview button sent it: a preview the person closed since the last
    // state push opens again instead of the click doing nothing.
    if (previewInBrowser && on(HEADER_ACTIONS.preview, mode)) return onPreview(previewUrl, mode);
    if (previewInBrowser && previewUrl && !on(HEADER_ACTIONS.browser, mode)) return onPreview(previewUrl, mode);
    onBrowser(mode);
  };
  const browserPressed = (mode: QuickActionMode) =>
    previewInBrowser && on(HEADER_ACTIONS.preview, mode) ? true : on(HEADER_ACTIONS.browser, mode);
  const buttons = tabTools && actions.length > 0 && (
    <>
      {actions.map(({ id, mode }) =>
        id === "newTab" ? (
          // One button whose label and icon change, so the next click lands on it again.
          <button
            key={id}
            data-quick-action={id}
            type="button"
            className="acpmux-header-tool"
            aria-label={t(sideTabs ? "header.hideTabs" : "header.newTab")}
            aria-pressed={sideTabs}
            title={t(sideTabs ? "header.hideTabs" : "header.newTab")}
            onClick={onSideTabs}
          >
            <Icon name={sideTabs ? "tunable.sidebar" : "action.add"} size={HEADER_GLYPH} />
          </button>
        ) : id === "changes" ? (
          // Hidden, not disabled, without changes (cx-qom0); an open diff keeps it, to close it here.
          onChanges && (hasChanges || lit.includes(HEADER_ACTIONS.changes)) ? (
            <button
              key={id}
              data-quick-action={id}
              type="button"
              className="acpmux-header-tool"
              aria-label={t("header.changes")}
              aria-pressed={on(HEADER_ACTIONS.changes, mode)}
              {...tooltipProps(t("header.changes"), changesKey)}
              onClick={() => onChanges(mode)}
            >
              <Icon name="diff.file" size={HEADER_GLYPH} />
            </button>
          ) : null
        ) : id === "files" ? (
          onFiles ? (
            <button
              key={id}
              data-quick-action={id}
              type="button"
              className="acpmux-header-tool"
              aria-label={t("header.files")}
              aria-pressed={on(HEADER_ACTIONS.files, mode)}
              title={t("header.files")}
              onClick={() => onFiles(mode)}
            >
              <Icon name="folder" size={HEADER_GLYPH} />
            </button>
          ) : null
        ) : id === "preview" ? (
          // Hidden, not disabled, without a page (cx-qom0); an open preview keeps it, to close it here.
          onPreview && (previewUrl || on(HEADER_ACTIONS.preview, mode)) ? (
            <button
              key={id}
              data-quick-action={id}
              type="button"
              className="acpmux-header-tool"
              aria-label={t("header.preview")}
              aria-pressed={on(HEADER_ACTIONS.preview, mode)}
              title={
                previewUrl ? t("header.previewAddress", { address: previewAddress(previewUrl) }) : t("header.preview")
              }
              onClick={() => onPreview(previewUrl, mode)}
            >
              <Icon name="media.play" size={HEADER_GLYPH} />
            </button>
          ) : null
        ) : id === "splitDown" ? (
          onSplitDown ? (
            <button
              key={id}
              data-quick-action={id}
              type="button"
              className="acpmux-header-tool"
              aria-label={t("header.splitDown")}
              aria-pressed={on(HEADER_ACTIONS.splitDown, mode)}
              {...tooltipProps(t("header.splitDown"), splitDownKey)}
              onClick={() => onSplitDown(mode)}
            >
              <Icon name="pane.split.down" size={HEADER_GLYPH} />
            </button>
          ) : null
        ) : id === "terminal" ? (
          <button
            key={id}
            data-quick-action={id}
            type="button"
            className="acpmux-header-tool"
            aria-label={t("header.terminal")}
            aria-pressed={on(HEADER_ACTIONS.terminal, mode)}
            {...tooltipProps(t("header.terminal"), terminalKey)}
            onClick={() => onTerminal(mode)}
          >
            <Icon name="terminal" size={HEADER_GLYPH} />
          </button>
        ) : (
          <button
            key={id}
            data-quick-action={id}
            type="button"
            className="acpmux-header-tool"
            aria-label={t("header.browser")}
            aria-pressed={browserPressed(mode)}
            {...(previewInBrowser && previewUrl
              ? tooltipProps(t("header.previewAddress", { address: previewAddress(previewUrl) }), undefined)
              : tooltipProps(t("header.browser"), browserKey))}
            onClick={() => browserRun(mode)}
          >
            <Icon name="browser" size={HEADER_GLYPH} />
          </button>
        ),
      )}
    </>
  );
  return (
    <div className="acpmux-header-tools" onPointerEnter={onPointerEnter}>
      {worktree && <WorktreePill worktree={worktree} onApply={onApplyWorktree} onRemove={onRemoveWorktree} />}
      {pullRequest && pullRequestChip !== false && (
        <PullRequestChip pullRequest={pullRequest} onMerge={onMergePullRequest} />
      )}
      {/* The panel toggle leads the icons, as in Claude and ChatGPT desktop. */}
      {inspector}
      {summary}
      {inbox}
      {buttons ? (
        <div className="acpmux-header-tool-group acpmux-header-tool-group-actions">
          {onCustomize ? (
            // Only the buttons: the summary's and the menu's popups are portaled, and a right-click
            // inside them reaches this host through React.
            <ContextMenu
              className="acpmux-header-customize"
              items={customizeItems(actions, menuTarget, onCustomize, t)}
              onOpen={() => setMenuTarget(target.current)}
            >
              <div
                className="acpmux-header-customize"
                onContextMenuCapture={(event) => {
                  const button = (event.target as Element).closest?.("[data-quick-action]");
                  target.current = (button?.getAttribute("data-quick-action") ?? undefined) as
                    | QuickActionId
                    | undefined;
                }}
              >
                {buttons}
              </div>
            </ContextMenu>
          ) : (
            buttons
          )}
        </div>
      ) : null}
      <ChatMenu
        items={rows}
        disabled={rows().length === 0}
        onOpen={onMenuOpen}
        expand={expand}
        onExpanded={onExpanded}
      />
    </div>
  );
}

/// The quick actions that show whatever the chat holds (Changes and Preview need edits or a page,
/// Files a folder on this Mac).
const ALWAYS_SHOWN: ReadonlySet<QuickActionId> = new Set(["terminal", "splitDown", "browser", "newTab"]);

const QUICK_ACTION_NAMES: Record<QuickActionId, StringKey> = {
  terminal: "header.terminal",
  splitDown: "header.splitDown",
  browser: "header.browser",
  changes: "header.changes",
  files: "header.files",
  preview: "header.preview",
  newTab: "header.newTab",
};

/// The header's right-click menu (cx-00n1, Claude Code desktop's toolbar customization): for the
/// right-clicked button, Move Left/Right and whether a click toggles its panel or opens another
/// ([+] New tab always toggles); then every quick action, checked while shown; then Reset. The last
/// button always shown (Terminal, Browser, Split Down, New tab) cannot be hidden: the menu opens on the buttons.
function customizeItems(
  list: readonly QuickAction[],
  target: QuickActionId | undefined,
  save: (list: readonly QuickAction[]) => void,
  t: ReturnType<typeof useT>,
): ContextMenuItem[] {
  const items: ContextMenuItem[] = [];
  const index = target ? list.findIndex((action) => action.id === target) : -1;
  const check = (on: boolean, label: string) => (
    <>
      <span className="acpmux-header-customize-check" aria-hidden="true">
        {on ? "✓" : ""}
      </span>
      {label}
    </>
  );
  if (target && index >= 0) {
    const mode = list[index].mode;
    items.push(
      {
        id: "moveLeft",
        label: t("header.quickActions.moveLeft"),
        disabled: index === 0,
        onSelect: () => save(withMoved(list, target, -1)),
      },
      {
        id: "moveRight",
        label: t("header.quickActions.moveRight"),
        disabled: index === list.length - 1,
        onSelect: () => save(withMoved(list, target, 1)),
      },
    );
    if (target !== "newTab") {
      const modes = [
        ["toggle", "header.quickActions.toggles"],
        ["open", "header.quickActions.opens"],
      ] as const;
      for (const [value, key] of modes) {
        items.push({
          id: value,
          label: check(mode === value, t(key)),
          ariaLabel: t(key),
          separatorBefore: value === "toggle",
          onSelect: () => save(withMode(list, target, value)),
        });
      }
    }
  }
  for (const id of QUICK_ACTION_IDS) {
    const shown = list.some((action) => action.id === id);
    const name = t(QUICK_ACTION_NAMES[id]);
    items.push({
      id: `show-${id}`,
      label: check(shown, name),
      ariaLabel: t(shown ? "header.quickActions.hide" : "header.quickActions.show", { name }),
      disabled: shown && !withShown(list, id, false).some((action) => ALWAYS_SHOWN.has(action.id)),
      separatorBefore: items.length > 0 && id === QUICK_ACTION_IDS[0],
      onSelect: () => save(withShown(list, id, !shown)),
    });
  }
  items.push({
    id: "reset",
    label: t("header.quickActions.reset"),
    separatorBefore: true,
    disabled: JSON.stringify(list) === JSON.stringify(QUICK_ACTION_DEFAULTS),
    onSelect: () => save(QUICK_ACTION_DEFAULTS),
  });
  return items;
}

export function ChatMenu({
  items,
  disabled,
  onOpen,
  expand,
  onExpanded,
  trigger,
  triggerClassName,
  triggerLabel,
  triggerTitle,
  registerPickerLabel,
}: {
  items: () => ChatMenuItem[];
  /// No rows yet (Quick Chat before its session): the button stays, disabled.
  disabled?: boolean;
  onOpen?: () => Promise<unknown>;
  expand?: string;
  onExpanded?: () => void;
  /// Optional trigger content for another header control (ThreadTitle); the menu behavior stays shared.
  trigger?: ReactNode;
  triggerClassName?: string;
  triggerLabel?: string;
  triggerTitle?: string;
  /// `null` leaves this menu out of the picker registry (a title menu is not the header actions picker).
  registerPickerLabel?: string | null;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<ChatMenuItem[]>([]);
  // Set when the palette asks for one row's children (Continue In…): the menu lists only those.
  const [only, setOnly] = useState<string>();
  const opening = useRef(0);
  const itemsRef = useRef(items);
  itemsRef.current = items;
  useEffect(
    () => () => {
      opening.current++;
    },
    [],
  );
  const show = (row?: string) => {
    const generation = ++opening.current;
    const apply = () => {
      if (generation !== opening.current) return;
      // `onOpen` refreshes native state and may rerender before its promise settles. Read the
      // latest factory after that await so a title menu never commits the previous chat's targets.
      setRows(itemsRef.current());
      setOnly(row);
      setOpen(true);
    };
    // Open on the press. Refresh native availability in place; a delayed response must never
    // postpone the menu or reopen it after dismissal or unmount.
    apply();
    void onOpen?.()
      .catch(() => undefined)
      .then(apply);
  };
  const showRef = useRef(show);
  showRef.current = show;
  useEffect(() => {
    if (!expand) return;
    showRef.current(expand);
    onExpanded?.();
  }, [expand, onExpanded]);
  // Automation and captures open it by its label, as a click does (see pickerOpeners.ts).
  const label = t("chatMenu.open");
  useEffect(() => {
    const pickerLabel = registerPickerLabel === undefined ? label : registerPickerLabel;
    if (pickerLabel === null) return;
    return registerPicker(pickerLabel, () => showRef.current());
  }, [label, registerPickerLabel]);
  const onOpenChange = (next: boolean) => {
    if (next) return show();
    opening.current++;
    setOpen(false);
  };
  const focused = only ? rows.find((row) => row !== "separator" && row.key === only) : undefined;
  const children = focused && focused !== "separator" ? focused.children : undefined;
  const shortcutRows = children ?? rows;
  const onMenuKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || event.key.length !== 1) return;
    const key = event.key.toUpperCase();
    const item = menuItemForShortcut(rows, key) ?? menuItemForShortcut(shortcutRows, key);
    if (!item || item.disabled || !item.onSelect) return;
    event.preventDefault();
    event.stopPropagation();
    item.onSelect();
    onOpenChange(false);
  };
  const buttonLabel = triggerLabel ?? label;
  return (
    <Menu open={open} onOpenChange={onOpenChange}>
      <MenuButton
        className={triggerClassName ?? "acpmux-header-tool"}
        label={buttonLabel}
        title={triggerTitle}
        disabled={disabled}
      >
        {trigger ?? <Icon name="action.more.vertical" size={HEADER_GLYPH} />}
      </MenuButton>
      <MenuPopup className="acpmux-chat-menu-popover" align="end" onKeyDown={onMenuKeyDown}>
        {children
          ? children.map((child) => <ChatMenuChildRow key={child.key} child={child} />)
          : rows.map((row, index) =>
              row === "separator" ? (
                // oxlint-disable-next-line react/no-array-index-key
                <MenuSeparator key={`separator-${index}`} />
              ) : row.children ? (
                <Submenu
                  key={row.key}
                  className="acpmux-chat-menu-item"
                  popupClassName="acpmux-chat-menu-popover"
                  disabled={row.disabled}
                  label={
                    <>
                      <Icon name={row.icon} size={15} />
                      <span className="acpmux-chat-menu-label">{row.label}</span>
                      {row.shortcutLabel && <kbd className="acpmux-chat-menu-key">{row.shortcutLabel}</kbd>}
                    </>
                  }
                >
                  {row.children.map((child) => (
                    <ChatMenuChildRow key={child.key} child={child} />
                  ))}
                </Submenu>
              ) : (
                <ChatMenuRow key={row.key} item={row} />
              ),
            )}
      </MenuPopup>
    </Menu>
  );
}

function ChatMenuRow({ item }: { item: Exclude<ChatMenuItem, "separator"> }) {
  const registeredShortcut = useShortcut(item.shortcutAction ?? "");
  const shortcut = item.shortcutLabel ?? registeredShortcut;
  return (
    <MenuItem className="acpmux-chat-menu-item" disabled={item.disabled} onSelect={item.onSelect}>
      <Icon name={item.icon} size={15} />
      <span className="acpmux-chat-menu-label">{item.label}</span>
      {shortcut && <kbd className="acpmux-chat-menu-key">{shortcut}</kbd>}
    </MenuItem>
  );
}

function ChatMenuChildRow({ child }: { child: ChatMenuChild }) {
  const registeredShortcut = useShortcut(child.shortcutAction ?? "");
  const shortcut = child.shortcutLabel ?? registeredShortcut;
  return (
    <MenuItem className="acpmux-chat-menu-item" disabled={child.disabled} onSelect={child.onSelect}>
      <span className="acpmux-chat-menu-label">{child.label}</span>
      {shortcut && <kbd className="acpmux-chat-menu-key">{shortcut}</kbd>}
    </MenuItem>
  );
}
