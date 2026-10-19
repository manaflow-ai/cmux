// l10n-allow-file: gallery prototype fixtures, not shipped UI.
// Sidebar hierarchy of agents and subagents (Lawrence 2026-10-19): six layouts of one session
// family, on the Mac and the iPhone. Toggle the platform, the number of children, the depth, the
// visible columns, the grouping, and the limit panel and settings in the header.
import { componentEntry } from "../../gallery/format";
import type { SubagentSidebarProps } from "./SubagentSidebar";

const PLATFORM = {
  id: "platform",
  label: "Frame",
  kind: "choice",
  choices: [
    { value: "mac", label: "Mac" },
    { value: "iphone", label: "iPhone" },
  ],
  defaultValue: "mac",
} as const;

export default componentEntry<SubagentSidebarProps>({
  id: "subagents.sidebar-hierarchy",
  title: "Subagents: sidebar hierarchy",
  area: "Subagent books",
  keywords: ["miller", "columns", "tree", "nested", "children", "limits", "width", "depth", "sidebar", "ios", "mac"],
  covers: [
    "prototypes/subagents/SubagentSidebar.tsx",
    "prototypes/subagents/views.tsx",
    "prototypes/subagents/limits.tsx",
    "prototypes/subagents/parts.tsx",
  ],
  load: () => import("./SubagentSidebar").then((module) => module.SubagentSidebar),
  height: 920,
  widths: { narrow: 440, normal: 1280, wide: 1600 },
  options: [
    PLATFORM,
    { id: "fanout", label: "Children", kind: "choice", choices: ["5", "12", "50", "80"], defaultValue: "12", numeric: true },
    { id: "depth", label: "Depth", kind: "choice", choices: ["1", "2", "4", "10", "12"], defaultValue: "4", numeric: true },
    { id: "visibleColumns", label: "Columns", kind: "choice", choices: ["2", "3", "4"], defaultValue: "3", numeric: true },
    {
      id: "groupBy",
      label: "Group by",
      kind: "choice",
      choices: [
        { value: "status", label: "Status" },
        { value: "task", label: "Task" },
        { value: "harness", label: "Harness" },
      ],
      defaultValue: "status",
    },
    { id: "limitsOpen", label: "Limits panel", kind: "toggle", defaultValue: false },
    { id: "settings", label: "Settings (defaults)", kind: "toggle", defaultValue: false },
  ],
  variants: {
    columns: {
      note: "Miller columns: one column per level; older levels fold into strips (the columns exception).",
      props: { platform: "mac", layout: "columns", fanout: 12, depth: 4 },
    },
    "columns-deep": {
      note: "Ten levels: only the newest three show in full.",
      props: { platform: "mac", layout: "columns", fanout: 12, depth: 10, focusDepth: 10 },
    },
    tree: {
      note: "Indented tree; the running path opens; 8 children per level, then Show more.",
      props: { platform: "mac", layout: "tree", fanout: 12, depth: 4 },
    },
    "tree-deep": {
      note: "Past level 6 the indent stops and the level is written (L7).",
      props: { platform: "mac", layout: "tree", fanout: 12, depth: 10, focusDepth: 10 },
    },
    "grouped-status": {
      note: "The whole family flat, by status; Done folds by default.",
      props: { platform: "mac", layout: "grouped", groupBy: "status", fanout: 12, depth: 4 },
    },
    "grouped-task": { note: "By task kind.", props: { platform: "mac", layout: "grouped", groupBy: "task", fanout: 12, depth: 4 } },
    "grouped-harness": {
      note: "By harness.",
      props: { platform: "mac", layout: "grouped", groupBy: "harness", fanout: 12, depth: 4 },
    },
    lanes: {
      note: "Original: a timeline lane per agent; who ran when, at a glance.",
      props: { platform: "mac", layout: "lanes", fanout: 12, depth: 4 },
    },
    stack: {
      note: "Original: one level at a time with a breadcrumb (the iPhone's natural form).",
      props: { platform: "mac", layout: "stack", fanout: 12, depth: 4 },
    },
    digest: {
      note: "Original: attention first; each session folds into counts, only what needs you shows.",
      props: { platform: "mac", layout: "digest", fanout: 12, depth: 4 },
    },
    "at-width-limit": {
      note: "80 asked, limit 50: 30 wait for a slot; the limit panel is open.",
      props: { platform: "mac", layout: "columns", fanout: 80, depth: 3, limitsOpen: true },
    },
    "at-depth-limit": {
      note: "The family wants 12 levels; the session allows 10.",
      props: { platform: "mac", layout: "tree", fanout: 5, depth: 12, focusDepth: 12 },
    },
    "settings-defaults": {
      note: "Settings › Agents › Subagents: the defaults for new sessions.",
      props: { platform: "mac", layout: "tree", fanout: 12, depth: 4, settings: true },
    },
  },
});
