// l10n-allow-file: gallery fixture repository names and error text, not shipped UI.
//
// A new Cloud chat's folder menu with its GitHub part (githubRepos.ts, FolderPopover `github`): the
// Add repositories from GitHub row before the cmux GitHub App is installed, its install card and the
// wait after Install on GitHub, the repositories once it is ready, and a failed read with Retry.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ComposerContext } from "./ComposerContext";
import type { GitHubPicker, GitHubPickerState } from "./githubRepos";

type Props = ComponentProps<typeof ComposerContext>;

/// The folder menu's GitHub handle as a fixed state: the gallery draws it, nothing is asked.
function picker(state: Partial<GitHubPickerState>): GitHubPicker {
  return {
    state: { query: null, truncated: false, loading: false, waiting: false, ...state },
    onOpen: () => undefined,
    onConnect: () => {
      document.documentElement.dataset.galleryGitHub = "connect";
    },
    onSearch: () => undefined,
    onRetry: () => {
      document.documentElement.dataset.galleryGitHub = "retry";
    },
  };
}

const REPOS = [
  { fullName: "acme/api", private: true, defaultBranch: "main" },
  { fullName: "acme/web", private: false, defaultBranch: "main" },
  { fullName: "acme/infra", private: true, defaultBranch: "main" },
  { fullName: "you/dotfiles", private: false, defaultBranch: "main" },
];

const base: Props = {
  summary: { sessionId: "", harness: "claude", cwd: "", host: "This Mac", hostKind: "local" },
  projectChoices: [
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/Users/you/src/notes", label: "notes" },
  ],
  localName: "This Mac",
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onNoProject: () => undefined,
  noProject: true,
  runMode: { mode: "cloud", onMode: () => undefined },
};

const notConnected = picker({ status: { state: "not_connected", reposScope: null } });

const openFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
};

const openCard: Play = async (ctx) => {
  await openFolder(ctx);
  await ctx.click({ role: "option", name: /Add repositories from GitHub/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-github-card"));
};

export default componentEntry<Props>({
  id: "agent-pane.github-folders",
  title: "Folder menu: GitHub repositories",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/FolderPopover.tsx#FolderPopover",
    "agent-session/acpmux/GitHubInstallCard.tsx#GitHubInstallCard",
    "agent-session/acpmux/GitHubInstallCard.tsx#GitHubMark",
    "agent-session/acpmux/GitHubInstallCard.tsx#LockIcon",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 360,
  anchors: [{ selector: ".acpmux-composer-context" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "The folder menu and its install card open in a portal and leave the composer row in place.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Choosing the GitHub row swaps the menu's content without moving the row.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Opening the folder menu and its install card must stay responsive on the gallery host.",
    },
  },
  variants: {
    "not-connected": {
      note: "A new Cloud chat before the cmux GitHub App is installed: one Add repositories from GitHub row ends the list.",
      props: { ...base, github: notConnected },
      play: openFolder,
    },
    "install-card": {
      note: "The row opens the install card in the menu: the GitHub mark, what it is, one full-width Install on GitHub; Back or Escape returns to the list.",
      props: { ...base, github: notConnected },
      play: openCard,
    },
    waiting: {
      note: "After Install on GitHub: a quiet Waiting for GitHub… until the window comes back and the status says ready.",
      props: { ...base, github: picker({ status: { state: "not_connected", reposScope: null }, waiting: true }) },
      play: openCard,
    },
    ready: {
      note: "Installed for selected repositories: a GitHub group under the folders, a lock on private ones, then Choose more repositories….",
      props: { ...base, github: picker({ status: { state: "ready", reposScope: "selected" }, repos: REPOS }) },
      play: openFolder,
    },
    "ready-picked": {
      note: "A repository picked: the chip reads owner/name with the GitHub mark, and its row is checked.",
      props: {
        ...base,
        noProject: false,
        summary: { ...base.summary!, cwd: "github:acme/api" },
        github: picker({ status: { state: "ready", reposScope: "all" }, repos: REPOS }),
      },
      play: openFolder,
    },
    error: {
      note: "Reading the repositories failed: one short line with Retry under the list.",
      props: {
        ...base,
        github: picker({ status: { state: "ready", reposScope: "all" }, error: "GitHub didn't answer." }),
      },
      play: openFolder,
    },
  },
});
