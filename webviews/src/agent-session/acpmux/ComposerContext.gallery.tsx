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
import { fleetPeers } from "../../gallery/fixtures/acpmux";

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

/// 21 machines, as `acpmux host ls` lists them on a Mac with a fleet.
const fleetProps = { ...baseProps, ...fleetPeers() };
/// The account's Cloud machines acpmux does not list (cloudMachines.ts): paused, ready and booting.
const accountMachines = [
  { id: "vm-build", name: "build box", stage: "paused" },
  { id: "vm-eval", name: "eval box", stage: "ready" },
  { id: "vm-fresh", name: "fresh box", stage: "booting" },
];

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

// Austin's list (2026-10-20): cmux's agent worktrees each listed as a project of its own. The host
// reads each folder's repository (`project.list` `repos`), so they fold under one cmux row.
const cmuxRepo = (branch: string) => ({
  root: "/Users/you/src/cmux",
  name: "cmux",
  branch,
  github: "manaflow-ai/cmux",
});
const lane = (name: string): Project => ({
  cwd: `/Users/you/.cmux/worktrees/cmux/${name}`,
  label: name,
  repo: cmuxRepo(name),
});
const repoProjects: Project[] = [
  lane("issue-22273-runaway-children"),
  {
    cwd: "/Users/you/src/atlas-web",
    label: "atlas-web",
    repo: { root: "/Users/you/src/atlas-web", name: "atlas-web", branch: "main" },
  },
  lane("feat-cmux-next-unread-ring-classic"),
  { cwd: "/Users/you/src/cmux", label: "cmux", repo: cmuxRepo("feat-cmux-next") },
  lane("agent-caller-scoped-current-selector"),
  {
    cwd: "/Users/you/src/relay",
    label: "relay",
    repo: { root: "/Users/you/src/relay", name: "relay", branch: "main" },
  },
  lane("agent-21352-sidebar-drag"),
  { cwd: "/Users/you/src/notes", label: "notes" },
];

// Leo's New Tab list on nightly 331e2e9 (2026-10-21): the main clone and the lane mirror's worktrees
// (one GitHub repository, two Git folders), chat folders the host read nothing for, `.noindex` scratch
// and the home folder. It shows cmux once, its clones and lanes as branches, and no scratch.
const leoMirror = (branch: string) => ({
  root: "/Users/you/Projects/.wt-mirrors/manaflow-ai/cmux.git",
  top: `/Users/you/Projects/checkouts/cmux/${branch}`,
  name: "cmux",
  branch,
  github: "manaflow-ai/cmux",
});
const laneCheckouts: Project[] = [
  { cwd: "/Users/you/Projects", label: "Projects" },
  { cwd: "/Users/you/Projects/cmux", label: "cmux", repo: { ...cmuxRepo("main"), root: "/Users/you/Projects/cmux" } },
  {
    cwd: "/Users/you/Projects/checkouts/cmux/lane-host-fg",
    label: "lane-host-fg",
    repo: leoMirror("lane-host-fg"),
  },
  {
    cwd: "/Users/you/Projects/leo-workspace",
    label: "leo-workspace",
    repo: { root: "/Users/you/Projects/leo-workspace", name: "leo-workspace", branch: "main" },
  },
  { cwd: "/Users/you/Projects/checkouts/cmux/queued-agent-from", label: "queued-agent-from" },
  { cwd: "/Users/you/Projects/cmux-live-block.noindex", label: "cmux-live-block.noindex" },
  { cwd: "/Users/you/Projects/cmux-steer-folds.noindex", label: "cmux-steer-folds.noindex" },
  {
    cwd: "/Users/you/Projects/checkouts/cmux/cg-queue--collapsed-queue",
    label: "cg-queue--collapsed-queue",
    repo: leoMirror("cg-queue/collapsed-queue"),
  },
  // The lane mirror itself (a bare repository) and lane folders that are no Git checkout (2026-10-21).
  {
    cwd: "/Users/you/Projects/.wt-mirrors/manaflow-ai/cmux.git",
    label: "cmux.git",
    repo: {
      root: "/Users/you/Projects/.wt-mirrors/manaflow-ai/cmux.git",
      top: "/Users/you/Projects/.wt-mirrors/manaflow-ai/cmux.git",
      name: "cmux",
      github: "manaflow-ai/cmux",
    },
  },
  { cwd: "/Users/you/Projects/leo--ask-cost-dollar", label: "leo--ask-cost-dollar" },
  { cwd: "/Users/you/Projects/codex--protocol-contract-node-version", label: "codex--protocol-contract-node-version" },
  { cwd: "/Users/you", label: "~" },
];

