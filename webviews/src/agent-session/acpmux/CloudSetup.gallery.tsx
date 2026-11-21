// l10n-allow-file: gallery fixtures (a sample prompt and model ids), not shipped UI.
//
// Set up Cloud (conversation/CloudSetupCard.tsx, cloudSetup.ts): Cloud first use. A Cloud send whose
// picked model no connection serves (cmux-tui/docs/model-connections.md, "Cloud first use") shows the
// card under the message instead of a failure; a button's way in runs on this Mac, and the chat starts
// by itself once a connection serving the model appears.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";

const needed: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "failed",
  folder: "paint",
  code: "cloud_setup_required",
  message: "cloud_setup_required",
  cloudSetup: { family: "claude", model: "claude-opus-5-5" },
};
const { code: _code, message: _message, ...asked } = needed;
const waiting: CloudStartProgress = { ...asked, state: "starting", signingIn: true };
const actions = { onSetUp: () => undefined, onSetUpDismiss: () => undefined };

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-setup",
  title: "Cloud start: Set up Cloud",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/CloudSetupCard.tsx",
    "agent-session/acpmux/cloudSetup.ts",
    "agent-session/acpmux/CloudStartView.tsx",
  ],
  keywords: ["cloud", "setup", "first use", "subscription", "connection", "chatgpt", "claude", "api key", "models"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 280,
  variants: {
    claude: {
      note: "A Claude model: the message, then Set up Cloud naming the model, Sign in to Claude first, Continue with ChatGPT, Add an API key, Open Settings and Not now.",
      props: { start: needed, ...actions },
    },
    codex: {
      note: "A Codex model: Continue with ChatGPT leads.",
      props: { start: { ...needed, cloudSetup: { family: "codex", model: "gpt-5.5-codex" } }, ...actions },
    },
    "no-model": {
      note: "The picker named no model (the agent's default): the body alone.",
      props: { start: { ...needed, cloudSetup: { family: "claude" } }, ...actions },
    },
    waiting: {
      note: "A button's way in is out (the browser sign-in, or Settings): the card waits for a connection with its buttons at rest; Not now withdraws the wait.",
      props: {
        start: waiting,
        ...actions,
      },
    },
    "long-model": {
      note: "A long model id wraps in the body without pushing the buttons off the card.",
      height: 320,
      props: {
        start: {
          ...needed,
          cloudSetup: { family: "codex", model: "openrouter/anthropic/claude-opus-5-5-preview-2026-11-01-long" },
        },
        ...actions,
      },
    },
  },
});
