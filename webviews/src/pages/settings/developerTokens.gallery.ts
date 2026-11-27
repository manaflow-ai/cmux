// l10n-allow-file: gallery fixtures (sample token names, repositories and people), not shipped UI.
// Settings > Developer (DeveloperTokensCard): API tokens. Personal tokens with scope chips, expiry,
// last use and Revoke; New Token's form (scopes with what each allows, Expiration with a warning on No
// expiration, an optional spend cap); the token shown once with Copy and the lines to paste; and for
// a team admin, Team Tokens and GitHub Actions with its workflow.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockTeamAdminTokensState, mockTokensState } from "./mockTokens";

const shown: PageFixtureStep = { selector: '[data-card="developerTokens"]', action: "wait" };
const rows: PageFixtureStep = { selector: '[data-tokens-group="me"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "developer",
  steps: [shown, rows],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-developer-tokens",
  title: "Settings Developer",
  area: "Settings",
  // Tall enough for a team admin's page through the GitHub Actions workflow.
  height: 1300,
  covers: ["pages/settings/components/DeveloperTokensCard.tsx#DeveloperTokensCard"],
  anchors: [{ selector: '[data-card="developerTokens"]' }],
  variants: {
    shipped: variant({
      note: "Two personal tokens: Deploy script (Machines, Chats; expires in 50 days, used 2 hours ago, $50 cap) and Usage dashboard (Usage; never expires, never used), each with Revoke.",
    }),
    empty: variant({
      tokens: mockTokensState({ tokens: [] }),
      note: "No tokens yet: one line and New Token.",
    }),
    "create-form": variant({
      tokens: mockTokensState({ tokens: [] }),
      steps: [
        shown,
        rows,
        { selector: '[data-tokens-action="new"]', action: "click" },
        { selector: '[data-tokens-form="me"]', action: "wait" },
      ],
      note: "New Token: Name, the three scopes with what each allows (Machines and Chats checked), Expiration (90 days) and an optional spend cap.",
    }),
    "create-no-expiration": variant({
      tokens: mockTokensState({ tokens: [] }),
      steps: [
        shown,
        rows,
        { selector: '[data-tokens-action="new"]', action: "click" },
        { selector: "[data-tokens-expiration]", action: "change", value: "never" },
        { selector: "[data-tokens-never-warning]", action: "wait" },
      ],
      note: "No expiration picked: the warning under the fields says it works until revoked.",
    }),
    created: variant({
      tokens: mockTokensState({ tokens: [] }),
      steps: [
        shown,
        rows,
        { selector: '[data-tokens-action="new"]', action: "click" },
        { selector: "[data-tokens-name]", action: "input", value: "Deploy script" },
        { selector: '[data-tokens-action="create"]', action: "click" },
        { selector: "[data-tokens-created]", action: "wait" },
      ],
      note: "Right after Create Token: the token once, with Copy, the won't-be-shown-again line, the export CMUX_TOKEN line and a curl to try, then Done.",
    }),
    revoke: variant({
      steps: [
        shown,
        rows,
        { selector: '[data-tokens-id="tok_mock_deploy"] [data-tokens-action="revoke"]', action: "click" },
        { selector: "[data-tokens-confirm]", action: "wait" },
      ],
      note: "Revoke asks first, inline: anything using the token stops right away.",
    }),
    "team-admin": variant({
      tokens: mockTeamAdminTokensState(),
      note: "A team admin: Personal Tokens, Team Tokens (Nightly evals, by Sam Ortiz) and GitHub Actions with acme/web on main in production, Allow Repository and the workflow to copy.",
    }),
  },
});
