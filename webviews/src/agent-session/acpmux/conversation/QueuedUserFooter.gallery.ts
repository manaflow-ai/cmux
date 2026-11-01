// l10n-allow-file: gallery fixture prompts, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const TEXT = "Use the cache directory for the next run";
const snapshot = (steer: "waiting" | "landed" = "waiting") => {
  const state = chat(
    [
      user("Check the cache", 4),
      assistant("Checking the cache.", 3, { streaming: true }),
      user(TEXT, 1, { steer, steerPromptId: "p-footer-gallery" }),
    ],
    { isWorking: true },
  );
  return {
    ...state,
    summary: { ...state.summary!, harness: "claude-sr2", family: "claude-sr2", steering: true, backgroundsWork: true },
  };
};
const preview = (gap?: string) => async (ctx: PlayContext) => {
  await ctx.hover({ text: TEXT });
  const pending = ctx.document.querySelector<HTMLElement>(".cv-user__pending");
  const footer = pending?.querySelector<HTMLElement>(".cv-message-footer-row");
  if (footer && gap) footer.style.gap = gap;
  const actions = pending?.parentElement;
  const bubble = pending?.closest(".cv-user")?.querySelector<HTMLElement>(".cv-user__bubble");
  if (actions?.querySelector(".cv-user__time, .cv-user__read, .cv-user__dot, .cv-message-retry"))
    throw new Error("queue footer includes normal hover actions");
  if (pending && bubble) {
    const bubbleBox = bubble.getBoundingClientRect();
    const footerBox = actions!.getBoundingClientRect();
    if (footerBox.top < bubbleBox.bottom || Math.abs(footerBox.right - bubbleBox.right) > 1)
      throw new Error("waiting steer footer is not under the bubble's right edge");
  }
};
export default agentPaneEntry({
  id: "agent-pane.queued-user-footer",
  title: "Queued user footer",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/PendingSteer.tsx",
    "agent-session/acpmux/conversation/UserBubble.tsx#UserBubble",
    "agent-session/acpmux/conversation/MessageActions.tsx#PromptActions",
  ],
  variants: {
    compact: {
      note: "Alternative: a compact footer with a 2px gap between controls.",
      snapshot: snapshot(),
      play: preview("2px"),
    },
    balanced: {
      note: "Chosen: the right-aligned footer uses the sent prompt's shared control slots for Send now, remove and Copy, with no receipt, time or Retry.",
      snapshot: snapshot(),
      play: preview(),
    },
    roomy: {
      note: "Alternative: a roomier 12px control gap while keeping the footer under the bubble.",
      snapshot: snapshot(),
      play: preview("12px"),
    },
    accepted: {
      note: "Send now accepted while the agent still reports waiting: only normal hover actions remain.",
      snapshot: snapshot(),
      native: { "chat.queue.edit": { ok: true, sent: "now" } },
      play: async (ctx) => {
        await ctx.hover({ text: TEXT });
        await ctx.click({ selector: ".cv-user__send-now" });
        await ctx.waitFor(() => !ctx.document.querySelector(".cv-user__pending"));
      },
    },
    read: {
      note: "The agent read the prompt: only normal hover actions, with no check or dot.",
      snapshot: snapshot("landed"),
      play: async (ctx) => ctx.hover({ text: TEXT }),
    },
  },
});
