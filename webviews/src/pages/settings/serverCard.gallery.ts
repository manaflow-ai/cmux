// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Server (ServerCard): each server's status and version line, Restart Recommended, the
// local socket and the Tailscale address with Pair, from the host lists' `server`.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { ServerHostState } from "./ops";

const base: ServerHostState = {
  title: "Server",
  empty: "No server has answered yet.",
  socket_title: "Local Socket",
  tailnet_title: "Tailscale Address",
  copy_title: "Copy",
  pair_title: "Pair",
  servers: [
    {
      id: "cmux-tui|local",
      kind: "cmux-tui",
      host: null,
      name: "cmux-tui",
      running: true,
      status: "Running",
      version_line: "Version 0.67.0 · Build 7a3c9e1 · Protocol 12",
      restart: null,
      socket: "/Users/me/.cmux/sockets/main.sock",
      tailnet: "100.64.0.7:7777",
    },
  ],
};
const shown: PageFixtureStep = { selector: '[data-card="server"]', action: "wait" };
const variant = (server: ServerHostState, note: string): SettingsPageVariant => ({
  section: "server",
  host: { server },
  steps: [shown],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-server",
  title: "Settings Server",
  area: "Settings",
  height: 520,
  covers: ["pages/settings/components/ServerCard.tsx"],
  anchors: [{ selector: '[data-card="server"]' }],
  variants: {
    current: variant(
      base,
      "A current server: Running, its version line, the local socket, the Tailscale address with Pair and Copy.",
    ),
    "restart-recommended": variant(
      {
        ...base,
        servers: [
          {
            ...base.servers[0]!,
            version_line: "Version 0.66.0 · Build 1d4b2f8 · Protocol 12",
            restart: {
              title: "Restart Recommended",
              help: "A restart turns on: Tab groups, Workspace checklists and 2 more",
              button: "Restart cmux-tui…",
            },
          },
        ],
      },
      "An older server: the Restart Recommended row names what a restart turns on; its button opens the confirm and never restarts by itself.",
    ),
    none: variant({ ...base, servers: [] }, "No server has answered yet: one line, no rows."),
  },
});
