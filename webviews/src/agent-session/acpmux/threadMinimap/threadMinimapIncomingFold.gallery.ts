// l10n-allow-file: gallery fixtures (sample prompts, senders and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "../conversation/incomingMessage";
import { threadMinimapIncoming } from "./incoming.experiment";

// Runs of messages from other chats on the compact rail, compared arm by arm (incoming.experiment.ts;
// Leo, 2026-11-03: "i've always been on the fence about messages from other chats showing up in that
// prompt jump scroll rail individual elements"). Every arm keeps them on the rail in the one column
// every tick shares at rest (cmux#32637). The compare view renders each arm beside the others.
// Synthetic prompts and senders only.
const message = (seq: number, sender: string, minutes: number, text: string) => {
  const incoming = incomingPrompt(text, {
    _meta: { provenance: { kind: "session_message", from: `${sender}-id`, fromName: sender, to: "me" } },
  });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { id: `user-${seq}`, incoming, resend: text })
    : user(text, minutes, { id: `user-${seq}` });
};
const answered = (seq: number, minutes: number) => [
  assistant(`Checked step ${seq}.\n\nA second paragraph so the turn has some height.`, minutes - 0.2),
  summary(minutes - 0.4, { status: "completed" }),
];
/// The person's prompts with two runs of other chats' messages: three from one sender after prompt 3,
/// two from two senders after prompt 6, and single messages in between.
const PLAN: ({ sender: string } | { prompt: string })[] = [
  { prompt: "Plan the rail change" },
  { prompt: "Write the failing test first" },
  { prompt: "Now the fix" },
  { sender: "lane-box-1/ux-owner" },
  { sender: "lane-box-1/ux-owner" },
  { sender: "lane-box-1/ux-owner" },
  { prompt: "Reply to the review" },
  { prompt: "Rebase on the base branch" },
  { sender: "lane-box-3/review-router" },
  { prompt: "Push it" },
  { sender: "lane-box-3/review-router" },
  { sender: "lane-box-2/picker" },
  { prompt: "Land it" },
  { prompt: "File the follow-ups" },
];
const rows = PLAN.flatMap((step, index) => {
  const seq = index * 3 + 1;
  const minutes = 300 - index * 2;
  const head =
    "sender" in step
      ? message(seq, step.sender, minutes, `Status ${index + 1}: the helper's branch is green and the review passed.`)
      : user(`Prompt ${index + 1}: ${step.prompt}`, minutes, { id: `user-${seq}` });
  return [head, ...answered(seq, minutes)];
});

/// The first message of the first run: tick 3 in every arm.
const FIRST_RUN = '[data-tick="3"]';
const ready = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(FIRST_RUN));
};

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-incoming-fold",
  title: "Thread minimap: runs of messages from other chats",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapIncoming,
    setup: ready,
    script: [
      { name: "hover the first run", run: (ctx) => ctx.hover({ selector: FIRST_RUN }) },
      { name: "hover a prompt", run: (ctx) => ctx.hover({ selector: '[data-tick="0"]' }) },
    ],
  },
  variants: {
    rest: {
      note: "At rest: the person's prompts, a run of three messages from one chat, a single message, and a run of two from two chats. The default folds each run into one tick and draws other chats' ticks a step dimmer, in the same column.",
      snapshot: chat(rows, { title: "Runs of messages from other chats" }),
      play: ready,
    },
    "run-hovered": {
      note: 'The pointer on the first run: the folded tick\'s card reads "Received 3 messages" from ux-owner, with its bookmark.',
      snapshot: chat(rows, { title: "A hovered run of messages" }),
      play: async (ctx) => {
        await ready(ctx);
        await ctx.hover({ selector: FIRST_RUN });
      },
    },
  },
});
