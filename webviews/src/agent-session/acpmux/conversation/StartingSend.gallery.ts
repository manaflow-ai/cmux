// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// A new chat's first prompt while its agent still starts (startingSends.ts `withStartingPrompt`):
// the chat's first row from the send, with the Thinking line under it in its start look, instead of
// a "sending" row in the composer's queue that jumps into the transcript once the agent is up (Leo,
// 2026-11-09: "there's the gap between when you send off a message versus otherwise, like it's like
// there's a one-two discontinuity. That's not good.").
import { agentPaneEntry } from "../../../gallery/format";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import { withStartingPrompt, type StartingSend } from "../startingSends";

const AT = Date.UTC(2026, 10, 9, 18, 0, 0);
const FIRST: StartingSend = {
  id: "gallery-first",
  text: "Find every retry loop and give them one capped backoff",
  attachments: [],
  at: AT,
  sentIn: { visit: 1 },
};
const SECOND: StartingSend = {
  id: "gallery-second",
  text: "Also cover the upload queue",
  attachments: [],
  at: AT + 2_000,
  sentIn: { visit: 1 },
};
const WITH_IMAGE: StartingSend = {
  ...FIRST,
  text: "Why does this banner show twice?",
  attachments: [
    {
      id: "gallery-shot",
      kind: "image",
      name: "banner.jpg",
      mimeType: "image/jpeg",
      size: 2_048,
      data: SCREEN_RECORDING_POSTER_JPEG,
    },
  ],
};
const queued = (send: StartingSend) => ({ id: send.id, prompt: send.text, sending: true });

export default agentPaneEntry({
  id: "agent-pane.starting-send",
  title: "A new chat's first prompt, while its agent starts",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/startingSends.ts", "agent-session/acpmux/conversation/Thinking.tsx"],
  variants: {
    "first-row": {
      note: "Picked. The prompt is the chat's first row from the Return, the Thinking line under it in its start look. When the agent is up, the chat's own row for it is the same row, so nothing moves.",
      snapshot: withStartingPrompt(noChat(), [FIRST]),
    },
    "queued-after": {
      note: "A second prompt sent while the agent still starts waits in the composer's queue, as it would behind any running turn.",
      snapshot: { ...withStartingPrompt(noChat(), [FIRST, SECOND]), queue: [queued(SECOND)] },
    },
    "with-image": {
      note: "A first prompt with a screenshot draws its image in its row from the send.",
      snapshot: withStartingPrompt(noChat(), [WITH_IMAGE]),
    },
    "before-queued": {
      note: "Before: the transcript stays empty and the prompt waits as a sending row in the composer's queue, then jumps into the transcript once the agent is up, with no Thinking line until then.",
      snapshot: { ...noChat(), queue: [queued(FIRST)] },
    },
  },
});
