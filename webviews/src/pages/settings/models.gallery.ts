// l10n-allow-file: gallery fixtures (sample addresses, machine and team names), not shipped UI.
// Settings > Models (ModelsCard): the person's connections in thread order, the organization's,
// the members policy and the Add a Connection sheet (cmux-tui/docs/model-connections.md).
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockModels } from "./mockModels";
import type { ModelsState } from "./ops";

const shown: PageFixtureStep = { selector: '[data-card="models"]', action: "wait" };
const variant = (models: ModelsState, note: string, steps: PageFixtureStep[] = [shown]): SettingsPageVariant => ({
  section: "models",
  models,
  steps,
  note,
});

export default settingsPageEntry({
  id: "pages.settings-models",
  title: "Settings Models",
  area: "Settings",
  height: 820,
  covers: ["pages/settings/components/ModelsCard.tsx#ModelsCard"],
  anchors: [{ selector: '[data-card="models"]' }],
  variants: {
    empty: variant(mockModels.empty, "No connections and no team: the empty rows and the + to add one."),
    "mac-logins": variant(
      mockModels.macLogins,
      "This Mac's Codex and Claude Code logins and an OpenRouter key (each This Mac only), a ChatGPT plan and a Claude Code token in thread order; the team's shared key; the members policy.",
    ),
    "chatgpt-pending": variant(
      mockModels.chatgptPending,
      "Continue with ChatGPT pressed: waiting on the browser, with Cancel.",
    ),
    "chatgpt-error": variant(
      mockModels.chatgptError,
      "The ChatGPT sign-in came back without plan access: the reason in plain words and Try Again.",
    ),
    "add-sheet": variant(mockModels.macLogins, "The Add a Connection sheet: search, Subscriptions and API keys.", [
      shown,
      { selector: '[data-models-action="add"]', action: "click" },
      { selector: "[data-models-sheet]", action: "wait" },
    ]),
    "add-key": variant(mockModels.macLogins, "Add a Connection > Anthropic: the key field and an optional label.", [
      shown,
      { selector: '[data-models-action="add"]', action: "click" },
      { selector: '[data-models-choice="anthropic"]', action: "click" },
      { selector: "[data-models-key-form]", action: "wait" },
    ]),
    "claude-token": variant(
      mockModels.macLogins,
      "Add a Connection > Claude Code: Open Terminal runs claude setup-token, then paste the token it prints.",
      [
        shown,
        { selector: '[data-models-action="add"]', action: "click" },
        { selector: '[data-models-choice="claude"]', action: "click" },
        { selector: "[data-models-claude-form]", action: "wait" },
      ],
    ),
    "claude-token-invalid": variant(
      mockModels.macLogins,
      "A pasted value that is not a setup token: the plain-words hint, and Add Token stays off.",
      [
        shown,
        { selector: '[data-models-action="add"]', action: "click" },
        { selector: '[data-models-choice="claude"]', action: "click" },
        { selector: '[data-models-claude-form] input[type="password"]', action: "input", value: "not a token" },
      ],
    ),
    member: variant(mockModels.member, "A member: the organization's connections and the members policy read only."),
  },
});
