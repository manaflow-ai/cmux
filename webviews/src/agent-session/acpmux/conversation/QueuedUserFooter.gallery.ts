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
// Three waiting steers, oldest first: only the newest offers Send now (#31419), the earlier ones keep
// Copy and × on hover; each row's last control ends on its own bubble's right edge.
const stack = () => {
  const state = chat(
    [
      user("Check the cache", 4),
      assistant("Checking the cache.", 3, { streaming: true }),
      user("Use the cache dir, not tmp", 1.5, { id: "user-steer-1", steer: "waiting", steerPromptId: "p-steer-1" }),
      user("And keep the old run's logs", 1, { id: "user-steer-2", steer: "waiting", steerPromptId: "p-steer-2" }),
      user(TEXT, 0.5, { id: "user-steer-3", steer: "waiting", steerPromptId: "p-steer-3" }),
    ],
    { isWorking: true, newestOwnSteer: "user-steer-3" },
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
  // Each row's last control's ink (Send now's words, or the last glyph) against its bubble's right
  // edge, and Copy's glyph against its bottom (never a version chevron).
  const copyGlyph = (row: Element) => {
    const bubble = row.querySelector(".cv-user__bubble")!.getBoundingClientRect();
    const copy = row.querySelector('.cv-user__actions [aria-label="Copy"] > svg')!.getBoundingClientRect();
    const send = row.querySelector(".cv-user__send-now");
    let right = [...row.querySelectorAll(".cv-user__actions .cv-iconbtn > svg")].at(-1)!.getBoundingClientRect().right;
    if (send) {
      const words = ctx.document.createRange();
      words.selectNodeContents(send);
      right = words.getBoundingClientRect().right;
    }
    return { right: right - bubble.right, top: copy.top - bubble.bottom };
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
  if (actions?.querySelector(".cv-user__time, .cv-user__read, .cv-user__dot"))
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
    checkOrder(ctx);
  }
};
/// Claude desktop's queued row (Leo, 2026-11-03: "the copy is always showing for no reason... plus the
/// order is wrong"): Copy first, the × then Send now last; everything but Send now only on hover.
const checkOrder = (ctx: PlayContext) => {
  const row = ctx.document.querySelector(".cv-user__pending:has(.cv-user__send-now)");
  if (!row) throw new Error("no waiting steer with Send now");
  const buttons = [...row.querySelectorAll("button")];
  if (buttons[0]?.getAttribute("aria-label") !== "Copy") throw new Error("Copy is not the queued row's first control");
  if (!buttons.at(-1)?.classList.contains("cv-user__send-now")) throw new Error("Send now is not last");
  if (!buttons.at(-2)?.classList.contains("cv-user__take-back")) throw new Error("× is not just before Send now");
};
const checkRest = async (ctx: PlayContext) => {
  const getComputedStyle = (element: Element) => ctx.document.defaultView!.getComputedStyle(element);
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll<HTMLElement>(".cv-user__queued-hover")].every(
      (group) => getComputedStyle(group).opacity === "0",
    ),
  );
  for (const send of ctx.document.querySelectorAll<HTMLElement>(".cv-user__send-now"))
    if (getComputedStyle(send.closest(".cv-user__actions")!).opacity !== "1") throw new Error("Send now hides at rest");
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
      note: "Chosen: Claude desktop's queued row, hovered: Copy, × and Send now last in the sent prompt's shared control slots, with no receipt or time.",
      snapshot: snapshot(),
      play: preview(),
    },
    roomy: {
      note: "Alternative: a roomier 12px control gap while keeping the footer under the bubble.",
      snapshot: snapshot(),
      play: preview("12px"),
    },
    rest: {
      note: "At rest, as Claude desktop: a waiting steer shows only Send now under its bubble; Copy and × wait for hover.",
      snapshot: snapshot(),
      play: checkRest,
    },
    stack: {
      note: "Three waiting steers, oldest first, hovering the newest: Copy, × then Send now; only the newest offers Send now, and every row ends on its bubble's right edge, the sent row's gap under it.",
      snapshot: stack(),
      play: async (ctx) => {
        await ctx.hover({ text: TEXT });
        checkAligned(ctx);
        checkOrder(ctx);
      },
    },
    "stack-rest": {
      note: "The same three steers at rest: only the newest's Send now shows.",
      snapshot: stack(),
      play: checkRest,
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
