// l10n-allow-file: gallery fixture repository names and error text, not shipped UI.
//
// A new Cloud chat's folder menu with its GitHub part (githubRepos.ts, FolderPopover `github`): the
// Add repositories from GitHub row before the cmux GitHub App is installed, its install card and the
// wait after Install on GitHub, the repositories once it is ready, a failed read with Retry, and the
// row that connects in place while GitHub is unavailable (signed out, not set up, or refused).
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
    unavailable: {
      note: "GitHub unavailable (the check did not answer): the same Add repositories from GitHub row; a click connects in place, the menu stays open.",
      props: { ...base, github: picker({ status: { state: "unavailable", reposScope: null, reason: "unreachable" } }) },
      play: openFolder,
    },
    "unavailable-signed-out": {
      note: "Signed out of the Cloud service: the row reads Sign in to add GitHub repositories and opens sign-in.",
      props: { ...base, github: picker({ status: { state: "unavailable", reposScope: null, reason: "signed_out" } }) },
      play: openFolder,
    },
    "unavailable-not-configured": {
      note: "No GitHub App on this Cloud service: a quiet second line says so; the row still tries on a click.",
      props: {
        ...base,
        github: picker({ status: { state: "unavailable", reposScope: null, reason: "not_configured" } }),
      },
      play: openFolder,
    },
    "unavailable-refused": {
      note: "A click was refused: the host's words are the row's second line, and another click tries again.",
      props: {
        ...base,
        github: picker({
          status: { state: "unavailable", reposScope: null, reason: "unreachable" },
          connectError: "GitHub didn't answer. Try again.",
        }),
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
