// l10n-allow-file: gallery fixtures (sample automations, runs and a webhook secret), not shipped UI.
// Settings > Automations (AutomationsCard): cloud automations with their trigger, last run and
// switch; the form with conditions, the prompt preview against a sample event and limits; the run
// log; a new webhook's secret, once; and the template gallery.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { MOCK_AUTOCLOUD_CATALOG, mockAutocloudOverview, mockAutocloudState } from "./mockAutocloud";

const shown: PageFixtureStep = { selector: '[data-card="automationsCloud"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "automations",
  options: { values: { "labs.automations": true } },
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-automations",
  title: "Settings Automations",
  area: "Settings",
  height: 1100,
  covers: ["pages/settings/components/AutomationsCard.tsx#AutomationsCard"],
  anchors: [{ selector: '[data-card="automationsCloud"]' }],
  variants: {
    shipped: variant({
      note: "Three automations: CI fixes on acme/web (last run failed 3 minutes ago), a webhook for failed deploys, and a weekday schedule turned off; the template gallery below.",
    }),
    empty: variant({
      autocloud: mockAutocloudState(mockAutocloudOverview({ automations: [] })),
      note: "No automations yet: one line, then the templates, first among them the CI fix.",
    }),
    "template-form": variant({
      autocloud: mockAutocloudState(mockAutocloudOverview({ automations: [] })),
      steps: [
        shown,
        { selector: '[data-autocloud-template="ci-fix"] [data-autocloud-action="useTemplate"]', action: "click" },
        { selector: "[data-autocloud-repository]", action: "input", value: "acme/web" },
        { selector: '[data-autocloud-preview="match"]', action: "wait" },
      ],
      note: "Use on the CI fix template: GitHub CI fails on acme/web, two conditions, Claude Code on the PR's branch; the preview renders the prompt against a sample failure and says it would start the agent.",
    }),
    "edit-webhook": variant({
      steps: [
        shown,
        { selector: '[data-autocloud-automation="auto_mock_deploy"] [data-autocloud-action="edit"]', action: "click" },
        { selector: '[data-autocloud-preview="match"]', action: "wait" },
      ],
      note: "Editing the webhook automation: its URL, a condition on the body's type, Codex on acme/api with Open a pull request; the preview against a sample webhook body.",
    }),
    "webhook-created": variant({
      autocloud: mockAutocloudState(mockAutocloudOverview({ automations: [] })),
      steps: [
        shown,
        { selector: '[data-autocloud-action="new"]', action: "click" },
        { selector: "[data-autocloud-name]", action: "input", value: "Triage Sentry alerts" },
        { selector: "[data-autocloud-trigger-type]", action: "change", value: "webhook" },
        { selector: "[data-autocloud-repo]", action: "input", value: "acme/web" },
        { selector: "[data-autocloud-prompt]", action: "input", value: "Look into this alert: {{event.url}}" },
        { selector: '[data-autocloud-action="save"]', action: "click" },
        { selector: "[data-autocloud-secret]", action: "wait" },
      ],
      note: "A new webhook automation saved: its URL and signing secret show once, with Copy; I saved it drops the secret from the page.",
    }),
    "run-log": variant({
      steps: [
        shown,
        { selector: '[data-autocloud-automation="auto_mock_ci"] [data-autocloud-action="runs"]', action: "click" },
        { selector: '[data-autocloud-run="failed"]', action: "wait" },
      ],
      note: "Runs of the CI fix: a failed run with its error, comment and session links, a succeeded one with its pull request, and a skipped one with the condition that failed.",
    }),
    "remove-confirm": variant({
      steps: [
        shown,
        {
          selector: '[data-autocloud-automation="auto_mock_nightly"] [data-autocloud-action="remove"]',
          action: "click",
        },
      ],
      note: "Remove asks first, inline.",
    }),
    "save-refused": variant({
      autocloud: {
        ...mockAutocloudState(),
        error: {
          action: "create",
          code: "automation.invalid",
          message: "trigger.repository: acme/web is not linked to this team's GitHub app",
        },
      },
      steps: [shown, { selector: '[data-autocloud-action="new"]', action: "click" }],
      note: "The platform refused a save: its message under the form, as it came.",
    }),
    "not-here": variant({
      autocloud: mockAutocloudState({
        ok: true,
        available: false,
        message: "Cloud automations are not available on this cmux Cloud deployment yet.",
        automations: [],
        templates: [],
        catalog: MOCK_AUTOCLOUD_CATALOG,
      }),
      note: "A deployment without automations: one calm line.",
    }),
    unavailable: variant({
      autocloud: { loading: false, problem: "unavailable", overview: null, error: null },
      note: "A cmux without the autocloud command: the part is unavailable.",
    }),
  },
});
