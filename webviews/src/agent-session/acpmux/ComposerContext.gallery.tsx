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
import { thisMacName } from "./environments";

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
const folderMenuProps = {
  ...baseProps,
  summary: {
    sessionId: "gallery-folder",
    harness: "claude",
    cwd: projects[1]!.cwd,
    host: "This Mac",
    hostKind: "local" as const,
  },
};
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
        {
          id: "s1",
          name: "GPU box training",
          kind: "ssh",
          host: "gpu-box",
          folder: "/home/dev/model",
          updatedAt: 3,
        },
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

/// A new chat on `machine` with `folders` added beside its own (ComposerContext `extraFolders`).
function extraProps(
  machine: string,
  folders: string[],
  extra: Partial<ComponentProps<typeof ComposerContext>> = {},
): ComponentProps<typeof ComposerContext> {
  return {
    ...baseProps,
    onNoProject: () => undefined,
    ...extra,
    extraFolders: {
      draft: { machine, folders },
      onChange: () => undefined,
      ...(machine === "local" ? { onBrowse: () => undefined } : {}),
    },
  };
}

const openFolderMenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Folder/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-extra-folders"));
};

const openFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
};

// Leo's list (hq#1957 composer location strip): three checkouts of cmux, each named "cmux", in no
// worktree home the pickers know (a lane's own `wt/lanes/<lane>/cmux` folds under cmux instead:
// projectRepos.ts), so each keeps its row and is named apart.
const worktrees: Project[] = [
  { cwd: "/Users/you/clones/cg-lane-adopt/cmux", label: "cmux" },
  { cwd: "/Users/you/clones/fleet-ci/cmux", label: "cmux" },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/you/src/relay", label: "relay" },
];

const worktreeProps = {
  ...baseProps,
  projectChoices: worktrees,
  onNewWorktree: () => undefined,
  summary: {
    sessionId: "",
    harness: "claude",
    cwd: worktrees[0]!.cwd,
    host: "This Mac",
    hostKind: "local" as const,
  },
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
  {
    cwd: "/Users/you/Projects/cmux",
    label: "cmux",
    repo: { ...cmuxRepo("main"), root: "/Users/you/Projects/cmux" },
  },
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
  {
    cwd: "/Users/you/Projects/codex--protocol-contract-node-version",
    label: "codex--protocol-contract-node-version",
  },
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
const frameworkProjects = Object.keys(frameworkGlyphs).map((label) => ({
  cwd: `/Users/you/src/${label}`,
  label,
}));
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

const openEnvironment: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
};

// Menu-grid experiment arms for the custom environment picker. The shared arm is the shipped
// choice; the other two keep the old and an over-tight inset visible for side-by-side captures.
const applyMenuGridArm = (ctx: Parameters<Play>[0], arm: "legacy" | "shared" | "compact") => {
  const style = ctx.document.createElement("style");
  const inset =
    arm === "shared"
      ? "calc(var(--cmux-menu-icon-x) - var(--ui-popup-padding))"
      : arm === "compact"
        ? "var(--cmux-menu-highlight-inset)"
        : "var(--ui-row-padding-inline)";
  const gap = arm === "compact" ? "4px" : arm === "shared" ? "var(--cmux-menu-icon-gap)" : "8px";
  const headingInset =
    arm === "shared"
      ? "calc(var(--cmux-menu-icon-x) - var(--ui-popup-padding))"
      : arm === "compact"
        ? "var(--cmux-menu-highlight-inset)"
        : "8px";
  style.dataset.galleryMenuGridArm = arm;
  style.textContent = `
    .acpmux-location-menu .acpmux-menu-item { padding-inline: ${inset}; }
    .acpmux-location-menu .acpmux-location-row { gap: ${gap}; }
    .acpmux-location-menu .acpmux-location-name[data-section]::before { left: ${headingInset}; }
  `;
  ctx.document.head.append(style);
};

const openEnvironmentWithInsetArm =
  (arm: "legacy" | "shared" | "compact"): Play =>
  async (ctx) => {
    await openEnvironment(ctx);
    applyMenuGridArm(ctx, arm);
  };

