// l10n-allow-file: gallery fixture names and messages.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ComposerContext } from "./ComposerContext";
import type { GitHubPicker, GitHubPickerState } from "./githubRepos";

type Props = ComponentProps<typeof ComposerContext>;

function picker(state: Partial<GitHubPickerState> = {}): GitHubPicker {
  return {
    state: { query: null, truncated: false, loading: false, waiting: false, ...state },
    onOpen: () => {},
    onConnect: () => {},
    onSearch: () => {},
    onRetry: () => {},
    onAddAccount: () => {},
  };
}

const ready = { state: "ready", reposScope: "selected" } as const;
const notConnected = { state: "not_connected", reposScope: null } as const;
const repos = [
  { fullName: "acme/api", private: true, defaultBranch: "main" },
  { fullName: "acme/web", private: false, defaultBranch: "main" },
];
const base: Props = {
  summary: { sessionId: "", cwd: "/Users/you/src/atlas-web", host: "This Mac", hostKind: "local" },
  projectChoices: [
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/Users/you/src/notes", label: "notes" },
  ],
  cloudMachines: [],
  onProject: () => {},
  onBrowseProject: () => undefined,
  onNoProject: () => {},
  onNewProject: () => {},
  onCloneRepository: () => new Promise(() => {}),
};
const cloud = { ...base, runMode: { mode: "cloud", onMode: () => {} } } satisfies Props;
const cloudFolders = {
  ...cloud,
  peers: ["north", "eu-west"],
  peerKinds: { north: "cloud", "eu-west": "cloud" },
  peerConnected: { north: true, "eu-west": true },
  sessions: [
    {
      sessionId: "north-1",
      harness: "claude",
      peer: "north",
      host: "North",
      hostKind: "cloud",
      cwd: "/home/cmux/work/api",
    },
    {
      sessionId: "north-2",
      harness: "claude",
      peer: "north",
      host: "North",
      hostKind: "cloud",
      cwd: "/home/cmux/work/tools",
    },
    {
      sessionId: "europe-1",
      harness: "claude",
      peer: "eu-west",
      host: "Europe",
      hostKind: "cloud",
      cwd: "/home/cmux/work/web",
    },
  ],
} satisfies Props;

const openFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-folder-popover [role="option"]'));
};

const openSources: Play = async (ctx) => {
  await openFolder(ctx);
  await ctx.click({ role: "option", name: "Add project…" });
};

const entry = (note: string, gitHub: GitHubPicker, props = base) => ({
  note,
  props: { ...props, github: gitHub },
  play: openSources,
});
const unavailable = (reason: "signed_out" | "not_configured" | "not_allowed" | "unreachable") =>
  picker({ status: { state: "unavailable", reposScope: null, reason } });

const step =
  (name: RegExp): Play =>
  async (ctx) => {
    await openSources(ctx);
    await ctx.click({ role: "option", name });
  };
const gitURL =
  (text?: string, message?: string): Play =>
  async (ctx) => {
    await step(/^Git URL/)(ctx);
    if (text) {
      await ctx.type(text, { role: "textbox", name: "Git URL" });
      await ctx.press("Enter");
    }
    if (message) await ctx.waitFor(() => ctx.document.body.textContent?.includes(message));
  };

