// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the card.
import { defineExperiment } from "../../../experiments/experiment";

/// How the sign-in card looks once a ChatGPT account signed in (DeviceSignInCard.tsx, `ChatGPTSignedIn`).
/// Leo, 2026-11-25: "the signed in page for chatgpt looks like ass on our end it should just follow at
/// least basic styling or guidance for signed in with chatgpt type stuff". Every arm follows OpenAI's
/// Sign in with ChatGPT guidance (developers.openai.com/siwc/ui-ux-guidelines): the ChatGPT mark on its
/// own black (light) or white (dark) tile, the plan named as ChatGPT's and kept apart from cmux's, and a
/// "Manage usage" link to chatgpt.com/settings/usage. Compare the arms in the gallery's
/// `settings.sign-in-chatgpt`.
export const chatgptSignedInLook = defineExperiment({
  id: "chatgpt-signed-in",
  title: "ChatGPT signed in",
  description: "The device sign-in card once a ChatGPT account signed in.",
  arms: {
    plan: {
      label: "Plan notice",
      description:
        "OpenAI's welcome notice: the brand tile, \"You're using your ChatGPT plan\", one line on usage, the account, Manage usage and Got it.",
    },
    account: {
      label: "Account card",
      description:
        'The account first: the brand tile with a check badge, the email large, "Signed in with ChatGPT", then the plan line.',
    },
    row: {
      label: "Compact row",
      description:
        'One row like a connected-account row: tile, "Signed in with ChatGPT" over the email, Manage usage and Done trailing.',
    },
  },
  defaultArm: "plan",
});
