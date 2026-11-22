// Settings > Menus for the dev server, tests and the gallery: three right-click menus as the app
// sends them (Swift `ContextMenusSettingsPage`), each as a tree with submenus, one inside another.
// Not shipped.
import type { ContextMenuState, ContextMenusHostState, MenuLayout, MenuNode, MenuRow } from "./ops";

const row = (
  key: string,
  title: string,
  symbol: string | null,
  home: string | null = null,
  kind: MenuRow["kind"] = "item",
): MenuRow => ({
  key,
  title,
  kind,
  symbol,
  home,
});

const workspaceRows: MenuRow[] = [
  row("renameWorkspace", "Rename Workspace…", "pencil"),
  row("palette.toggleWorkspacePin", "Pin Workspace", "pin"),
  row("palette.workspaceColor", "Workspace Color", "paintpalette", null, "submenu"),
  row("workspace.newBelow", "New Workspace Below", "plus.square.on.square"),
  row("workspace.duplicate", "Duplicate Workspace", "plus.square.on.square"),
  row("folder:move", "Move", "arrow.up.and.down.square", null, "folder"),
  row("palette.moveWorkspaceToTop", "Move to Top", "arrow.up.to.line", "folder:move"),
  row("palette.moveWorkspaceToBottom", "Move to Bottom", "arrow.down.to.line", "folder:move"),
  row("moveWorkspaceToGroup", "Move to Group", "square.stack.3d.up", null, "submenu"),
  row("folder:more", "More", "ellipsis.circle", null, "folder"),
  row("workspace.copyPath", "Copy Path", "doc.on.doc", "folder:more"),
  row("revealWorkspaceInFinder", "Reveal in Finder", "folder", "folder:more"),
  row("folder:options", "Options", "slider.horizontal.3", "folder:more", "folder"),
  row("palette.markWorkspaceUnread", "Mark as Unread", "envelope.badge", "folder:options"),
  row("workspace.showResources", "Show Resources", "gauge.with.dots.needle.33percent", "folder:options"),
  row("closeWorkspace", "Close Workspace", "xmark.square"),
];

const workspaceTree: MenuNode[] = [
  "renameWorkspace",
  "palette.toggleWorkspacePin",
  "palette.workspaceColor",
  "workspace.newBelow",
  "workspace.duplicate",
  { key: "folder:move", items: ["palette.moveWorkspaceToTop", "palette.moveWorkspaceToBottom"] },
  "-",
  "moveWorkspaceToGroup",
  "-",
  {
    key: "folder:more",
    items: [
      "workspace.copyPath",
      "revealWorkspaceInFinder",
      { key: "folder:options", items: ["palette.markWorkspaceUnread", "workspace.showResources"] },
    ],
  },
  "-",
  "closeWorkspace",
];

const tabRows: MenuRow[] = [
  row("newTab.toRight", "New Tab to the Right", "plus.square"),
  row("reloadTab", "Reload", "arrow.clockwise"),
  row("duplicateTab", "Duplicate", "plus.square.on.square"),
  row("palette.toggleTabPin", "Pin Tab", "pin"),
  row("folder:more", "More", "ellipsis.circle", null, "folder"),
  row("renameTab", "Rename Tab…", "pencil", "folder:more"),
  row("moveTabToNewWindow", "Move Tab to New Window", "macwindow", "folder:more"),
  row("closeTab", "Close Tab", "xmark.square"),
  row("closeOtherTabsInPane", "Close Other Tabs", "xmark.square.fill"),
];

const tabTree: MenuNode[] = [
  "newTab.toRight",
  "-",
  "reloadTab",
  "duplicateTab",
  "palette.toggleTabPin",
  "-",
  { key: "folder:more", items: ["renameTab", "moveTabToNewWindow"] },
  "-",
  "closeTab",
  "closeOtherTabsInPane",
];

const terminalRows: MenuRow[] = [
  row("copy", "Copy", "doc.on.doc"),
  row("paste", "Paste", "doc.on.clipboard"),
  row("splitRight", "Split Right", "rectangle.split.2x1"),
  row("splitDown", "Split Down", "rectangle.split.1x2"),
  row("clearTerminal", "Clear", "clear"),
];

function menu(id: string, title: string, area: string, rows: MenuRow[], items: MenuNode[]): ContextMenuState {
  const generated: MenuLayout = { items, hidden: [] };
  return { id, title, area, customized: false, rows, generated, layout: generated };
}

export function mockContextMenus(): ContextMenusHostState {
  return {
    show_customize_item: true,
    menus: [
      menu("workspaceRow", "Workspace", "workspace", workspaceRows, workspaceTree),
      menu("tab", "Tab", "tabs", tabRows, tabTree),
      menu("terminalSelection", "Terminal", "terminal", terminalRows, [
        "copy",
        "paste",
        "-",
        "splitRight",
        "splitDown",
        "-",
        "clearTerminal",
      ]),
    ],
  };
}

/** The mock's `cmux.settings.context_menus.set`: the layout as saved, or the generated one on Reset. */
export function setMockMenuLayout(
  state: ContextMenusHostState,
  id: string,
  layout: MenuLayout | null,
): ContextMenusHostState {
  return {
    ...state,
    menus: state.menus.map((item) =>
      item.id === id ? { ...item, layout: layout ?? item.generated, customized: layout !== null } : item,
    ),
  };
}
