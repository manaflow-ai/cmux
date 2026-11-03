// l10n-allow-file: gallery fixture prompts, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import { gridLength } from "../transcriptGrid";

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
// Two waiting steers: only the newest offers Send now (#31419), the
// earlier one keeps × and Copy; each row's Copy ends on its own bubble's right edge.
const stack = () => {
  const state = chat(
    [
      user("Check the cache", 4),
      assistant("Checking the cache.", 3, { streaming: true }),
      user("Use the cache dir, not tmp", 1, { id: "user-steer-1", steer: "waiting", steerPromptId: "p-steer-1" }),
      user(TEXT, 0.5, { id: "user-steer-2", steer: "waiting", steerPromptId: "p-steer-2" }),
    ],
    { isWorking: true, newestOwnSteer: "user-steer-2" },
  );
  return {
    ...state,
    summary: { ...state.summary!, harness: "claude-sr2", family: "claude-sr2", steering: true, backgroundsWork: true },
  };
};
/// Every waiting steer's controls sit as a sent prompt's row does (Leo, relayed 2026-11-03: "Send now
/// × and the copy icon float loosely under the bubble. Align them to the bubble's edge"): the last
/// glyph ends on the bubble's right edge, and the glyphs are the sent row's gap under the bubble.
const checkAligned = (ctx: PlayContext) => {
  // Copy's glyph in each row: the last control in both, and never a version chevron.
  const copyGlyph = (row: Element) => {
    const bubble = row.querySelector(".cv-user__bubble")!.getBoundingClientRect();
    const copy = row.querySelector('.cv-user__actions [aria-label="Copy"] > svg')!.getBoundingClientRect();
    return { right: copy.right - bubble.right, top: copy.top - bubble.bottom };
  };
  const rows = [...ctx.document.querySelectorAll(".cv-user")].filter((row) => row.querySelector(".cv-user__bubble"));
  const sent = rows.find((row) => !row.querySelector(".cv-user__pending"));
  const waiting = rows.filter((row) => row.querySelector(".cv-user__pending"));
  if (!sent || waiting.length === 0) throw new Error("no sent prompt or waiting steer to compare");
  const reference = copyGlyph(sent);
  for (const row of waiting) {
    const box = copyGlyph(row);
    if (Math.abs(box.right) > 1) throw new Error("a waiting steer's last control is not on its bubble's right edge");
    if (Math.abs(box.top - reference.top) > 1)
      throw new Error("a waiting steer's controls are not the sent row's gap under the bubble");
  }
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
    // The row overhangs the bubble's right edge by its control's inset, so the last glyph's ink sits
    // on that edge (conversation.css `--cv-action-overhang`: (control - icon box) / 2; #27580, #31683).
    const overhang = (gridLength("transcript-action-control") - gridLength("transcript-icon-box")) / 2;
    if (footerBox.top < bubbleBox.bottom || Math.abs(footerBox.right - overhang - bubbleBox.right) > 1)
      throw new Error("waiting steer footer is not under the bubble's right edge");
  }
  if (!gap) checkAligned(ctx);
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
    stack: {
      note: "Two waiting steers: the newest offers Send now, the earlier keeps × and Copy; both rows end on their bubble's right edge, the sent row's gap under it.",
      snapshot: stack(),
      play: async (ctx) => {
        await ctx.hover({ text: TEXT });
        checkAligned(ctx);
      },
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
