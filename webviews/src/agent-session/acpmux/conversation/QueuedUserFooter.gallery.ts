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
// earlier one keeps Copy and ×; each row's last control ends on its own bubble's right edge.
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
/// control's ink ends on the bubble's right edge, and the glyphs are the sent row's gap under the
/// bubble. The order is Copy, ×, Send now, and Copy shows only on hover (Leo, 2026-11-03: "the copy
/// is always showing for no reason... plus the order is wrong").
const checkAligned = (ctx: PlayContext) => {
  const bubbleOf = (row: Element) => row.querySelector(".cv-user__bubble")!.getBoundingClientRect();
  // Copy's glyph in a row, never a version chevron.
  const copyGlyph = (row: Element) => row.querySelector('.cv-user__actions [aria-label="Copy"] > svg')!.getBoundingClientRect();
  // The ink of a row's last control: its glyph, or Send now's text.
  const lastInk = (row: Element) => {
    const last = row.querySelector(".cv-user__pending .cv-message-footer-row")!.lastElementChild!;
    const glyph = last.querySelector("svg");
    if (glyph) return glyph.getBoundingClientRect();
    const range = ctx.document.createRange();
    range.selectNodeContents(last);
    return range.getBoundingClientRect();
  };
  const rows = [...ctx.document.querySelectorAll(".cv-user")].filter((row) => row.querySelector(".cv-user__bubble"));
  const sent = rows.find((row) => !row.querySelector(".cv-user__pending"));
  const waiting = rows.filter((row) => row.querySelector(".cv-user__pending"));
  if (!sent || waiting.length === 0) throw new Error("no sent prompt or waiting steer to compare");
  const referenceTop = copyGlyph(sent).top - bubbleOf(sent).bottom;
  for (const row of waiting) {
    const controls = [...row.querySelector(".cv-user__pending .cv-message-footer-row")!.children];
    const order = controls.map((el) =>
      el.matches(".cv-user__pending-copy") ? "copy" : el.matches(".cv-user__take-back") ? "x" : el.matches(".cv-user__send-now") ? "send" : "other",
    );
    const expected = ["copy", "x", "send"].filter((name) => order.includes(name));
    if (order.filter((name) => name !== "other").join() !== expected.join())
      throw new Error(`a waiting steer's controls are out of order: ${order.join(", ")}`);
    if (Math.abs(lastInk(row).right - bubbleOf(row).right) > 1)
      throw new Error("a waiting steer's last control is not on its bubble's right edge");
    if (Math.abs(copyGlyph(row).top - bubbleOf(row).bottom - referenceTop) > 1)
      throw new Error("a waiting steer's controls are not the sent row's gap under the bubble");
    // At rest only Send now and × show; a row's Copy shows once the pointer is on it (checkCopyShown).
    if (!row.matches(":hover") && copyOpacity(ctx, row) !== "0")
      throw new Error("a waiting steer's Copy shows without the pointer on it");
  }
};
const copyOpacity = (ctx: PlayContext, row: Element) =>
  ctx.document.defaultView!.getComputedStyle(row.querySelector(".cv-user__pending-copy")!).opacity;
/// The hovered waiting steer's Copy fades in, as a sent prompt's actions do.
const checkCopyShown = (ctx: PlayContext) =>
  ctx.waitFor(() => {
    const row = [...ctx.document.querySelectorAll(".cv-user")].find((r) => r.matches(":hover") && r.querySelector(".cv-user__pending"));
    return Boolean(row && copyOpacity(ctx, row) === "1");
  });
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
  if (!gap) {
    checkAligned(ctx);
    await checkCopyShown(ctx);
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
      note: "Chosen: the right-aligned footer uses the sent prompt's shared control slots for Copy (on hover), remove and Send now, with no receipt, time or Retry.",
      snapshot: snapshot(),
      play: preview(),
    },
    roomy: {
      note: "Alternative: a roomier 12px control gap while keeping the footer under the bubble.",
      snapshot: snapshot(),
      play: preview("12px"),
    },
    stack: {
      note: "Two waiting steers: the newest offers Send now, the earlier keeps Copy and ×; both rows end on their bubble's right edge, the sent row's gap under it.",
      snapshot: stack(),
      play: async (ctx) => {
        await ctx.hover({ text: TEXT });
        checkAligned(ctx);
        await checkCopyShown(ctx);
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
