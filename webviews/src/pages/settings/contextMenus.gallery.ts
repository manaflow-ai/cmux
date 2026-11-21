// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Menus (ContextMenusCard): the list of right-click menus beside the chosen menu drawn
// as a menu, More open beneath its row, Hidden rows after it.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockContextMenus, setMockMenuLayout } from "./mockMenus";

const shown: PageFixtureStep = { selector: '[data-card="context-menus"]', action: "wait" };
const base = mockContextMenus();
const variant = (focus: string, note: string, menus = base): SettingsPageVariant => ({
  section: "menus",
  focus,
  host: { context_menus: menus },
  steps: [shown],
  note,
});

const movePicker = (key: string, note: string, menus = base): SettingsPageVariant => ({
  ...variant("workspaceRow", note, menus),
  // Keep the fallback picker below the complete preview in the captured frame.
  height: 1100,
  steps: [
    shown,
    { selector: `.menu-row[data-key="${key}"] [data-action="move-to"]`, action: "click" },
    { selector: "[data-picker]", action: "wait" },
  ],
});

// Copy Path out of More, Rename inside Move ▸, Move ▸ inside More, a submenu of the person's
// holding Mark as Unread, and Duplicate hidden in place.
const customized = setMockMenuLayout(base, "workspaceRow", {
  items: [
    "workspace.copyPath",
    "palette.toggleWorkspacePin",
    "palette.workspaceColor",
    "workspace.newBelow",
    "workspace.duplicate",
    { key: "group:mine", title: "Mine", items: ["palette.markWorkspaceUnread"] },
    "-",
    "moveWorkspaceToGroup",
    "-",
    {
      key: "folder:more",
      items: [
        {
          key: "folder:move",
          items: ["renameWorkspace", "palette.moveWorkspaceToTop", "palette.moveWorkspaceToBottom"],
        },
        "revealWorkspaceInFinder",
        { key: "folder:options", items: ["workspace.showResources"] },
      ],
    },
    "-",
    "closeWorkspace",
  ],
  hidden: ["workspace.duplicate"],
});

export default settingsPageEntry({
  id: "pages.settings-menus",
  title: "Settings Menus",
  area: "Settings",
  height: 760,
  covers: [
    "pages/settings/components/ContextMenusCard.tsx",
    "pages/settings/menuLayouts.ts",
    "pages/settings/styles.css",
  ],
  anchors: [{ selector: '[data-card="context-menus"]' }],
  variants: {
    generated: variant("workspaceRow", "The Workspace menu as the app makes it: More open beneath its row, Reset off."),
    customized: variant(
      "workspaceRow",
      "Copy Path out of More, Rename inside Move, Move inside More, the person's Mine submenu, Duplicate hidden in place.",
      customized,
    ),
    terminal: variant("terminalSelection", "Customize Menu… from a terminal opens the Terminal menu."),
    "move-top-level": movePicker(
      "renameWorkspace",
      "Top-level row: current destination disabled, nested destinations visible.",
    ),
    "move-submenu": movePicker("folder:more", "Submenu: its own descendants are excluded from the destination menu."),
    "move-customized": movePicker(
      "workspace.copyPath",
      "Customized menu: user-named and nested destinations share one glass grid.",
      customized,
    ),
  },
});
