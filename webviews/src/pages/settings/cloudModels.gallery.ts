// l10n-allow-file: gallery fixtures (sample addresses), not shipped UI.
// Settings > Cloud > Models for Cloud (CloudModelsCard): whether Claude, ChatGPT and an API key are set
// up for Cloud chats, with Set Up for each (cmux-tui/docs/model-connections.md, Revision 2).
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockModels } from "./mockModels";
import type { ModelsState } from "./ops";

const shown: PageFixtureStep = { selector: '[data-card="cloudModels"]', action: "wait" };
const variant = (models: ModelsState, note: string, steps: PageFixtureStep[] = [shown]): SettingsPageVariant => ({
  section: "cloud",
  models,
  steps,
  note,
});

export default settingsPageEntry({
  id: "pages.settings-cloud",
  title: "Settings Cloud",
  area: "Settings",
  height: 820,
  covers: ["pages/settings/components/CloudModelsCard.tsx#CloudModelsCard"],
  anchors: [{ selector: '[data-card="cloudModels"]' }],
  variants: {
    empty: variant(mockModels.empty, "Nothing connected: each row Not set up for Cloud, with its Set Up."),
    "mac-only": variant(
      mockModels.macOnly,
      "Only this Mac's Claude Code and Codex CLI logins: not set up for Cloud, each saying why in plain words.",
    ),
    "claude-token": variant(mockModels.claudeForCloud, "A Claude Code token: Claude is Connected for Cloud."),
    chatgpt: variant(mockModels.chatgptForCloud, "A ChatGPT plan: ChatGPT is Connected for Cloud."),
    "set-up-claude": variant(mockModels.macOnly, "Set Up on Claude: Models' Claude Code steps (setup-token, paste).", [
      shown,
      { selector: '[data-cloud-action="setUpClaude"]', action: "click" },
      { selector: "[data-models-claude-form]", action: "wait" },
    ]),
  },
});
