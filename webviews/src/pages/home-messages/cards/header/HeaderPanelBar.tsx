// The Home transcript header's top-right toggles (Swift `HomeHeaderPanelBar` and the panel list of
// `HomeHeaderPanels`): quiet icon buttons, no pill at rest, the theme's hover pill, the accent
// glyph when on, left to right in the panels' order. Each opens a panel beside Home and, clicked
// again, closes it (Leo 2026-10-20: "Use top-right toggle buttons ... Nothing opens by default").
// The host says which show and which are on (`cmux.home.headerPanels.state`); a click is
// `cmux.home.headerPanels.toggle {id}`, which runs the panel's action as the person's own.
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import { Tooltip } from "../../../../ui/Tooltip";
import type { Strings } from "../strings";
import "../cards.css";

/** A click on toggle `id` (page → host): the panel's action, with its arguments for this chat. */
export const HEADER_PANEL_TOGGLE_OP = "cmux.home.headerPanels.toggle";
/** The host's state of every toggle for this chat (host → page), after every change. */
export const HEADER_PANEL_STATE_EVENT = "cmux.home.headerPanels.state";

/** One header panel (the Swift `HomeHeaderPanel` entry): its icon closed and open, its name. */
export interface HeaderPanel {
  id: string;
  icon: string;
  onIcon?: string;
  labelKey: string;
  /** Shown for this chat (Memory: a Chief's only). */
  isShown(context: HeaderPanelContext): boolean;
  /** Shown even while the Debug toggle hides the others: a control that is also an indicator. */
  alwaysShown?: boolean;
}

/** What a toggle reads of the conversation. */
export interface HeaderPanelContext {
  isChief: boolean;
  /** A named local Chief, else this Mac's own. */
  chief?: string;
  /** A paired server's Chief. */
  server?: string;
}

/** Every header toggle, left to right. */
export const HEADER_PANELS: readonly HeaderPanel[] = [
  {
    // Share Screen with Chief: on this Mac's own Chief only, lit while the Chief can see the screen.
    id: "screenShare",
    icon: "remote.display",
    onIcon: "status.running",
    labelKey: "chiefScreenShare.header.label",
    isShown: (context) => context.isChief && !context.chief && !context.server,
    alwaysShown: true,
  },
  { id: "memory", icon: "tool.thought", labelKey: "home.headerPanels.memory", isShown: (context) => context.isChief },
  { id: "rightSidebar", icon: "panel.right", labelKey: "home.headerPanels.rightSidebar", isShown: () => true },
];

/** One toggle as the host reports it. */
export interface HeaderPanelState {
  id: string;
  isOn: boolean;
  /** The toggle's shortcut for its tooltip ("⌥⌘B"). */
  shortcut?: string;
}

/** One drawn toggle. */
export interface HeaderPanelItem {
  id: string;
  icon: string;
  onIcon: string;
  label: string;
  shortcut?: string;
  isOn: boolean;
}

/** The cluster's buttons for `context`: only the always-shown ones while the Debug toggle
 * (Debug Settings > Home > Home header panel toggles) is off. */
export function headerPanelItems(
  context: HeaderPanelContext,
  states: readonly HeaderPanelState[],
  strings: Strings,
  enabled: boolean,
  panels: readonly HeaderPanel[] = HEADER_PANELS,
): HeaderPanelItem[] {
  return panels
    .filter((panel) => (enabled || panel.alwaysShown) && panel.isShown(context))
    .map((panel) => {
      const state = states.find((entry) => entry.id === panel.id);
      return {
        id: panel.id,
        icon: panel.icon,
        onIcon: panel.onIcon ?? panel.icon,
        label: strings.t(panel.labelKey),
        shortcut: state?.shortcut,
        isOn: state?.isOn ?? false,
      };
    });
}

export function HeaderPanelBar({ items, onToggle }: { items: readonly HeaderPanelItem[]; onToggle(id: string): void }) {
  if (!items.length) return null;
  return (
    <div className="hm-header-panels" role="toolbar" data-testid="cmux.home.headerPanels">
      {items.map((item) => (
        <Tooltip key={item.id} label={item.label} shortcut={item.shortcut} side="bottom">
          <button
            type="button"
            className="hm-header-panels__button"
            data-testid={`cmux.home.headerPanel.${item.id}`}
            aria-label={item.label}
            aria-pressed={item.isOn}
            onClick={() => onToggle(item.id)}
          >
            <Icon name={item.isOn ? item.onIcon : item.icon} size={16} />
          </button>
        </Tooltip>
      ))}
    </div>
  );
}
