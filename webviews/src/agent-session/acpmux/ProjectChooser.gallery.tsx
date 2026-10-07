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
};

const noMatches: Play = async (ctx) => {
  await open(ctx);
  await ctx.type("nothing-matches");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-empty"));
};

const typedPath: Play = async (ctx) => {
  await open(ctx);
  await ctx.type("/tmp/new-project");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-menu-active"));
};

export default componentEntry<Props>({
  id: "agent-pane.project-chooser",
  title: "Project chooser",
  area: "Agent pane",
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
        onPick: () => undefined,
        onBrowse: () => undefined,
      },
      play: open,
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
