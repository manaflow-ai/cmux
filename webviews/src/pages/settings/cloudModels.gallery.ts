// l10n-allow-file: gallery fixtures (sample addresses), not shipped UI.
// Settings > Cloud > Models for Cloud (CloudModelOverview): whether Claude, ChatGPT and an API key are set
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
  covers: ["pages/settings/components/CloudModelsCard.tsx#CloudModelOverview"],
  anchors: [{ selector: '[data-card="cloudModels"]' }],
  variants: {
    empty: variant(mockModels.empty, "Nothing connected: each row Not set up for Cloud, with its Set Up."),
    "mac-only": variant(
      mockModels.macOnly,
      "Only this Mac's Claude Code and Codex CLI logins: not listed, every row Not set up for Cloud.",
    ),
    "claude-token": variant(mockModels.claudeForCloud, "A Claude Code token: Claude is Connected for Cloud."),
    chatgpt: variant(mockModels.chatgptForCloud, "A ChatGPT plan: ChatGPT is Connected for Cloud."),
    "chatgpt-signed-out": variant(mockModels.chatgptSignedOut, "The ChatGPT plan signed out: Sign in with ChatGPT."),
    "chatgpt-off": variant(mockModels.chatgptOff, "The ChatGPT plan turned off: Turn On, in place."),
    "connect-claude-starting": variant(
      mockModels.claudeStarting,
      "Connect Claude pressed: one progress line, Opening the Claude sign-in page…, with Cancel.",
    ),
    "connect-claude-signing-in": variant(
      mockModels.claudeSigningIn,
      "Waiting for you to sign in to Claude in the browser…, with Cancel.",
    ),
    "connect-claude-saving": variant(mockModels.claudeSaving, "Saving… once the browser handed the token back."),
    "connect-claude-error": variant(
      mockModels.claudeError,
      "The sign-in ended with an error: its words and Try Again.",
    ),
    "set-up-claude": variant(
      mockModels.macOnly,
      "Paste a token instead: Models dialog opens with the paste field out.",
      [
        shown,
        { selector: '[data-cloud-action="setUpClaude"]', action: "click" },
        { selector: "[data-models-claude-form]", action: "wait" },
      ],
    ),
  },
});