/// The environment control's machine list: Machines… on its right-click menu (its main list is This
/// Mac and Cloud, Leo 2026-10-31: "it's just a cloud button").
const openMachineList: Play = async (ctx) => {
  await ctx.contextMenu({ role: "button", name: /^Environment/ });
  await ctx.click({ role: "menuitem", name: "Machines…" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover.acpmux-env-machines [role="option"]'));
};

// The strip's layouts (ComposerContext `stripLayout`), Leo 2026-11-03 on Codex desktop's strip:
// "chatgpt codex has nicer ways to deal with stuff". Each arm draws the same machines: two of the
// person's SSH machines (connected), a Cloud machine that is not, and Cloud work mode.
const stripMachines = {
  ...baseProps,
  environments: true,
  localName: "studio-mac",
  sessions: sessions.filter((session) => session.hostKind !== "cloud"),
  peers: ["studio-mini", "gpu-box", "Cloud machine"],
  peerKinds: { "studio-mini": "ssh", "gpu-box": "ssh", "Cloud machine": "cloud" } as Record<string, "ssh" | "cloud">,
  peerConnected: { "studio-mini": true, "gpu-box": true, "Cloud machine": false },
  // Signed in, so Where shows its three rows (signed out, Sign in for Cloud takes Cloud's place).
  cloudSignedIn: true,
  runMode: { mode: "persistent" as const, onMode: () => undefined },
};
const onMachine = (peer: string) => ({
  summary: { sessionId: "", harness: "claude", host: peer, peer },
});
const waitRows =
  (rows: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(`.acpmux-env-popover.acpmux-env-rows-${rows} [role="option"]`));
  };
const openWhere: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await waitRows("where")(ctx);
};
const openMachineChip: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Machine/ });
  await waitRows("machines")(ctx);
};
const openMachineControl: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await waitRows("machines")(ctx);
};
/// The combined arm's one control: This Mac and Cloud.
const openCombined: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await waitRows("combined")(ctx);
};
const openRunToggle: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Where should this chat run/ });
  await waitRows("run")(ctx);
};
/// Where > Another machine: the first ready machine is the pick and the machine control opens.
const pickAnother: Play = async (ctx) => {
  await openWhere(ctx);
  await ctx.click({ selector: '.acpmux-env-popover [data-action="another"]' });
  await waitRows("machines")(ctx);
};
type StripArm = "where-machine" | "where-machine-always" | "cloud-toggle" | "combined";
const STRIP_NOTES: Record<StripArm, string> = {
  "where-machine":
    "Arm 1 of 4, shipped (Codex desktop's strip): Project | Where | Machine, three single-purpose chips. The machine chip shows only while the pick is another machine.",
  "where-machine-always":
    "Arm 2 of 4: the same three chips, the machine chip always shown (this Mac's own name and its live dot).",
  "cloud-toggle":
    'Arm 3 of 4 (ChatGPT Work): Project | Machine, and a cloud toggle at the strip\'s end whose menu asks "Where should this chat run?".',
  combined:
    "Arm 4 of 4, the baseline before this: one control, This Mac and Cloud, the machines behind its right-click Machines….",
};
/// ChatGPT Work's two rows' second lines, copied for the cloud-toggle arm only (rule 0 ships none).
const chatgptRunDetails = {
  local: "This chat stays on this computer",
  cloud: "Available on any device and can access your computer",
};
function stripVariants(arm: StripArm) {
  const props = {
    ...stripMachines,
    stripLayout: arm,
    ...(arm === "cloud-toggle" ? { runDetails: chatgptRunDetails } : {}),
  };
  const note = (what: string) => `${STRIP_NOTES[arm]} ${what}`;
  const whereOpen = arm === "cloud-toggle" ? openRunToggle : arm === "combined" ? openCombined : openWhere;
  const machineOpen =
    arm === "where-machine"
      ? pickAnother
      : arm === "where-machine-always"
        ? openMachineChip
        : arm === "cloud-toggle"
          ? openMachineControl
          : openMachineList;
  return {
    [`strip-${arm}`]: { note: note("Closed, on This Mac with no project: nothing is required to start."), props },
    [`strip-${arm}-where`]: { note: note("Where it runs, open."), props, play: whereOpen },
    [`strip-${arm}-machines`]: {
      height: 320,
      note: note(
        arm === "where-machine"
          ? "Another machine picked: the first ready machine is the pick and the machine chip opens on the person's machines, ready first, SSH and Cloud alike (the icon is how each connects), Add Machine… last."
          : "Which machine, open.",
      ),
      props,
      play: machineOpen,
    },
    [`strip-${arm}-cloud`]: {
      note: note(
        arm === "where-machine" || arm === "where-machine-always"
          ? "Cloud picked: two chips, Project and Where, with no machine chip and no New machine step. Send reuses the person's Cloud machine or makes one, its progress in the chat (Leo, 2026-11-04: \"after you pick Cloud, like, you shouldn't be seeing the new machine situation\")."
          : arm === "cloud-toggle"
            ? "Cloud picked: the machine chip says Cloud, never New machine; Send reuses the person's Cloud machine or makes one, its progress in the chat."
            : "Cloud picked: Cloud gives the workspace its own new machine; its project is picked in the same Project chip.",
      ),
      props: { ...props, runMode: { mode: "cloud" as const, onMode: () => undefined } },
    },
    ...(arm === "where-machine"
      ? {
          [`strip-${arm}-cloud-where`]: {
            height: 260,
            note: note(
              "Cloud picked, Where open: Cloud checked, one line, and nothing to choose after it: no New machine row, no machine chip, no create card on Send.",
            ),
            props: { ...props, runMode: { mode: "cloud" as const, onMode: () => undefined } },
            play: whereOpen,
          },
        }
      : {}),
    [`strip-${arm}-machine-picked`]: {
      note: note(
        "One of the person's machines picked (gpu-box): the machine chip names it, a server and a green live dot.",
      ),
      props: { ...props, ...onMachine("gpu-box") },
    },
  };
}

