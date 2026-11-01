// l10n-allow-file: gallery fixtures (sample projects), not shipped UI.
import { createElement } from "react";
import type { ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { Project } from "./ProjectChooser";

type Props = {
  projects: Project[];
  current?: string;
  currentLabel?: string;
  icon: ReactNode;
  onPick(cwd: string): void;
  onBrowse?(): void;
  onNoProject?(): void;
  noProject?: boolean;
  side?: "top" | "bottom";
  inline?: boolean;
};

const icon = createElement(
  "svg",
  {
    className: "acpmux-icon",
    width: 14,
    height: 14,
    viewBox: "0 0 16 16",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.25,
    "aria-hidden": true,
  },
  createElement("path", { d: "M2 4.5h4l1.4 1.6H14v6.4H2z" }),
);

const projects: Project[] = [
  { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/src/relay", label: "relay" },
];

// A folder the host names by its path (a home folder has no project name), then a named project.
const pathTitled: Project[] = [
  { cwd: "/Users/sample", label: "/Users/sample" },
  { cwd: "/Users/sample/projects/atlas-web", label: "atlas-web" },
];

// The new chat's hero picker (EmptyState: inline, opening below the question) in no project, over
// projects whose folders have app icons (Leo, "why is this all misaligned in the agent chat project
// selectin"): the glyphs of Do not work in a project and New project, and each app icon, sit in one
// icon column, with every title on one text inset.
const appIcon = (fill: string, mark: string) =>
  "data:image/svg+xml;base64," +
  btoa(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".28"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient></defs><rect width="64" height="64" rx="14" fill="${fill}"/><rect width="64" height="64" rx="14" fill="url(#g)"/>${mark}</svg>`,
  );
const appProjects: Project[] = [
  { cwd: "/Users/sample/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/sample/src/relay", label: "relay" },
  { cwd: "/Users/sample/Projects", label: "Projects" },
];
const appIcons = {
  "/Users/sample/src/atlas-web": appIcon(
    "#2563eb",
    '<circle cx="32" cy="32" r="17" fill="none" stroke="#fff" stroke-width="5"/><path d="M15 32h34M32 15c-8 10-8 24 0 34M32 15c8 10 8 24 0 34" fill="none" stroke="#fff" stroke-width="4"/>',
  ),
  "/Users/sample/src/relay": appIcon(
    "#f97316",
    '<path d="M16 40l16-18 16 18" fill="none" stroke="#fff" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>',
  ),
  "/Users/sample/Projects": appIcon("#111827", '<rect x="17" y="17" width="30" height="30" rx="7" fill="#22c55e"/>'),
};
const hero = { icon, side: "bottom", inline: true, onPick: () => undefined, onBrowse: () => undefined } as const;

// Two lanes' worktrees of cmux (`wt/lanes/<lane>/cmux`, folders the host read no repository for)
// beside cmux's own checkout: one cmux row, and a search that names a lane finds its worktree.
const cmuxRepo = { root: "/Users/sample/Projects/cmux", name: "cmux", branch: "main", github: "sample/cmux" };
const laneProjects: Project[] = [
  { cwd: "/Users/sample/wt/lanes/lane-adopt/cmux", label: "cmux" },
  { cwd: "/Users/sample/wt/lanes/next-reds/cmux", label: "cmux" },
  { cwd: "/Users/sample/Projects/cmux", label: "cmux", repo: cmuxRepo },
  { cwd: "/Users/sample/Projects", label: "Projects" },
];

const longProjects: Project[] = [
  {
    cwd: "/Users/you/Projects/very-long-folder-name-that-must-remain-readable/atlas-web",
    label: "very-long-folder-name-that-must-remain-readable",
  },
  {
    cwd: "/Users/you/Projects/another-really-long-project-name-with-a-path/relay-tools",
    label: "another-really-long-project-name-with-a-path",
  },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
];

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-project-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
  const field = ctx.document.querySelector<HTMLInputElement>('[role="combobox"]')!;
  const menu = ctx.document.querySelector<HTMLElement>(".acpmux-project-menu")!;
  const width = field.getBoundingClientRect().width;
  if (width < menu.clientWidth - 24)
    throw new Error("Project search must fill the menu width, not render as a native short input");
  if (ctx.document.defaultView!.getComputedStyle(field).borderLeftWidth !== "0px")
    throw new Error("Project search must keep the composer field style without a native border");
};

// The macOS menu gesture: press the pill, drag onto a row, release to pick it.
const pressDragRelease: Play = async (ctx) => {
  await ctx.pointer.down({ selector: ".acpmux-project-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
  await ctx.pointer.move({ selector: '[role="option"][aria-label^="relay"]' });
  await ctx.pointer.up({ selector: '[role="option"][aria-label^="relay"]' });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]'));
};

const noMatches: Play = async (ctx) => {
  await open(ctx);
  await ctx.type("nothing-matches");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-empty"));
};

const typedPath: Play = async (ctx) => {
  await open(ctx);
  await ctx.type("/tmp/new-project");
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-menu-active, [role="option"][data-highlighted]'));
};

export default componentEntry<Props>({
  id: "agent-pane.project-chooser",
  title: "Project chooser",
  area: "Agent pane",
  // Its rows use the pane's Tailwind (`data-[highlighted]:bg-hover`), which only a pane entry loads.
  pane: true,
  covers: ["agent-session/acpmux/ProjectChooser.tsx#ProjectChooser"],
  load: () => import("./ProjectChooser").then((module) => module.ProjectChooser),
  styles: () => import("./styles.css"),
  widths: { narrow: 320, normal: 420, wide: 560 },
  height: 300,
  anchors: [{ selector: ".acpmux-project-button" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening and filtering the chooser uses a portal and must not move the composer anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Project filtering and the empty state stay inside the chooser without reflowing the page.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Chooser opening and filtering must remain responsive on the gallery host.",
    },
  },
  variants: {
    closed: {
      note: "The current project is visible on the trigger; its row is checked when the chooser opens.",
      props: { projects, current: projects[0]!.cwd, currentLabel: projects[0]!.label, icon, onPick: () => undefined },
    },
    "open-current": {
      note: "The current project stays checked while the project menu is open.",
      props: {
        projects,
        current: projects[0]!.cwd,
        currentLabel: projects[0]!.label,
        icon,
        onPick: (cwd) => {
          document.documentElement.dataset.galleryProjectPicked = cwd;
        },
        onBrowse: () => {
          document.documentElement.dataset.galleryProjectAction = "browse";
        },
        onNoProject: () => {
          document.documentElement.dataset.galleryProjectAction = "none";
        },
      },
      play: open,
    },
    "open-path-titled": {
      note: 'A folder titled by its own path (Leo, ":( alignemnt"): Do not work in a project, New project and the folder share one icon column and one text inset, the folder shows its path once, and a hairline splits the actions from the folders.',
      props: {
        projects: pathTitled,
        current: pathTitled[0]!.cwd,
        currentLabel: pathTitled[0]!.label,
        icon,
        onPick: () => undefined,
        onBrowse: () => undefined,
        onNoProject: () => undefined,
      },
      play: open,
    },
    "open-app-icons": {
      note: 'The new chat\'s hero picker in no project (Leo, "why is this all misaligned in the agent chat project selectin"): Do not work in a project (checked), New project and three projects with app icons share one 16px icon column and one text inset.',
      props: { ...hero, projects: appProjects, noProject: true, onNoProject: () => undefined },
      chipHost: { projectIcons: appIcons },
      play: open,
    },
    "lane-worktrees": {
      note: "Two lanes' worktrees of cmux (wt/lanes/<lane>/cmux) and cmux's own checkout list as one cmux row; no lane is a project of its own.",
      props: { ...hero, projects: laneProjects, noProject: true, onNoProject: () => undefined },
      play: open,
    },
    "lane-worktrees-search": {
      note: "A search that names a lane (next-reds) finds its worktree, with its path under the name.",
      props: { ...hero, projects: laneProjects, noProject: true, onNoProject: () => undefined },
      play: async (ctx) => {
        await open(ctx);
        await ctx.type("next-reds");
        await ctx.waitFor(() =>
          ctx.document.querySelector('[role="option"] [data-path="/Users/sample/wt/lanes/next-reds/cmux"]'),
        );
      },
    },
    "press-drag-release": {
      note: "Pressing the pill opens the chooser; dragging onto a project and releasing picks it and closes.",
      props: { projects, current: projects[0]!.cwd, currentLabel: projects[0]!.label, icon, onPick: () => undefined },
      play: pressDragRelease,
    },
    "remote-completion": {
      note: "The shared combobox completes readable project, host and path text; same-path projects stay on the machine selected by the filter.",
      props: {
        projects: [
          { cwd: "/home/you/src/atlas-web", label: "atlas-web", host: "This Mac" },
          { cwd: "/home/you/src/atlas-web", label: "atlas-web", host: "gpu-box", peer: "gpu-box" },
        ],
        icon,
        onPick: () => undefined,
      },
      play: async (ctx) => {
        await open(ctx);
        await ctx.type("gpu");
        await ctx.press("Tab");
        await ctx.waitFor(() =>
          ctx.document.querySelector<HTMLInputElement>('[role="combobox"]')?.value.includes("/home/you/src/atlas-web"),
        );
      },
    },
    "no-matches": {
      note: "A query with no results shows the quiet empty state without changing the anchor.",
      props: { projects, current: projects[0]!.cwd, currentLabel: projects[0]!.label, icon, onPick: () => undefined },
      play: noMatches,
    },
    "typed-path": {
      note: "An absolute path query offers the typed path as a selectable project.",
      props: { projects, current: projects[0]!.cwd, currentLabel: projects[0]!.label, icon, onPick: () => undefined },
      play: typedPath,
    },
    "long-no-actions": {
      note: "A long recent-project list without action rows still scrolls to its last folder.",
      props: {
        projects: Array.from({ length: 40 }, (_, index) => ({
          cwd: `/demo/review-${index + 1}`,
          label: `review-${index + 1}`,
        })),
        icon,
        onPick: () => undefined,
      },
      play: open,
    },
    "long-names": {
      note: "Long project labels and paths truncate inside stable rows while badges remain visible.",
      props: {
        projects: longProjects,
        current: longProjects[0]!.cwd,
        currentLabel: longProjects[0]!.label,
        icon,
        onPick: () => undefined,
        onBrowse: () => undefined,
      },
      play: open,
    },
  },
});
