// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Accounts and Devices > Connectors (ConnectorsCard): what the person connected, then what
// they can connect, from cmux-platform's `/v1/connectors` as the host relays it.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockConnectors } from "./mockProvider";
import type { ConnectorsState } from "./ops";

const shown: PageFixtureStep = { selector: '[data-card="connectors"]', action: "wait" };
const variant = (connectors: ConnectorsState, note: string, steps: PageFixtureStep[] = []): SettingsPageVariant => ({
  section: "connectors",
  host: {},
  connectors,
  steps: [shown, ...steps],
  note,
});
const base = mockConnectors();
const nothing: ConnectorsState = {
  ...base,
  team: null,
  connectors: base.connectors?.map((connector) => ({
    ...connector,
    state: connector.configured ? "available" : "unavailable",
    connections: [],
  })),
};

export default settingsPageEntry({
  id: "pages.settings-connectors",
  title: "Settings Connectors",
  area: "Settings",
  height: 640,
  covers: ["pages/settings/components/ConnectorsCard.tsx", "pages/settings/connectors.ts"],
  anchors: [{ selector: '[data-card="connectors"]' }],
  variants: {
    current: variant(
      base,
      "On a team: GitHub shared with the team, Linear the person's own and waiting on sign-in again (it offers Connect again), Google Drive not set up on this server, the rest ready to connect.",
    ),
    "nothing-connected": variant(
      nothing,
      "Personal, nothing connected (Leo: not everybody wants GitHub connected): every provider offers Connect, and Connect goes straight to the provider as Only You.",
    ),
    "choose-sharing": variant(
      base,
      "On a team, Connect on Slack first asks who may use it: Only You (checked) or Your Team.",
      [{ selector: '[data-connector="slack"] [data-connector-action="connect"]', action: "click" }],
    ),
    "confirm-disconnect": variant(base, "Disconnect asks inline first; the stored sign-in is deleted at once.", [
      {
        selector: '[data-connection="conn_aaaaaaaaaaaaaaaaaaaa"] [data-connector-action="disconnect"]',
        action: "click",
      },
    ]),
    "signed-out": variant({ available: true, signedIn: false }, "Signed out: one line pointing to Accounts."),
    unavailable: variant({ available: false }, "A preview build: no platform, one line."),
  },
});