const repoProps = {
  ...baseProps,
  projectChoices: repoProjects,
  onNewWorktree: () => undefined,
  summary: {
    sessionId: "",
    harness: "claude",
    cwd: repoProjects[0]!.cwd,
    host: "This Mac",
    hostKind: "local" as const,
  },
};

// No icon file of their own: cmux draws its GitHub owner's avatar (here a drawn stand-in), atlas-web
// its framework, relay its language, notes (no manifest) a folder.
const ownerAvatar =
  "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iMTYiIGZpbGw9IiMxZjIzMjgiLz48cGF0aCBkPSJNOSAyMlYxMWw3IDcgNy03djExIiBmaWxsPSJub25lIiBzdHJva2U9IiNmZmYiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PC9zdmc+";
const repoHost = {
  projectIcons: Object.fromEntries(
    repoProjects.filter((project) => project.repo?.github).map((project) => [project.cwd, ownerAvatar]),
  ),
  projectGlyphs: { "/Users/you/src/atlas-web": "react", "/Users/you/src/relay": "rust" },
};

// One project per kind the host tells apart (AgentPaneProjectIcon.glyph), and one it cannot.
const frameworkGlyphs = {
  "vite-app": "vite",
  dashboard: "next",
  storefront: "react",
  docs: "astro",
  "admin-panel": "vue",
  "svelte-kit-site": "svelte",
  desktop: "electron",
  "mobile-app": "expo",
  "api-server": "bun",
  engine: "rust",
  "macos-app": "swift",
  "ml-pipeline": "python",
  notes: undefined,
} as const;
const frameworkProjects = Object.keys(frameworkGlyphs).map((label) => ({ cwd: `/Users/you/src/${label}`, label }));
const frameworkProps = {
  ...baseProps,
  projectChoices: frameworkProjects,
};
const frameworkHost = {
  projectIcons: {},
  projectGlyphs: Object.fromEntries(
    Object.entries(frameworkGlyphs).flatMap(([label, glyph]) => (glyph ? [[`/Users/you/src/${label}`, glyph]] : [])),
  ),
};
// Every cmux folder draws manaflow-ai's avatar (the host reads it for a chat folder in a lane checkout
// too); a folder with no repository draws a plain folder.
const laneHost = {
  projectIcons: Object.fromEntries(
    laneCheckouts.flatMap((project) =>
      project.repo?.github || project.cwd.includes("/checkouts/cmux/") ? [[project.cwd, ownerAvatar]] : [],
    ),
  ),
};

const openComputer: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Computer/ });
  await ctx.waitFor(() =>
    ctx.document.querySelector('.acpmux-location-menu [role="option"], [role="menu"] [role="menuitemradio"]'),
  );
};

