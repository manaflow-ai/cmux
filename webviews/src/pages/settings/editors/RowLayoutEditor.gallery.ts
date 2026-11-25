// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Sidebar > Workspace Rows > Row Layout (CMUX-383) on the real page and mock store: the
// three layout keys' tabs, the empty state, a refused write, and a full layout.
import { settingsPageEntry, type SettingsPageVariant } from "../../../gallery/format";

const LINES = "sidebar.workspaceRow.lines";
const BY_KIND = "sidebar.workspaceRow.linesByKind";
const BY_AGENT = "sidebar.workspaceRow.linesByAgent";

const tab =
  (name: string): SettingsPageVariant["play"] =>
  async (ctx) => {
    await ctx.click({ role: "tab", name });
    await ctx.waitFor(
      () =>
        ctx.document.querySelector(`[data-row-key="${LINES}"] [role="tab"][aria-selected="true"]`)?.textContent ===
        name,
    );
  };

const variants: Record<string, SettingsPageVariant> = {
  "all-rows": {
    section: "sidebar",
    focus: LINES,
    note: "All Rows: marks, the name pinned on line one, two text lines, Add Line.",
    options: {
      values: {
        [LINES]: [
          ["icon", "name", "branch", "working"],
          ["agentStatus", "lastActivity"],
        ],
      },
    },
  },
  "item-switches": {
    section: "sidebar",
    focus: LINES,
    note: "No layout set: rows follow the item switches; Customize starts from them.",
  },
  "by-kind": {
    section: "sidebar",
    focus: LINES,
    note: "By Kind: Agent has its own layout; the other kinds use All Rows.",
    options: {
      values: {
        [LINES]: [
          ["icon", "name"],
          ["directory", "branch"],
        ],
        [BY_KIND]: { agent: [["icon", "name", "working"], ["agentStatus"]] },
      },
    },
    play: tab("By Kind"),
  },
  "by-agent": {
    section: "sidebar",
    focus: LINES,
    note: "By Agent: claude and codex each with a layout, and the Add Agent field.",
    options: {
      values: {
        [BY_AGENT]: {
          claude: [["icon", "name", "working"], ["lastActivity"]],
          codex: [["name", "branch", "progress"]],
        },
      },
    },
    play: tab("By Agent"),
  },
  refused: {
    section: "sidebar",
    focus: LINES,
    note: "A refused write: the last good layout stays; the problem shows on its item and in words.",
    options: {
      values: { [LINES]: [["icon", "name", "branch", "ports"], ["process"]] },
      refusals: {
        [LINES]: {
          message: "sidebar.workspaceRow.lines[0][2]: repeated",
          details: { accepted: { problems: [{ at: "sidebar.workspaceRow.lines[0][2]", why: "repeated" }] } },
        },
      },
    },
    play: async (ctx) => {
      await ctx.click({ selector: '[data-chip="ports"] .row-layout-chip-remove' });
      await ctx.waitFor(() => ctx.document.querySelector(".row-layout-problems"));
    },
  },
  preview: {
    section: "sidebar",
    focus: LINES,
    note: "The preview row: icon, name and line one's items, the working mark and progress bar, three lines.",
    options: {
      values: {
        [LINES]: [
          ["icon", "name", "branch", "ports", "working", "progress"],
          ["directory", "process", "lastActivity"],
          ["agentStatus", "pullRequest"],
        ],
      },
    },
  },
  full: {
    section: "sidebar",
    focus: LINES,
    note: "Three lines, six items on line one: its + and Add Line are off.",
    options: {
      values: {
        [LINES]: [
          ["icon", "name", "directory", "branch", "process", "agentStatus", "tabCount", "ports", "working", "progress"],
          ["lastActivity", "pullRequest"],
          ["notification", "log"],
        ],
      },
    },
  },
};

/** `base` drawn at a page density (appearance.density), so the chips and lines show at both ends. */
const atDensity = (base: SettingsPageVariant, density: "compact" | "comfortable"): SettingsPageVariant => ({
  ...base,
  note: `${base.note} At the ${density} density.`,
  options: { ...base.options, values: { ...base.options?.values, "appearance.density": density } },
});
for (const name of ["all-rows", "by-kind", "refused", "preview"])
  for (const density of ["compact", "comfortable"] as const)
    variants[`${name}-${density}`] = atDensity(variants[name]!, density);

export default settingsPageEntry({
  id: "pages.settings-row-layout",
  title: "Settings row layout",
  area: "Settings",
  height: 760,
  widths: { narrow: 480, normal: 1000, wide: 1440 },
  covers: [
    "pages/settings/editors/RowLayoutEditor.tsx",
    "pages/settings/editors/JsonEditor.tsx",
    "pages/settings/rowLayout.ts",
  ],
  checks: {
    layoutShiftMax: {
      value: 1,
      reason: "The play steps switch a tab or refuse a write, which changes the editor's height on purpose.",
    },
  },
  variants,
});