// A Cloud machine that sleeps (cloudMachines.ts withCloudSleep). Cloud machines pause on their own
// when idle and between tool calls (cmux-platform docs/agent-turn-sleep.md), so acpmux's lost link
// to one the account says is paused reads Paused (the quiet ring), a resume a spinner, and only a
// machine the account knows nothing about keeps Not connected. Leo, 2026-11-03: "it's all still
// responsive on the ui side".
const sleepingMachine = (stage?: string) => ({
  ...stripMachines,
  stripLayout: "where-machine-always" as const,
  ...onMachine("Cloud machine"),
  peerStates: { "studio-mini": "connected", "gpu-box": "connected", "Cloud machine": "reconnecting" },
  cloudMachines: stage ? [{ id: "vm-cloud", name: "Cloud machine", stage }] : [],
  onCloudMachine: () => undefined,
});
const chipSleep =
  (sleep: "paused" | "resuming" | "none"): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-button .acpmux-env-live"));
    const live = ctx.document.querySelector(".acpmux-location-button .acpmux-env-live");
    const shown = live?.getAttribute("data-sleep") ?? "none";
    if (shown !== sleep) throw new Error(`the machine chip reads ${shown}, not ${sleep}`);
    const box = live?.getBoundingClientRect();
    // The dot's own 6px box in every state: nothing in the strip moves as paused turns to resuming.
    if (!box || Math.round(box.width) !== 6) throw new Error("the live dot's box changed size");
    if (sleep === "resuming" && !live?.querySelector(".acpmux-env-live-spinner"))
      throw new Error("a resuming machine draws no spinner");
  };
const sleepVariants = {
  "machine-sleep-paused": {
    note: "Picked: a Cloud machine the account says is paused while acpmux has no link to it. The chip keeps the quiet ring and says Paused (to screen readers), never Not connected or Reconnecting; a send wakes it.",
    props: sleepingMachine("paused"),
    play: chipSleep("paused"),
  },
  "machine-sleep-resuming": {
    note: "The same machine on its way up (stage booting): a spinner turns in the dot's 6px box, so the strip does not move; it says Resuming.",
    props: sleepingMachine("booting"),
    play: chipSleep("resuming"),
  },
  "machine-sleep-unknown": {
    note: "Before / control: a Cloud machine acpmux lost that the account does not list: the ring, Not connected, as before.",
    props: sleepingMachine(),
    play: chipSleep("none"),
  },
  "machine-sleep-paused-list": {
    height: 320,
    note: "Machines… with that machine paused: its row reads Paused · Resume and is a pick (it resumes the machine, and the chat moves there once it links), never a greyed Reconnecting row.",
    props: { ...sleepingMachine("paused"), stripLayout: "combined" as const },
    play: async (ctx: Parameters<Play>[0]) => {
      await openMachineList(ctx);
      const row = [...ctx.document.querySelectorAll(".acpmux-env-popover .acpmux-env-row")].find((candidate) =>
        candidate.textContent?.includes("Cloud machine"),
      );
      if (!row) throw new Error("the paused machine is not listed");
      if (row.getAttribute("aria-disabled") === "true") throw new Error("the paused machine is greyed");
      if (!row.textContent?.includes("Paused")) throw new Error("the paused machine does not say Paused");
    },
  },
};

