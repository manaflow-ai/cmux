// l10n-allow-file: gallery fixtures (sample folders and machines), not shipped UI.
//
// The unified composer puts the project and computer controls in the attached scope row. Keep a
// component-level specimen for the row itself so Lawrence's gallery can inspect the real menus at
// the narrow dock width, without having to infer their states from a full transcript.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ComponentProps } from "react";
import type { AcpmuxSnapshot } from "./model";
import { ComposerContext } from "./ComposerContext";
import type { Project } from "./ProjectChooser";

const projects: Project[] = [
  { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/src/relay", label: "relay" },
];

const sessions: AcpmuxSnapshot["sessions"] = [
  {
    sessionId: "gallery-atlas",
    displayTitle: "Fix the checkout page",
    cwd: projects[0]!.cwd,
    host: "This Mac",
    hostKind: "local",
    updatedAt: 0,
  },
  {
    sessionId: "gallery-cloud",
    displayTitle: "Investigate the build cache",
    cwd: "/home/you/src/cmux",
    host: "Cloud machine",
    hostKind: "cloud",
    peer: "Cloud machine",
    updatedAt: 0,
  },
];

const baseProps = {
  sessions,
  peers: ["Cloud machine"],
  projectChoices: projects,
  localName: "This Mac",
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onConnect: () => undefined,
};

const openFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
};

const openComputer: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Computer" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
};

export default componentEntry<ComponentProps<typeof ComposerContext>>({
  id: "agent-pane.composer-context",
  title: "Composer scope row",
  area: "Agent pane",
  covers: ["agent-session/acpmux/ComposerContext.tsx#ComposerContext"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 180,
  anchors: [{ selector: ".acpmux-composer-context" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening a scope menu uses a portal and must leave the attached composer row in place.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Folder and computer choices stay inside the menu without changing the row geometry.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Scope menu opening and keyboard traversal must remain responsive on the gallery host.",
    },
  },
  variants: {
    closed: {
      note: "The composer scope row keeps folder and computer readable as quiet text controls.",
      props: baseProps,
    },
    "folder-menu": {
      note: "The folder menu shows recent projects with paths and keeps the row anchored below the composer.",
      props: baseProps,
      play: openFolder,
    },
    "computer-menu": {
      note: "The computer menu keeps local and Cloud destinations together with SSH and cmux Cloud actions.",
      props: baseProps,
      play: openComputer,
    },
    "started-branch": {
      note: "After a turn starts, location labels lock while the branch remains visible at the right.",
      props: {
        ...baseProps,
        started: true,
        summary: {
          sessionId: "gallery-started",
          harness: "claude",
          model: "claude-opus-5-5",
          cwd: projects[0]!.cwd,
          host: "This Mac",
          hostKind: "local",
          branch: "feature/composer-context-gallery",
        },
      },
    },
  },
});
