// l10n-allow-file: gallery fixtures (sample projects), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ProjectDirectoryHost } from "./projectDirectory";

const tree = new Map<string, { path: string; parent: string | null; home: string; directories: string[] }>([
  [
    "~",
    {
      path: "/Users/you",
      parent: null,
      home: "/Users/you",
      directories: ["/Users/you/Projects", "/Users/you/src"],
    },
  ],
  [
    "/Users/you/Projects",
    {
      path: "/Users/you/Projects",
      parent: "/Users/you",
      home: "/Users/you",
      directories: ["/Users/you/Projects/atlas-web", "/Users/you/Projects/cmux"],
    },
  ],
  [
    "/Users/you/src",
    {
      path: "/Users/you/src",
      parent: "/Users/you",
      home: "/Users/you",
      directories: ["/Users/you/src/relay"],
    },
  ],
  [
    "/Users/you/Projects/atlas-web",
    {
      path: "/Users/you/Projects/atlas-web",
      parent: "/Users/you/Projects",
      home: "/Users/you",
      directories: [],
    },
  ],
  [
    "/Users/you/Projects/cmux",
    {
      path: "/Users/you/Projects/cmux",
      parent: "/Users/you/Projects",
      home: "/Users/you",
      directories: [],
    },
  ],
  [
    "/Users/you/src/relay",
    { path: "/Users/you/src/relay", parent: "/Users/you/src", home: "/Users/you", directories: [] },
  ],
]);

const host: ProjectDirectoryHost = {
  list: async (path) => tree.get(path) ?? tree.get("~")!,
  reveal: async () => undefined,
};

const base = {
  host,
  localName: "This Mac",
  peers: ["big-red", "Office Mac"],
  onPick: () => undefined,
  onClose: () => undefined,
};

const toSources: Play = async (ctx) => {
  await ctx.click({ text: "This Mac" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-add-project-step="source"]'));
};

const toDirectory: Play = async (ctx) => {
  await toSources(ctx);
  await ctx.click({ text: "Local folder" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-add-project-step="directory"]'));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-add-project-item"));
};

const keyboardBrowse: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-add-project-input" });
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[data-add-project-step="source"]'));
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[data-add-project-step="directory"]'));
};

export default componentEntry({
  id: "agent-pane.add-project-panel",
  title: "Add project panel",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/AddProjectPanel.tsx#AddProjectPanel",
    "agent-session/acpmux/AddProjectPanel.tsx#AddProjectDialog",
  ],
  load: () => import("./AddProjectPanel").then((module) => module.AddProjectPanel),
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 440, wide: 560 },
  height: 410,
  anchors: [{ selector: ".acpmux-add-project" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The command panel keeps its frame while the step changes." },
    layoutShiftMax: {
      value: 0,
      reason: "Environment, source and directory rows stay inside a fixed panel.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Keyboard navigation changes only the mounted list rows.",
    },
  },
  variants: {
    environment: { note: "Choose an environment before selecting a project source.", props: base },
    sources: {
      note: "The source step keeps unsupported providers visible with quiet setup-required tags.",
      props: base,
      play: toSources,
    },
    directory: {
      note: "The local folder source becomes an in-pane directory browser with a stable footer.",
      props: base,
      play: toDirectory,
    },
    keyboard: {
      note: "Arrow keys and Enter move through the command panel without stacked dialogs.",
      props: base,
      play: keyboardBrowse,
    },
  },
});
