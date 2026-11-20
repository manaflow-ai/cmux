// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";
import type { GitHubConnectionState } from "./ops";
import { githubAppName } from "./components/githubAppName.experiment";

const github: GitHubConnectionState = {
  title: "GitHub",
  detail: "Connect GitHub to give agents access to selected repositories.",
  busy: false,
  connect: "Connect GitHub",
  disconnect: "Disconnect",
  reconfigure: "Reconfigure",
  confirm: "Disconnect GitHub?",
  cancel: "Cancel",
  refresh: "Refresh",
  canConnect: true,
  connections: [],
};

const variant = (connection: GitHubConnectionState, note: string): SettingsPageVariant => ({
  section: "accounts",
  note,
  accounts: {
    teams: null,
    refresh: "Refresh",
    refreshing: false,
    cmux: {
      title: "cmux Account",
      detail: null,
      status: "",
      statusKind: "neutral",
      busy: false,
      buttons: [],
      note: null,
      error: null,
    },
    removeTitle: "Remove",
    groups: [],
    github: connection,
  },
  steps: [{ selector: '[data-card="github-connection"]', action: "wait" }],
});

export default settingsPageEntry({
  id: "pages.settings-github-app-name",
  title: "GitHub App name preview",
  area: "Settings",
  height: 760,
  covers: ["pages/settings/components/GitHubAppNamePreview.tsx", "pages/settings/components/GitHubAccountsCard.tsx"],
  experiment: {
    definition: githubAppName,
    script: [
      {
        name: "Inspect GitHub connection",
        run: async (ctx) => {
          await ctx.waitFor(() => ctx.document.querySelector('[data-card="github-connection"]'));
        },
      },
    ],
  },
  variants: {
    disconnected: variant(github, "Compare all three name proposals before connecting. Off is the shipped default."),
    "signed-out": variant(
      { ...github, canConnect: false, signIn: "Sign In" },
      "Sign In remains the host's action in every arm.",
    ),
    connected: variant(
      {
        ...github,
        detail: "Connected",
        connections: [
          {
            id: "sample-github",
            account: "sample-team",
            status: "Connected",
            permissions: ["contents:write"],
            canDisconnect: true,
            canReconfigure: true,
          },
        ],
      },
      "Reconfigure and Disconnect still target the installed connection, not the proposed name.",
    ),
  },
});