export default componentEntry<ComponentProps<typeof ComposerContext>>({
  id: "agent-pane.composer-context",
  title: "Composer scope row",
  area: "Agent pane",
  pane: true,
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
      note: "Project actions stay directly below search, above the recent projects (paths on hover).",
      props: baseProps,
      play: openFolder,
    },
    "folder-pinned-search": {
      note: "Typing a project keeps its row active while the actions stay pinned above it.",
      props: {
        ...baseProps,
        onProject: (cwd) => {
          document.documentElement.dataset.galleryProjectPicked = cwd;
        },
        onBrowseProject: () => {
          document.documentElement.dataset.galleryProjectAction = "browse";
        },
        onNoProject: () => {
          document.documentElement.dataset.galleryProjectAction = "none";
        },
      },
      play: openFolder,
    },
    "folder-short-note": {
      note: "A short pane with a private-folder explanation keeps project rows visible.",
      props: {
        ...repoProps,
        summary: { ...repoProps.summary, cwd: "" },
        folderNote: "New chats in this workspace start in a private folder.",
      },
      play: openFolder,
    },
    "folder-short-note-de": {
      note: "A two-line German private-folder explanation in a short pane.",
      props: {
        ...repoProps,
        summary: { ...repoProps.summary, cwd: "" },
        folderNote: "Neue Chats in diesem Arbeitsbereich starten in einem privaten Ordner.",
      },
      play: openFolder,
    },
    "folder-short-note-fr": {
      note: "A two-line French private-folder explanation in a short pane.",
      props: {
        ...repoProps,
        summary: { ...repoProps.summary, cwd: "" },
        folderNote: "Les nouvelles discussions de cet espace de travail démarrent dans un dossier privé.",
      },
      play: openFolder,
    },
    "folder-long-list": {
      note: "Project actions stay below search while a long folder list scrolls; the thumb stays inside the right edge.",
      props: {
        ...baseProps,
        projectChoices: Array.from({ length: 40 }, (_, index) => ({
          cwd: `/demo/review-${index + 1}`,
          label: `review-${index + 1}`,
        })),
        onNoProject: () => undefined,
      },
      play: openFolder,
    },
    "folder-favicons": {
      note: "Projects with a favicon (public/, app/, the folder itself) show it in their tile; cmux has none and draws a plain folder.",
      props: baseProps,
      chipHost: { projectIcons },
      play: openFolder,
    },
    "framework-marks": {
      note: "With no favicon, each project shows its framework or language (from package.json dependencies, Package.swift, Cargo.toml…) in its brand color; a folder with no manifest shows a folder.",
      props: frameworkProps,
      chipHost: frameworkHost,
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
    "repo-worktrees": {
      note: "Worktrees fold under their repository: one cmux row (the current worktree's branch dimmed, its other worktrees counted), avatars and framework glyphs, else a plain folder.",
      props: repoProps,
      chipHost: repoHost,
      play: openFolder,
    },
    "repo-worktrees-open": {
      note: "→ (or the count) opens a repository's other worktrees under its row, newest first, each by its branch.",
      props: repoProps,
      chipHost: repoHost,
      play: async (ctx) => {
        await openFolder(ctx);
        await ctx.press("ArrowDown");
        await ctx.press("ArrowRight");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-row[data-worktree]"));
      },
    },
    "repo-worktrees-search": {
      note: "A search by branch lists the worktree it names under its repository; typing the repository's name lists it once.",
      props: repoProps,
      chipHost: repoHost,
      play: async (ctx) => {
        await openFolder(ctx);
        await ctx.type("unread");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-row[data-worktree]"));
      },
    },
    "lane-checkouts": {
      note: "Leo's New Tab list: the main clone, the lane mirror and its worktrees are one cmux row with manaflow-ai's avatar; chat folders join it by their lane path; .noindex scratch, lane folders and the home folder are left out; no letter tiles and no corner dots.",
      chipHost: laneHost,
      props: {
        ...repoProps,
        projectChoices: laneCheckouts,
        summary: { ...repoProps.summary, cwd: "/Users/you/Projects" },
      },
      play: openFolder,
    },
    "lane-checkouts-open": {
      note: "The cmux row's clones and lane checkouts open under it by their branch.",
      chipHost: laneHost,
      props: {
        ...repoProps,
        projectChoices: laneCheckouts,
        summary: { ...repoProps.summary, cwd: "/Users/you/Projects" },
      },
      play: async (ctx) => {
        await openFolder(ctx);
        // Projects (current) is the first row, cmux the second.
        await ctx.press("ArrowDown");
        await ctx.press("ArrowDown");
        await ctx.press("ArrowRight");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-row[data-worktree]"));
      },
    },
    "repo-worktrees-guessed": {
      note: "An older host sends no repositories: worktrees under ~/.cmux/worktrees/<repo>/ still fold under that repository by their path.",
      props: {
        ...repoProps,
        projectChoices: repoProjects.map(({ repo: _repo, ...project }) => project),
      },
      play: openFolder,
    },
    "computer-menu": {
      note: "The computer menu keeps local and Cloud destinations together with SSH and cmux Cloud actions.",
      props: baseProps,
      play: openComputer,
    },
    "computer-search": {
      note: "The classic machine picker uses the same searchable Combobox as environments and folders; filtering twenty machines leaves gpu-box.",
      props: { ...baseProps, peers: ["gpu-box", ...Array.from({ length: 20 }, (_, i) => `build-${i + 1}`)] },
      play: async (ctx) => {
        await openComputer(ctx);
        await ctx.focus({ role: "combobox", name: "Computer" });
        await ctx.type("gpu");
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="option"]').length === 1);
      },
    },
    "environment-picker": {
      note: "Preview: the computer is the environment picker, one searchable list in Local, SSH and Cloud sections with ⌥⌘1–9; New Cloud Machine ends the Cloud section and New environment (SSH…, Connect Phone…) comes last. gpu-box is connected (a filled dot), Cloud machine is not (a ring); this Mac has no status.",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "environment-picker-sandboxed-option": {
      note: "Labs (hq#3367): Sandboxed is New Cloud Machine's other face, with no row of its own. Holding ⌥ while the list is open shows it, as a Mac menu's alternate: a pick runs the new chat's first message once on a throwaway Cloud VM.",
      props: { ...baseProps, environments: true, runMode: { mode: "persistent", onMode: () => undefined } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
        ctx.document.defaultView?.dispatchEvent(new KeyboardEvent("keydown", { key: "Alt", altKey: true }));
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="sandboxed"]'));
      },
    },
    "environment-picker-sandboxed-search": {
      note: "Labs (hq#3367): searching for it shows Sandboxed in New Cloud Machine's place.",
      props: { ...baseProps, environments: true, runMode: { mode: "persistent", onMode: () => undefined } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
        await ctx.type("sandbox");
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="sandboxed"]'));
      },
    },
    "environment-picker-sandboxed-picked": {
      note: "Labs (hq#3367): Sandboxed picked. The control names it where the machine was, and its row stays checked in New Cloud Machine's place; any machine goes back to a Persistent chat.",
      props: { ...baseProps, environments: true, runMode: { mode: "sandboxed", onMode: () => undefined } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="sandboxed"]'));
      },
    },
    "environment-picker-cloud-machines": {
      note: "Preview: the environment picker above, then the account's Cloud machines acpmux does not list (`cloudMachine.list`) in Cloud and VMs, each with its stage: build box is paused (a pick resumes it), eval box is ready (a pick opens it), fresh box is still booting. They take no ⌥⌘ digit and are not greyed.",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
        cloudMachines: accountMachines,
        onCloudMachine: () => undefined,
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "computer-menu-cloud-machines": {
      note: "Previews off: the plain Computer menu lists the account's Cloud machines acpmux does not list the same way, with their stage on the second line.",
      props: { ...baseProps, cloudMachines: accountMachines, onCloudMachine: () => undefined },
      play: openComputer,
    },
    "environment-picker-fleet": {
      height: 760,
      note: "Preview: every machine acpmux lists (21, from `host ls`), in This Mac, My machines and Cloud and VMs sections; in each the machines a chat can start on come first, in number order, and the rest are greyed with their state (Offline, Reconnecting, Connecting) and are no pick.",
      props: { ...fleetProps, environments: true },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-env-popover [role="option"]').length > 20);
      },
    },
    "computer-menu-fleet": {
      height: 760,
      note: "Previews off: the plain Computer menu lists the same 21 machines in the same sections, greyed the same way.",
      props: fleetProps,
      play: async (ctx) => {
        await openComputer(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="option"]').length > 20);
      },
    },
    "machine-colors": {
      note: "Another machine keeps one color from its name (machineColor) in the list, so two SSH machines and a Cloud machine tell apart at a glance; this Mac stays quiet.",
      props: {
        ...baseProps,
        environments: true,
        localName: "office-mac",
        peers: ["gpu-box", "build-mini", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "build-mini": "ssh", "Cloud machine": "cloud" },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "environment-picker-no-cloud": {
      note: "Preview: with no cloud machine yet, New Cloud Machine heads its own Cloud section with what one gives.",
      props: {
        ...baseProps,
        environments: true,
        sessions: sessions.filter((session) => session.hostKind !== "cloud"),
        peers: ["gpu-box"],
        peerKinds: { "gpu-box": "ssh" },
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
    "started-move-to-cloud": {
      note: "Preview, a started chat on this Mac: the picker shows where it runs and Move to Cloud, the tab menu's same action, saying it reuses a Cloud machine or makes one.",
      props: {
        ...baseProps,
        environments: true,
        started: true,
        onOffload: () => undefined,
        offloads: ["move"],
        summary: {
          sessionId: "gallery-started-local",
          harness: "claude",
          cwd: projects[0]!.cwd,
          host: "This Mac",
          hostKind: "local",
        },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-popover .acpmux-env-new"));
      },
    },
    "started-bring-back": {
      note: "Preview, a started Cloud chat a move from this Mac put there: the picker shows its machine and Bring Back Local, which merges the machine's changes into the folder here.",
      props: {
        ...baseProps,
        environments: true,
        started: true,
        onOffload: () => undefined,
        offloads: ["bringBack"],
        summary: {
          sessionId: "gallery-started-cloud",
          harness: "claude",
          cwd: "/home/you/project",
          host: "Cloud machine",
          hostKind: "cloud",
        },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-popover .acpmux-env-new"));
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