// Composer warning specimens use the same health shape emitted by the cached `_acpmux/status`
// snapshot. Keep a quiet specimen beside the warning states so a capture shows the unchanged
// menu when the host is within budget.
const machineWarningBase = {
  ...baseProps,
  peers: ["gpu-box"],
  peerKinds: { "gpu-box": "ssh" as const },
};
const machineWarningHighLoad = {
  ...machineWarningBase,
  peerResources: {
    "gpu-box": { ramFreeGB: 6.4, coresBusy: 14, cores: 10, busy: true, lowMemory: false },
  },
};
const machineWarningLowMemory = {
  ...machineWarningBase,
  peerResources: {
    "gpu-box": { ramFreeGB: 1.2, coresBusy: 4, cores: 10, busy: false, lowMemory: true },
  },
};
const machineWarningQuiet = {
  ...machineWarningBase,
  peerResources: {
    "gpu-box": { ramFreeGB: 16, coresBusy: 2, cores: 10, busy: false, lowMemory: false },
  },
};

// These two temporary styles let the gallery compare warning treatments without adding a
// presentation switch to shipped props. Each stage is a fresh document, so the style only affects
// its own capture. The selected product treatment remains the default tint plus detail row.
const openComputerWithGalleryStyle =
  (css: string): Play =>
  async (ctx) => {
    await openComputer(ctx);
    const style = ctx.document.createElement("style");
    style.dataset.galleryWarningTreatment = "true";
    style.textContent = css;
    ctx.document.head.append(style);
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
      props: folderMenuProps,
      play: openFolder,
    },
    "folder-menu-hover": {
      note: "Hover uses the neutral menu wash; the current folder keeps only its check.",
      props: folderMenuProps,
      play: async (ctx) => {
        await openFolder(ctx);
        await ctx.hover({ role: "option", name: /atlas-web/ });
      },
    },
    "folder-menu-keyboard": {
      note: "Arrow navigation uses the same neutral wash as hover.",
      props: folderMenuProps,
      play: async (ctx) => {
        await openFolder(ctx);
        await ctx.press("ArrowDown");
      },
    },
    "menu-grid-legacy": {
      note: "Experiment arm: the old 8px row inset and icon gap, which leaves environment labels off the shared menu column.",
      props: { ...baseProps, environments: true },
      play: openEnvironmentWithInsetArm("legacy"),
    },
    "menu-grid-shared": {
      note: "Experiment arm: the shared AppKit menu grid (15px icon lead, 35px icon-row text, 6px icon gap); this is the shipped choice.",
      props: { ...baseProps, environments: true },
      play: openEnvironmentWithInsetArm("shared"),
    },
    "menu-grid-compact": {
      note: "Experiment arm: a tighter 5px inset and 4px icon gap, rejected because it crowds icons against the popup edge.",
      props: { ...baseProps, environments: true },
      play: openEnvironmentWithInsetArm("compact"),
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
    "computer-first-setup": {
      note: "A fresh home, with Labs off and no other computer: Add a computer opens Add Device, and New Cloud Machine uses the existing creation action.",
      props: { ...baseProps, sessions: [], peers: [], cloudMachines: [], localName: "Studio Mac" },
      play: openComputer,
    },
    "computer-first-setup-signed-in": {
      note: "The same fresh home once the app says Cloud is signed in (`cloudMachine.list` signedIn true): no Sign in for Cloud row; Add a computer and New Cloud Machine stay.",
      props: {
        ...baseProps,
        sessions: [],
        peers: [],
        cloudMachines: [],
        localName: "Studio Mac",
        cloudSignedIn: true,
      },
      play: openComputer,
    },
    "computer-first-setup-chat": {
      note: "The same first-computer setup footer in an existing local chat, without enabling Labs or allowing the chat to change its machine.",
      props: {
        ...baseProps,
        started: true,
        sessions: [],
        peers: [],
        cloudMachines: [],
        localName: "Studio Mac",
        summary: { sessionId: "gallery-local", harness: "claude", hostKind: "local" },
      },
      play: openComputer,
    },
    "computer-menu": {
      note: "The computer menu keeps local and Cloud destinations together with SSH and cmux Cloud actions.",
      props: baseProps,
      play: openComputer,
    },
    "computer-menu-high-load": {
      note: "Warning treatment (selected): the Computer menu calls out a machine whose one-minute reading is above its CPU budget, with the tint confined to that row and a precise detail line.",
      props: machineWarningHighLoad,
      play: openComputer,
    },
    "computer-menu-high-load-icon": {
      note: "Warning treatment alternative: a small warning glyph plus the same precise CPU detail; gallery-only styling for comparison.",
      props: machineWarningHighLoad,
      play: openComputerWithGalleryStyle(
        '.acpmux-location-name[data-warning="true"]::before { content: "⚠"; display: inline-block; margin-inline-end: 5px; font-size: 0.9em; }',
      ),
    },
    "computer-menu-high-load-detail-only": {
      note: "Warning treatment alternative: the precise CPU detail carries the warning color while the machine name stays neutral; gallery-only styling for comparison.",
      props: machineWarningHighLoad,
      play: openComputerWithGalleryStyle(
        '.acpmux-location-name[data-warning="true"] { color: var(--agent-text); } .acpmux-location-name[data-warning="true"] .acpmux-menu-description { color: var(--acpmux-warning); }',
      ),
    },
    "computer-menu-low-memory": {
      note: "Warning specimen: the Computer menu reports the machine's low free memory in GB while keeping the row otherwise quiet and still selectable.",
      props: machineWarningLowMemory,
      play: openComputer,
    },
    "computer-menu-quiet": {
      note: "Before/after baseline: a healthy one-minute reading leaves the Computer menu identical to the existing quiet state.",
      props: machineWarningQuiet,
      play: openComputer,
    },
    "computer-menu-warnings-off": {
      note: "Setting-off specimen: even with the same high CPU reading, disabling machine load warnings keeps the existing Computer menu unchanged.",
      props: { ...machineWarningHighLoad, showMachineLoadWarnings: false },
      play: openComputer,
    },
    "computer-search": {
      // The open machine list runs to about y=221, past the entry's 180px stage. On a short stage
      // the page scrolls to show it, the anchor leaves the view and the popup hides
      // (`.ui-positioner[data-anchor-hidden]`). When the health runner's step still then sends focus
      // back to the dialog, focusing the hidden input does nothing and "gpu" goes to the body. A
      // stage that holds the whole menu keeps the anchor, the popup and the input in view.
      height: 420,
      note: "The classic machine picker uses the same searchable Combobox as environments and folders; filtering twenty machines leaves gpu-box.",
      props: {
        ...baseProps,
        peers: ["gpu-box", ...Array.from({ length: 20 }, (_, i) => `build-${i + 1}`)],
      },
      play: async (ctx) => {
        await openComputer(ctx);
        await ctx.focus({ role: "combobox", name: "Computer" });
        await ctx.type("gpu");
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="option"]').length === 1, { capMs: 8000 });
      },
    },
    "environment-picker": {
      note: "Where a chat runs (the shipped strip, Codex desktop's): This Mac, Cloud and Another machine, one line each, with no machine list and no machine-name subtitle, though gpu-box and a Cloud machine are connected. Cloud gives the new workspace its own new machine; Another machine shows the machine chip. New Cloud Machine…, Open Cloud…, SSH…, Add Machine… and Connect Phone… are the control's right-click menu.",
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
    "environment-picker-hover": {
      note: 'Hover is not selection (Austin, 2026-11-02: "This highlighting needs some fix"): the pointer on Cloud draws the neutral menu wash, inset 5 at radius 5 as the model picker\'s rows, while This Mac keeps only its check. Just opened (environment-picker), no row is lit.',
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
      },
      play: async (ctx) => {
        await openEnvironment(ctx);
        await ctx.hover({ role: "option", name: /Cloud/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"][data-highlighted]'));
      },
    },
    "environment-picker-keyboard": {
      note: "The arrow keys move the same wash: Down from the open menu lights Cloud; This Mac keeps its check.",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
      },
      play: async (ctx) => {
        await openEnvironment(ctx);
        await ctx.press("ArrowDown");
        await ctx.waitFor(() =>
          ctx.document.querySelector(".acpmux-env-popover:not(.acpmux-env-highlight-auto) [data-highlighted]"),
        );
      },
    },
    "environment-picker-machines": {
      note: "Machines… (the control's right-click menu): every machine, This Mac first, then the person's other machines with ⌥⌘1–9, one line each; gpu-box is connected (a filled dot), Cloud machine is not (a ring); this Mac has no status. No Cloud row here: Cloud is the main list's.",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
      },
      play: openMachineList,
    },
    "environment-picker-alone": {
      note: "Leo's case: This Mac, Cloud and Another machine, as Codex's strip. A person with other machines sees the same three; with none, Another machine is Add Machine….",
      props: {
        ...baseProps,
        environments: true,
        localName: "studio-mac",
        sessions: sessions.filter((session) => session.hostKind !== "cloud"),
        peers: [],
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "environment-face-label": {
      note: "Variant 1 of 3, picked: the control is its icon and the short name of the current choice (This Mac, Cloud, or a machine's name), as the folder beside it. An icon alone cannot tell this Mac from another Mac, or one Cloud machine from another.",
      props: {
        ...baseProps,
        environments: true,
        localName: "studio-mac",
        environmentFace: "label" as const,
        peers: ["gpu-box"],
        peerKinds: { "gpu-box": "ssh" },
        peerConnected: { "gpu-box": true },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "environment-face-icon": {
      note: "Variant 2 of 3, the control is the icon alone (a computer for this Mac, a cloud for Cloud), its name in the tooltip, as Codex's cloud button beside its composer.",
      props: {
        ...baseProps,
        environments: true,
        localName: "studio-mac",
        environmentFace: "icon" as const,
        peers: ["gpu-box"],
        peerKinds: { "gpu-box": "ssh" },
        peerConnected: { "gpu-box": true },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "environment-face-chip": {
      note: "Variant 3 of 3, the control is a bordered chip in the row above the composer, as Codex's Projects | Cloud row. Its border is a second box the strip's plain text over the box avoids.",
      props: {
        ...baseProps,
        environments: true,
        localName: "studio-mac",
        environmentFace: "chip" as const,
        peers: ["gpu-box"],
        peerKinds: { "gpu-box": "ssh" },
        peerConnected: { "gpu-box": true },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    ...stripVariants("where-machine"),
    ...stripVariants("where-machine-always"),
    ...stripVariants("cloud-toggle"),
    ...stripVariants("combined"),
    // One Cloud row, whatever the account state: Cloud while signed in or before the app's Cloud
    // reply, Sign in for Cloud in its place once the app said signed out (never both).
    "strip-where-signed-out": {
      note: "Where open with the app saying Cloud is signed out (`cloudMachine.list` signedIn false): the one Cloud row reads Sign in for Cloud, in Cloud's place, and signs in only.",
      props: { ...stripMachines, stripLayout: "where-machine" as const, cloudSignedIn: false },
      play: openWhere,
    },
    "strip-where-account-unknown": {
      note: "Where open before the app's Cloud account reply: the row reads Cloud, never Sign in for Cloud, since nothing says the person is signed out yet.",
      props: { ...stripMachines, stripLayout: "where-machine" as const, cloudSignedIn: undefined },
      play: openWhere,
    },
    ...sleepVariants,
    "strip-cloud-works-on": {
      note: "ChatGPT Work's model, for comparison only (not built in cmux: a Cloud chat's agent runs on its Cloud machine with its files there). Where says the agent lives in Cloud; the machine chip says the computer it works on, as ChatGPT's \"In the cloud\" chat whose files and shell are on the Mac.",
      props: {
        ...stripMachines,
        stripLayout: "where-machine" as const,
        runMode: { mode: "cloud" as const, onMode: () => undefined },
        cloudWorksOn: "works on studio-mac",
      },
    },
    "environment-picker-cloud-chat": {
      // The whole list, down to the Cloud section, past the entry's 180px stage.
      height: 420,
      note: "Preview: a chat seeded onto a Cloud machine (kind-aqua-sandpiper). This Mac's row stays This Mac (its own name, office-mac, the host's `localMachineName`, is the row's tooltip) and the Cloud machine is the one other row, checked, between This Mac and Cloud, never This Mac's row (Leo, 2026-10-30: \"the ui is so ass in general for this tho\"). gpu-box is not listed: it is in Machines….",
      props: {
        ...baseProps,
        environments: true,
        summary: { sessionId: "", harness: "claude", host: "kind-aqua-sandpiper", hostKind: "cloud" as const },
        sessions: [
          {
            sessionId: "gallery-sandpiper",
            displayTitle: "Set up the repo",
            cwd: "/root/work",
            host: "kind-aqua-sandpiper",
            hostKind: "cloud" as const,
            updatedAt: 0,
          },
        ],
        peers: ["gpu-box"],
        peerKinds: { "gpu-box": "ssh" },
        peerConnected: { "gpu-box": true },
        localName: thisMacName("office-mac", "kind-aqua-sandpiper", { hostKind: "cloud", host: "kind-aqua-sandpiper" }),
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
      },
    },
    "environment-picker-sandboxed-option": {
      note: "Labs (hq#3367): Sandboxed is Cloud's other face, with no row of its own. Holding ⌥ while the list is open shows it, as a Mac menu's alternate: a pick runs the new chat's first message once on a throwaway Cloud VM.",
      props: {
        ...baseProps,
        environments: true,
        runMode: { mode: "persistent", onMode: () => undefined },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
        ctx.document.defaultView?.dispatchEvent(new KeyboardEvent("keydown", { key: "Alt", altKey: true }));
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="sandboxed"]'));
      },
    },
    "environment-picker-sandboxed-picked": {
      note: "Labs (hq#3367): Sandboxed picked. The control names it where the machine was, and its row stays checked in Cloud's place; any machine goes back to a Persistent chat.",
      props: {
        ...baseProps,
        environments: true,
        runMode: { mode: "sandboxed", onMode: () => undefined },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="sandboxed"]'));
      },
    },
    "environment-picker-cloud-row": {
      note: "Cloud work mode: where this chat runs is one pick, This Mac or Cloud. Cloud is one line: the host gives the new workspace its own new machine (cloud.startChat, one workspace per machine) and copies the folder, with no machine, size or environment to choose. The machines are in Machines….",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
        runMode: { mode: "persistent", onMode: () => undefined },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="cloud"]'));
      },
    },
    "environment-picker-cloud-picked": {
      note: "Cloud work mode: Cloud picked. The control reads Cloud where the machine was and its row is checked; This Mac goes back to this Mac.",
      props: { ...baseProps, environments: true, runMode: { mode: "cloud", onMode: () => undefined } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /^Environment/ });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-mode="cloud"][data-current]'));
      },
    },
    "environment-picker-cloud-closed": {
      note: "Labs (cloud work mode): the closed control with Cloud picked, as the composer shows it before the first send.",
      props: { ...baseProps, environments: true, runMode: { mode: "cloud", onMode: () => undefined } },
    },
    "environment-picker-cloud-machines": {
      note: "Machines…: the machines, then the account's Cloud machines acpmux does not list (`cloudMachine.list`) among the other machines, each with its stage: build box is paused (a pick resumes it), eval box is ready (a pick opens it), fresh box is still booting. They take no ⌥⌘ digit and are not greyed.",
      props: {
        ...baseProps,
        environments: true,
        peers: ["gpu-box", "Cloud machine"],
        peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
        peerConnected: { "gpu-box": true, "Cloud machine": false },
        cloudMachines: accountMachines,
        onCloudMachine: () => undefined,
      },
      play: openMachineList,
    },
    "computer-menu-cloud-machines": {
      note: "Previews off: the plain Computer menu lists the account's Cloud machines acpmux does not list the same way, with their stage on the second line.",
      props: { ...baseProps, cloudMachines: accountMachines, onCloudMachine: () => undefined },
      play: openComputer,
    },
    "environment-picker-fleet": {
      height: 760,
      note: "Machines…: every machine acpmux lists (21, from `host ls`): This Mac, then the person's own machines and the Cloud and VM pools with no headers, and a search field (8 or more machines); in each group the machines a chat can start on come first, in number order, and the rest are greyed with their state (Offline, Reconnecting, Connecting) and are no pick.",
      props: { ...fleetProps, environments: true },
      play: async (ctx) => {
        await openMachineList(ctx);
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
      play: openMachineList,
    },
    "environment-picker-no-cloud": {
      note: "With no Cloud machine yet, Cloud is still the second row; a pick makes a new one (New Cloud Machine).",
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
      note: "New Tab page, Machines…: the saved environments under This Mac, before the machines; Create environment is the control's right-click menu too.",
      props: savedProps(),
      play: async (ctx) => {
        await openMachineList(ctx);
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
      note: "Preview, a started chat on this Mac: the picker shows where it runs and Move to Cloud, the tab menu's same action, one line each.",
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
      note: "Preview, a started Cloud chat a move from this Mac put there: the picker shows its machine and Bring Back Local, one line each.",
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
    "started-browse-error-tray": {
      note: "Tray style keeps the folder chooser recovery row below the raised composer, with Retry and Dismiss visible.",
      props: {
        ...baseProps,
        started: true,
        summary: {
          sessionId: "gallery-started-browse-error-tray",
          harness: "claude",
          cwd: projects[0]!.cwd,
          host: "This Mac",
          hostKind: "local",
        },
        onNewChat: () => undefined,
        onBrowseFolder: () => Promise.reject(new Error("Folder access was denied.")),
      },
      play: async (ctx) => {
        ctx.document.documentElement.setAttribute("data-top-strip", "tray");
        await ctx.click({ role: "button", name: "Folder" });
        await ctx.click({ selector: ".acpmux-location-choose:last-child" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]'));
      },
    },
    "started-browse-error": {
      note: "A refused folder chooser leaves a started chat in place with a localized reason and direct Retry and Dismiss actions.",
      props: {
        ...baseProps,
        started: true,
        summary: {
          sessionId: "gallery-started-browse-error",
          harness: "claude",
          cwd: projects[0]!.cwd,
          host: "This Mac",
          hostKind: "local",
        },
        onNewChat: () => undefined,
        onBrowseFolder: () => Promise.reject(new Error("Folder access was denied.")),
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Folder" });
        await ctx.click({ selector: ".acpmux-location-choose:last-child" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]'));
      },
    },
    // A new chat's extra folders (extraFolders.ts, acpmux `additionalDirectories`). Leo, 2026-11-03:
    // "being able to have chatgpt (and in this case, any harnesses) see whatever folders/files would
    // be cool" and "and you can also just start with nothing".
    "extra-folders-no-project": {
      note: "No project: the chat starts in its private folder and sees the two folders added beside it; the chip reads No project +2, the menu lists them under Also sees with × each.",
      props: extraProps("local", ["/Users/you/notes", "/Users/you/Downloads/receipts"], { noProject: true }),
      play: openFolderMenu,
    },
    "extra-folders-project": {
      note: "A project and three folders beside it: the chip reads atlas-web +3, the menu lists the three under Also sees.",
      props: extraProps("local", ["/Users/you/src/relay", "/Users/you/notes", "/Users/you/design/specs"], {
        summary: { sessionId: "", harness: "claude", cwd: projects[0]!.cwd, host: "This Mac", hostKind: "local" },
      }),
      play: openFolderMenu,
    },
    "extra-folders-adding": {
      note: "Add folder… turns the menu into a pick of one more folder: its search says Add a folder, the project and the folders already added are not offered, Choose folder… opens this Mac's panel.",
      props: extraProps("local", ["/Users/you/src/relay"], {
        summary: { sessionId: "", harness: "claude", cwd: projects[0]!.cwd, host: "This Mac", hostKind: "local" },
      }),
      play: async (ctx) => {
        await openFolderMenu(ctx);
        await ctx.click({ role: "option", name: "Add folder…" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-folder-popover input[placeholder="Add a folder"]'));
      },
    },
    "extra-folders-peer": {
      note: "A new chat on an SSH machine: its folders are that machine's (its own folder list or a typed path, never this Mac's panel); two of them sit beside its project.",
      props: extraProps("gpu-box", ["/home/dev/datasets", "/srv/shared/checkpoints"], {
        environments: true,
        peers: ["gpu-box"],
        peerKinds: { "gpu-box": "ssh" },
        peerConnected: { "gpu-box": true },
        summary: { sessionId: "", harness: "claude", cwd: "/home/dev/model", host: "gpu-box", peer: "gpu-box" },
        machineFolders: [
          { cwd: "/home/dev/model", label: "model" },
          { cwd: "/home/dev/datasets", label: "datasets" },
          { cwd: "/home/dev/eval", label: "eval" },
        ],
      }),
      play: openFolderMenu,
    },
  },
});