export default componentEntry<Props>({
  id: "agent-pane.github-folders",
  title: "Add project palette",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/SourcePicker.tsx",
    "agent-session/acpmux/FolderPopover.tsx#FolderPopover",
    "agent-session/acpmux/GitHubIcons.tsx#GitHubMark",
    "agent-session/acpmux/GitHubIcons.tsx#LockIcon",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 420,
  anchors: [{ selector: ".acpmux-composer-context" }],
  variants: {
    checking: entry("GitHub is visible while the status check is running.", picker()),
    "unavailable-signed-out": entry("The GitHub action starts sign-in.", unavailable("signed_out")),
    "unavailable-not-configured": entry(
      "GitHub offers to connect without a configured app.",
      unavailable("not_configured"),
    ),
    "unavailable-not-allowed": entry("Team policy turns GitHub off.", unavailable("not_allowed")),
    unavailable: entry("The GitHub action retries the Cloud status check.", unavailable("unreachable")),
    "not-connected": entry("The GitHub action opens installation.", picker({ status: notConnected })),
    waiting: entry(
      "An organization owner must approve the installation.",
      picker({ status: { ...notConnected, pendingApproval: true } }),
    ),
    opening: entry("The GitHub page is opening.", picker({ status: notConnected, connecting: true })),
    "waiting-step": {
      ...entry(
        "The GitHub step says the repositories show up once an owner approves (Leo 2026-11-25).",
        picker({ status: { ...notConnected, pendingApproval: true } }),
      ),
      play: step(/^GitHub repository/),
    },
    "unavailable-refused": {
      ...entry(
        "The install request failed and can be retried.",
        picker({ status: notConnected, connectError: "The installation could not open." }),
      ),
      play: step(/^GitHub repository/),
    },
    "needs-reauth": {
      ...entry(
        "A GitHub link that needs reauthorization shows the reason supplied by the host.",
        picker({ status: { ...notConnected, message: "Reauthorize the GitHub App to see your repositories." } }),
      ),
      play: step(/^GitHub repository/),
    },
    "on-github": {
      ...entry(
        "GitHub's page is open in the app's own panel: the step says to finish there, no click needed (Leo 2026-11-25).",
        picker({ status: { ...notConnected, progress: "on_github" } }),
      ),
      play: step(/^GitHub repository/),
    },
    finishing: {
      ...entry(
        "The app finishes what GitHub handed back itself, no page of ours in between.",
        picker({ status: { ...notConnected, progress: "finishing" } }),
      ),
      play: step(/^GitHub repository/),
    },
    connected: {
      ...entry(
        "The connect just finished: the repositories are here at once, with whose they are and Add organization.",
        picker({ status: { ...ready, progress: "connected", account: "acme" }, repos }),
      ),
      play: step(/^GitHub repository/),
    },
    "ready-empty": entry(
      "Open GitHub to choose repositories for the empty installation.",
      picker({ status: ready, repos: [] }),
    ),
    ready: entry("This Mac offers four project sources.", picker({ status: ready, repos })),
    "with-extra-folder": entry(
      "Add project sources for a chat with an extra folder.",
      picker({ status: ready, repos }),
      {
        ...base,
        extraFolders: { draft: { machine: "local", folders: ["/Users/you/notes"] }, onChange: () => {} },
      },
    ),
    "not-shared": {
      ...entry(
        "The repository wanted when Connect started is still not shared: the step says how to add it.",
        picker({ status: ready, repos, missing: "acme/billing" }),
      ),
      play: step(/^GitHub repository/),
    },
    "typed-not-shared": {
      ...entry("A typed owner/name the app can't see says how to add it.", picker({ status: ready, repos })),
      play: async (ctx) => {
        await step(/^GitHub repository/)(ctx);
        await ctx.type("acme/billing", { role: "combobox", name: "Search repositories" });
      },
    },
    "ready-picked": {
      ...entry("The GitHub step shows the selected private repository.", picker({ status: ready, repos }), {
        ...cloud,
        summary: { ...base.summary!, cwd: "github:acme/api" },
      }),
      play: step(/^GitHub repository/),
    },
    error: {
      ...entry(
        "The repository list failed and offers Retry.",
        picker({ status: ready, error: "Couldn’t load repositories." }),
      ),
      play: step(/^GitHub repository/),
    },
    "rate-limited": entry(
      "GitHub is rate limiting repository requests.",
      picker({ status: ready, error: "Rate limited", rateLimited: true }),
    ),
    "rate-limit-wait": {
      ...entry(
        "The repository step shows the wait supplied by the service.",
        picker({ status: ready, error: "Rate limited", rateLimited: true, retryAfter: 25 }),
      ),
      play: step(/^GitHub repository/),
    },
    "this-mac-folders": {
      ...entry("This Mac lists its folders above the project actions.", picker({ status: notConnected })),
      play: openFolder,
    },
    "this-mac-repositories": {
      ...entry(
        "This Mac lists its folders, then GitHub's repositories under a hairline and their heading (cmux#53226).",
        picker({ status: ready, repos }),
        { ...base, runMode: { mode: "persistent", onMode: () => {} } },
      ),
      play: openFolder,
    },
    "cloud-repositories": {
      ...entry("Cloud lists available GitHub repositories.", picker({ status: ready, repos }), cloud),
      play: openFolder,
    },
    "cloud-folders": {
      ...entry("Known Cloud folders are grouped by machine.", picker({ status: ready, repos }), cloudFolders),
      play: openFolder,
    },
    "cloud-folder-source": {
      ...entry("Choose a machine to see its folders.", picker({ status: ready, repos }), cloudFolders),
      play: step(/^Folder on a Cloud machine/),
    },
    "cloud-machine-folders": {
      ...entry("Choose from one Cloud machine’s folders.", picker({ status: ready, repos }), cloudFolders),
      play: async (ctx) => {
        await step(/^Folder on a Cloud machine/)(ctx);
        await ctx.click({ role: "option", name: /^North/ });
      },
    },
    "filtered-sources": {
      ...entry("Typing narrows the sources.", picker({ status: ready, repos })),
      play: async (ctx) => {
        await openSources(ctx);
        await ctx.type("github", { role: "combobox", name: "Search sources" });
      },
    },
    "cloud-empty": entry(
      "Cloud offers three sources even with no repositories or folders.",
      unavailable("not_configured"),
      cloud,
    ),
    "cloud-folder-empty": {
      ...entry("The Cloud folder step explains an empty list.", picker({ status: ready, repos }), cloud),
      play: step(/^Folder on a Cloud machine/),
    },
    "url-empty": {
      ...entry("Enter an HTTPS Git URL to clone on This Mac.", picker()),
      play: gitURL(),
    },
    "url-invalid": {
      ...entry("Invalid URLs are explained in the input step.", picker()),
      play: gitURL("http://git.example/acme/api", "Enter an HTTPS repository URL."),
    },
    "url-cloning": {
      ...entry("While cloning, the composer chip names the repository.", picker()),
      play: gitURL("https://git.example/acme/api", "Cloning…"),
    },
    "url-failed": {
      ...entry("A rejected clone can be retried in place.", picker(), {
        ...base,
        onCloneRepository: async () => {
          throw Object.assign(new Error("Destination taken"), { code: "repo.destination_taken" });
        },
      }),
      play: gitURL("https://git.example/acme/api", "Another folder already uses this clone location."),
    },
  },
});
