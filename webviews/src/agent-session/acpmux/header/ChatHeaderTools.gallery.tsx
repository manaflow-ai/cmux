// l10n-allow-file: gallery fixtures (sample chat actions), not shipped UI.
import { createElement } from "react";
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ChatMenuItem } from "./ChatHeaderTools";

type HeaderToolsProps = {
  onTerminal: () => void;
  onBrowser: () => void;
  tabTools?: boolean;
  summary: ReactNode;
  menu: () => ChatMenuItem[];
  onMenuOpen?: () => Promise<unknown>;
  expand?: string;
  onExpanded?: () => void;
};

const menuRows = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", shortcutAction: "renameTab", onSelect: () => undefined },
  {
    key: "pin",
    label: "Pin tab",
    icon: "action.pin",
    shortcutAction: "palette.toggleTabPin",
    onSelect: () => undefined,
  },
  "separator",
  {
    key: "continue",
    label: "Continue in",
    icon: "agent.handoff",
    children: [
      { key: "codex", label: "Codex", onSelect: () => undefined },
      { key: "claude", label: "Claude Code", onSelect: () => undefined },
    ],
  },
  { key: "copy-link", label: "Copy link", icon: "link", onSelect: () => undefined },
  "separator",
  { key: "move-right", label: "Move to pane right", icon: "pane.split.right", onSelect: () => undefined },
  { key: "new-workspace", label: "Move to new workspace", icon: "workspace.new", onSelect: () => undefined },
  "separator",
  // The tab-owned close action stays the last row, like Chrome's tab actions.
  { key: "close", label: "Close", icon: "tab.close", shortcutAction: "closeTab", onSelect: () => undefined },
];

const summary = createElement(
  "button",
  { type: "button", className: "acpmux-summary-button", "aria-label": "Turn summary" },
  "Completed",
);

const openMenu: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Chat actions" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

const keyboardMenu: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitem"][data-highlighted]'));
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    return (
      !ctx.document.querySelector('[role="menu"]') &&
      ctx.document.activeElement?.getAttribute("aria-label") === "Chat actions"
    );
  });
};

const keyboardSubmenu: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.focus({ role: "menuitem", name: "Continue in" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 1);
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    return (
      !ctx.document.querySelector('[role="menu"]') &&
      ctx.document.activeElement?.getAttribute("aria-label") === "Chat actions"
    );
  });
};

const base: HeaderToolsProps = {
  onTerminal: () => undefined,
  onBrowser: () => undefined,
  summary,
  menu: menuRows,
  onMenuOpen: async () => undefined,
};

export default componentEntry<HeaderToolsProps>({
  id: "agent-pane.header-tools",
  title: "Chat header tools",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 390, normal: 560, wide: 860 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: ["agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools"],
  load: () => import("./ChatHeaderTools").then((module) => module.ChatHeaderTools),
  // The pane's own stylesheets, as the app ships them (build-agent-pane-web.sh): its theme variables,
  // the shared popup surface, then the header's rules. With header.css alone every popup was
  // see-through in the gallery and the "Continue in" submenu bug did not show as it does in the app.
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  checks: {
    popupLayer: {
      value: true,
      reason: "The chat menu and its Continue in submenu must each be the top, unclipped, opaque layer.",
    },
    anchorMovePx: {
      value: 0,
      reason: "Opening the chat menu uses a portal and must not move the header tool row.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Header menu keyboard transitions should stay responsive on the gallery host.",
    },
  },
  variants: {
    idle: {
      note: "The complete tab header: Terminal, Browser, summary, and chat actions.",
      props: base,
    },
    "menu-open": {
      note: "The real tab menu includes navigation actions and keeps Close as the final tab-owned row.",
      props: base,
      play: openMenu,
    },
    "keyboard-menu": {
      note: "Enter opens the menu, ArrowDown highlights a row, and Escape returns focus to Chat actions.",
      props: base,
      play: keyboardMenu,
    },
    "keyboard-submenu": {
      note: "Continue in opens with ArrowRight; Escape closes the submenu and then the parent menu.",
      props: base,
      play: keyboardSubmenu,
    },
    "quick-chat": {
      note: "Quick Chat has no tab to split, so only the summary and chat actions remain.",
      props: { ...base, tabTools: false },
    },
  },
});
