// l10n-allow-file: gallery fixture repository names and error text, not shipped UI.
//
// A new Cloud chat's folder menu with its GitHub part (githubRepos.ts, FolderPopover `github`): the
// one Connect to GitHub row while GitHub is not connected (at rest, waiting for the browser, refused,
// signed out), none where it can't connect (not set up, unchecked), the repositories once it is ready,
// and a failed read with Retry.
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

export default componentEntry<Props>({
  id: "agent-pane.github-folders",
  title: "Folder menu: GitHub repositories",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/FolderPopover.tsx#FolderPopover",
    "agent-session/acpmux/GitHubIcons.tsx#GitHubMark",
    "agent-session/acpmux/GitHubIcons.tsx#LockIcon",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 360,
  anchors: [{ selector: ".acpmux-composer-context" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "The folder menu opens in a portal and leaves the composer row in place.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Connect to GitHub keeps the menu open and its list in place; the row draws its title alone.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Opening the folder menu must stay responsive on the gallery host.",
    },
  },
  variants: {
    "not-connected": {
      note: "A new Cloud chat before GitHub is connected: Connect to GitHub sits with the fixed actions under the list, its title alone; one click opens the install page, the menu stays open.",
      props: { ...base, github: notConnected },
      play: openFolder,
    },
    waiting: {
      note: "After the click: the row stays its title alone (GitHub's own page is the one wait, #46018) until the window comes back and the status says ready.",
      props: { ...base, github: picker({ status: { state: "not_connected", reposScope: null }, waiting: true }) },
      play: openFolder,
    },
    ready: {
      note: "Installed for selected repositories: a GitHub group in the list, a lock on private ones; Choose more repositories… sits with the fixed actions under Add folder….",
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
      note: "GitHub unavailable (the check did not answer): no Connect to GitHub row, since a connected team's check can fail too (#46018).",
      props: { ...base, github: picker({ status: { state: "unavailable", reposScope: null, reason: "unreachable" } }) },
      play: openFolder,
    },
    "unavailable-signed-out": {
      note: "Signed out of the Cloud service: the same row, its title alone; a click opens sign-in.",
      props: { ...base, github: picker({ status: { state: "unavailable", reposScope: null, reason: "signed_out" } }) },
      play: openFolder,
    },
    "unavailable-not-configured": {
      note: "No GitHub App on this Cloud service: no Connect to GitHub row, since a click could connect nothing (#46018).",
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
      note: "Reading the repositories failed: the GitHub row becomes Retry, the error its second line; a click reads again with the menu open.",
      props: {
        ...base,
        github: picker({ status: { state: "ready", reposScope: "all" }, error: "GitHub didn't answer." }),
      },
      play: openFolder,
    },
  },
});
