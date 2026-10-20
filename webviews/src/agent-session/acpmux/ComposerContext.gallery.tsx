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

/// The New Tab page's saved environments (SavedEnvironmentRows), with `current` picked.
function savedProps(current?: string): ComponentProps<typeof ComposerContext> {
  return {
    ...baseProps,
    environments: true,
    peers: ["gpu-box"],
    peerKinds: { "gpu-box": "ssh" },
    saved: {
      environments: [
        { id: "s1", name: "GPU box training", kind: "ssh", host: "gpu-box", folder: "/home/dev/model", updatedAt: 3 },
        {
          id: "l1",
          name: "Atlas in a worktree",
          kind: "local",
          folder: projects[0]!.cwd,
          worktree: true,
          updatedAt: 2,
        },
      ],
      ...(current ? { current } : {}),
      onPick: () => undefined,
      onClear: () => undefined,
      onCreate: () => undefined,
      onEdit: () => undefined,
    },
  };
}

// Sample favicons (drawn here, public-safe) the host would read from the projects' folders.
const projectIcons = {
  "/Users/you/src/atlas-web":
    "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iNyIgZmlsbD0iIzI1NjNlYiIvPjxjaXJjbGUgY3g9IjE2IiBjeT0iMTYiIHI9IjkiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIyLjUiLz48cGF0aCBkPSJNNyAxNmgxOE0xNiA3Yy00IDUtNCAxMyAwIDE4TTE2IDdjNCA1IDQgMTMgMCAxOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZmZmIiBzdHJva2Utd2lkdGg9IjIiLz48L3N2Zz4=",
  "/Users/you/src/relay":
    "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iNyIgZmlsbD0iI2Y5NzMxNiIvPjxwYXRoIGQ9Ik04IDIwbDgtOSA4IDkiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIzLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjwvc3ZnPg==",
};

const openFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
};

// Leo's list (hq#1957 composer location strip): three checkouts of cmux, each named "cmux".
const worktrees: Project[] = [
  { cwd: "/Users/you/wt/lanes/cg-lane-adopt/cmux", label: "cmux" },
  { cwd: "/Users/you/wt/lanes/fleet-ci/cmux", label: "cmux" },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/you/src/relay", label: "relay" },
];

const worktreeProps = {
  ...baseProps,
  projectChoices: worktrees,
  onNewWorktree: () => undefined,
  summary: { sessionId: "", harness: "claude", cwd: worktrees[0]!.cwd, host: "This Mac", hostKind: "local" as const },
};

const openComputer: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Computer/ });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
};

export default componentEntry<ComponentProps<typeof ComposerContext>>({
  id: "agent-pane.composer-context",
  title: "Composer scope row",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/FolderPopover.tsx#FolderPopover",
    "agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker",
    "agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentIcon",
  ],
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
      note: "The folder popover: a search field over the recent projects (paths on hover), then Add project and Choose folder….",
      props: baseProps,
      play: openFolder,
    },
    "folder-favicons": {
      note: "Projects with a favicon (public/, app/, the folder itself) show it in their tile; cmux has none and keeps its letters.",
      props: baseProps,
      chipHost: { projectIcons },
      play: openFolder,
    },
    "duplicate-worktrees": {
      note: "Three checkouts named cmux: each row adds its lane, the path shows on hover, the current one is checked.",
      props: worktreeProps,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Folder" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
      },
    },
    "duplicate-search": {
      note: "The search field filters by name, lane and path: typing part of a lane leaves its checkout.",
      props: worktreeProps,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Folder" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
        await ctx.type("adopt");
        await ctx.waitFor(
          () => ctx.document.querySelectorAll(".acpmux-location-menu .acpmux-location-row").length === 1,
        );
      },
    },
    "computer-menu": {
      note: "The computer menu keeps local and Cloud destinations together with SSH and cmux Cloud actions.",
      props: baseProps,
      play: openComputer,
    },
    "environment-picker": {
      note: "Preview: the computer is the environment picker, one searchable list in Local, SSH and Cloud sections with ⌥⌘1–9 and New environment last.",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "saved-environments": {
      note: "Preview, New Tab page: the saved environments in a Saved section over the machines, and Create environment under New environment.",
      props: savedProps(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-popover .acpmux-env-saved"));
      },
    },
    "saved-environment-picked": {
      note: "Preview, New Tab page: a picked saved environment names the strip; the folder control steps aside.",
      props: savedProps("l1"),
    },
    "ssh-chat": {
      note: "A chat on an SSH machine names that machine as its Computer, not this Mac (cx-7ooz).",
      props: {
        ...baseProps,
        started: true,
        summary: {
          sessionId: "gallery-ssh",
          harness: "claude",
          model: "claude-opus-5-5",
          cwd: "/home/dev/project",
          host: "gpu-box",
          peer: "gpu-box",
        },
      },
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
