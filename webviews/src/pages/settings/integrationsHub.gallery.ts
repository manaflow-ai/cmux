// l10n-allow-file: gallery fixtures (sample accounts, charges, rules and audit lines), not shipped UI.
// Settings > Integrations (IntegrationsHubCard): four tabs under the header. Connections holds the
// hosted MCP catalog grid (ConnectionsPanel) above the linked Stripe and GitHub accounts; Approvals
// the calls waiting for the person with Approve once, Approve and don't ask again and Deny; Rules
// and Audit beside them. Reconnect on a dead key, the pause switch.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import {
  connected,
  CONNECTIONS_UPCOMING_LAB,
  ensureConnectionsUpcomingLabRow,
  MOCK_CATALOG,
  mockConnectionsCatalog,
  mockConnectionsState,
} from "./mockConnections";
import { MOCK_HUB_GITHUB, MOCK_HUB_STRIPE, mockHubOverview, mockHubState } from "./mockHub";

// The Upcoming Connections Labs row, until the checked-in export (regenerated on a Mac) lists it.
ensureConnectionsUpcomingLabRow();

const shown: PageFixtureStep = { selector: '[data-card="integrationsHub"]', action: "wait" };
const tab = (name: "connections" | "approvals" | "rules" | "audit"): PageFixtureStep => ({
  selector: `[data-hub-tab="${name}"]`,
  action: "click",
});
const grid: PageFixtureStep = { selector: "[data-connections-entry]", action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "integrations",
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-integrations-hub",
  title: "Settings Integrations",
  area: "Settings",
  height: 900,
  covers: [
    "pages/settings/components/IntegrationsHubCard.tsx#IntegrationsHubCard",
    "pages/settings/components/ConnectionsPanel.tsx#ConnectionsPanel",
  ],
  anchors: [{ selector: '[data-card="integrationsHub"]' }],
  variants: {
    shipped: variant({
      note: "One refund waits, so the hub opens on Approvals: its pinned summary, Approve once, Approve and don't ask again and Deny.",
    }),
    connections: variant({
      steps: [shown, tab("connections"), grid],
      note: "The Connections tab: the catalog grid in rank order (Linear for the team with 23 tools, Sentry yours with 14, then Atlassian, Notion and Vercel one tap each; Exa takes a pasted key, Figma says why it is not here), then the linked Stripe account.",
    }),
    "connections-top-five": variant({
      connections: mockConnectionsState(mockConnectionsCatalog(MOCK_CATALOG)),
      steps: [shown, tab("connections"), grid],
      note: "Nothing connected yet: Linear, Sentry, Atlassian, Notion and Vercel lead the grid, each one Connect.",
    }),
    "connections-upcoming": variant({
      options: { values: { [CONNECTIONS_UPCOMING_LAB]: true } },
      steps: [shown, tab("connections"), grid],
      note: "Labs > Upcoming Connections on: Slack, Gmail, Google Calendar and Google Drive list after the rest, each saying Not set up on this deployment yet, with no button.",
    }),
    "connections-vercel-pending": variant({
      connections: { ...mockConnectionsState(), pending: "vercel" },
      steps: [shown, tab("connections"), grid],
      note: "Connect on Vercel: the CLI listens on 127.0.0.1:47215 for the sign-in to come back, the tile waits, and the grid refreshes when it does.",
    }),
    "connections-team": variant({
      activeTeam: "team-acme",
      steps: [shown, tab("connections"), grid],
      note: "With Acme active, Connect asks whose the new connection is: just you, or Acme.",
    }),
    "connections-attention": variant({
      connections: mockConnectionsState(
        mockConnectionsCatalog(
          MOCK_CATALOG.map((entry) => {
            if (entry.name === "linear")
              return {
                ...connected(entry, "mcs_mock_linear", 23, "team"),
                state: "reconnect",
                statusLabel: "Sign in again",
                buttonLabel: "Reconnect",
              };
            if (entry.name === "sentry")
              return {
                ...connected(entry, "mcs_mock_sentry", 14),
                state: "enable",
                statusLabel: "Turned off",
                buttonLabel: "Turn On",
              };
            return entry;
          }),
        ),
      ),
      steps: [shown, tab("connections"), grid],
      note: "Linear's sign-in expired (Reconnect) and Sentry is turned off (Turn On); both keep Disconnect.",
    }),
    "connections-pending": variant({
      connections: { ...mockConnectionsState(), pending: "github" },
      steps: [shown, tab("connections"), grid],
      note: "Connect opened GitHub's sign-in in the browser: the tile waits, and the grid refreshes on return and every two seconds for a minute.",
    }),
    "connections-disconnect": variant({
      steps: [
        shown,
        tab("connections"),
        grid,
        { selector: '[data-connections-entry="sentry"] [data-connections-action="remove"]', action: "click" },
      ],
      note: "Disconnect asks first, inline, naming what the agents lose.",
    }),
    "connections-unavailable": variant({
      connections: { loading: false, problem: "unavailable", catalog: null, error: null, pending: null },
      steps: [shown, tab("connections")],
      note: "This build has no cmux CLI: the catalog says so in one line; the hub's accounts still show.",
    }),
    rules: variant({
      steps: [shown, tab("rules")],
      note: "The Rules tab: what each rule covers and does; the team rule has no Remove.",
    }),
    audit: variant({
      steps: [shown, tab("audit")],
      note: "The Audit tab: recent agent calls, each with what happened.",
    }),
    empty: variant({
      hub: mockHubState(
        mockHubOverview({ connections: [], hasStripe: false, hasGithub: false, approvals: [], rules: [], audit: [] }),
      ),
      note: "Nothing linked: the Link Stripe form says which restricted key to make; Link GitHub is one button.",
    }),
    paused: variant({
      hub: mockHubState(
        mockHubOverview({
          paused: true,
          pausedText: "Paused: every agent call is refused until you turn this off.",
          connections: [
            MOCK_HUB_STRIPE,
            { ...MOCK_HUB_GITHUB, healthy: false, statusLabel: "Needs to be linked again", reconnect: "link" },
          ],
          hasGithub: true,
          approvals: [],
        }),
      ),
      note: "Paused, both accounts linked (GitHub must be linked again: Reconnect); no approvals, so it opens on Connections.",
    }),
    "needs-new-key": variant({
      hub: mockHubState(
        mockHubOverview({
          connections: [{ ...MOCK_HUB_STRIPE, healthy: false, statusLabel: "Needs a new key", reconnect: "key" }],
          approvals: [],
        }),
      ),
      note: "Stripe refused the stored key (needs_reauth): the row says so and offers Reconnect next to Remove.",
    }),
    "reconnect-key": variant({
      hub: mockHubState(
        mockHubOverview({
          connections: [{ ...MOCK_HUB_STRIPE, healthy: false, statusLabel: "Needs a new key", reconnect: "key" }],
          approvals: [],
        }),
      ),
      steps: [
        shown,
        { selector: '[data-hub-connection="hubc_mock_stripe"] [data-hub-action="reconnect"]', action: "click" },
      ],
      note: "Reconnect opens the restricted-key form inside the account's row, keeping its sharing.",
    }),
    "live-key-refused": variant({
      hub: {
        ...mockHubState(mockHubOverview({ connections: [], hasStripe: false, approvals: [] })),
        error: {
          action: "link",
          code: "stripe.live_not_yet",
          message: "Live Stripe keys are not supported yet. Paste a test key (rk_test_).",
        },
      },
      note: "A pasted live key: the hub's stripe.live_not_yet message, shown as it came.",
    }),
    "remove-confirm": variant({
      steps: [
        shown,
        tab("connections"),
        { selector: '[data-hub-connection="hubc_mock_stripe"] [data-hub-action="remove"]', action: "click" },
      ],
      note: "Remove asks first, inline, and says the stored key is deleted.",
    }),
    "add-rule": variant({
      steps: [shown, tab("rules"), { selector: '[data-hub-action="addRule"]', action: "click" }],
      note: "Add rule: what it covers, what it does, and an amount cap in cents for Stripe.",
    }),
    "not-here": variant({
      hub: mockHubState({
        ok: true,
        available: false,
        message: "This cmux Cloud deployment has no integrations hub yet.",
        paused: false,
        connections: [],
        hasStripe: false,
        approvals: [],
        rules: [],
        audit: [],
      }),
      note: "A deployment without the hub: one calm line.",
    }),
    unavailable: variant({
      hub: { loading: false, problem: "unavailable", overview: null, error: null, lastCall: null },
      note: "This build has no cmux CLI: one short line.",
    }),
  },
});
