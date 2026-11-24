// l10n-allow-file: gallery fixtures (sample accounts, charges, rules and audit lines), not shipped UI.
// Settings > Integrations (IntegrationsHubCard): linked Stripe and GitHub accounts, the approvals
// waiting for the person with Allow, Deny and Don't ask again, rules, the pause switch and audit.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { MOCK_HUB_GITHUB, MOCK_HUB_STRIPE, mockHubOverview, mockHubState } from "./mockHub";

const shown: PageFixtureStep = { selector: '[data-card="integrationsHub"]', action: "wait" };
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
  covers: ["pages/settings/components/IntegrationsHubCard.tsx#IntegrationsHubCard"],
  anchors: [{ selector: '[data-card="integrationsHub"]' }],
  variants: {
    shipped: variant({
      note: "A Stripe test account; one refund waits with its pinned summary, Allow, Don't ask again and Deny; rules and recent activity.",
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
          connections: [MOCK_HUB_STRIPE, { ...MOCK_HUB_GITHUB, healthy: false, statusLabel: "Needs attention" }],
          hasGithub: true,
          approvals: [],
        }),
      ),
      note: "Paused, both accounts linked (GitHub needs attention), no approvals; the team rule has no Remove.",
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
        { selector: '[data-hub-connection="hubc_mock_stripe"] [data-hub-action="remove"]', action: "click" },
      ],
      note: "Remove asks first, inline, and says the stored key is deleted.",
    }),
    "add-rule": variant({
      steps: [shown, { selector: '[data-hub-action="addRule"]', action: "click" }],
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
