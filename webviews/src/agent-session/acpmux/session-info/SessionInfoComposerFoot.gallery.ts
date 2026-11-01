// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Session Info over the chat while the composer grows (Leo, 2026-10-31: "THE FACT THIS SHIT FUCKING
// EXPANDS WHEN THE COMPOSER GROWS OR SHRINKS IS... ok i guess but i feel like should have an
// animation... or maybe it should be out of focus when typing...? or idk i actually feel like there's
// decent behaviour here sometimes the claude code/chatgpt desktop just straight up make it a popover
// that hides when you click away when the viewport is indeed too small but idk"). Where the right
// gutter cannot hold it, the panel lies over the chat and stops above the composer's stack. The
// versions compared:
//   jump      the old card: its foot steps with every line the composer gains or loses.
//   steady    a fixed height to the pane's foot, the composer drawn over its bottom, which fades.
//   animated  the foot follows the composer's top on the composer's own motion (shipped, tall panes).
//   popover   in a short pane, a popover anchored under its toggle that a click elsewhere hides
//             (shipped, under SessionInfo.tsx POPOVER_BELOW_HEIGHT).
// Shipped: animated in a tall pane, popover in a short one (option d). `jump` and `steady` are the
// alternatives, drawn here by a stage-only stylesheet the play adds.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../../gallery/play";

const snapshot = chat(
  Array.from({ length: 12 }, (_, index) => [
    user(`Check part ${index + 1} of the plan and say what is left`, 40 - index * 2),
    assistant(
      `Part ${index + 1} is checked. The retry helper keeps its backoff, the tests for it pass, and the one open item is the timeout on slow networks.`,
      39 - index * 2,
    ),
  ]).flat(),
);
/// The app offers Session Info (Debug Settings `agent.inspector`, on by default).
const native = { "pane.tabState": { inspector: true } };

const panel = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-session-info[data-presence=shown]");

const opened: Play = async (ctx) => {
  await ctx.waitFor(() => panel(ctx), { capMs: 3000 });
};

/// A stage-only stylesheet for an alternative the app does not ship.
const restyle = (ctx: PlayContext, css: string) => {
  const style = ctx.document.createElement("style");
  style.textContent = css;
  ctx.document.head.append(style);
};

const typeDraft: Play = async (ctx) => {
  await opened(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md"));
  await ctx.type("Then document the cap", { selector: ".acpmux-md" });
  for (let line = 0; line < 4; line++) {
    await ctx.press("Shift+Enter");
    await ctx.type(`and line ${line + 2} of the note`);
  }
};

const JUMP = `.acpmux-session-info[data-over-chat] { transition-property: opacity, translate !important; }`;
const STEADY = `.acpmux-session-info[data-over-chat] {
  max-height: calc(100% - var(--acpmux-session-info-top, 0px) - var(--acpmux-session-info-inset)) !important;
  mask-image: linear-gradient(to bottom, black calc(100% - 96px), transparent);
}`;

const typeChecks = {
  layoutShiftMax: {
    value: 0.02,
    reason: "The composer grows a line upward at each Shift-Enter, and the panel's foot with it: the state under test.",
  },
};

export default agentPaneEntry({
  id: "agent-pane.inspector-composer-foot",
  title: "Session Info over the chat while the composer grows",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 560, normal: 700, wide: 900 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx#sessionInfoPopover"],
  variants: {
    animated: {
      note: "Shipped (tall pane): a five-line draft; the panel's foot follows the composer's top with an animation, never a jump.",
      snapshot,
      native,
      play: typeDraft,
      checks: typeChecks,
    },
    jump: {
      note: "Alternative (the old card): the same draft; the panel's foot steps with every line.",
      snapshot,
      native,
      play: async (ctx) => {
        restyle(ctx, JUMP);
        await typeDraft(ctx);
      },
      checks: typeChecks,
    },
    steady: {
      note: "Alternative: a fixed height to the pane's foot; the composer lies over its faded bottom, so typing never resizes it.",
      snapshot,
      native,
      play: async (ctx) => {
        restyle(ctx, STEADY);
        await typeDraft(ctx);
      },
      checks: typeChecks,
    },
    popover: {
      note: "Shipped (short pane): a popover under its toggle, taking the room to the pane's foot over the composer.",
      height: 440,
      snapshot,
      native,
      play: async (ctx) => {
        await opened(ctx);
        if (!ctx.document.querySelector(".acpmux-session-info[data-popover]"))
          throw new Error("In a 440px pane over the chat, Session Info is not a popover");
      },
    },
    "popover-click-away": {
      note: "Shipped (short pane): a click in the composer hides the popover; its toggle brings it back.",
      height: 440,
      snapshot,
      native,
      play: async (ctx) => {
        await opened(ctx);
        // A press at the composer (its centre may lie under the popover).
        ctx.document
          .querySelector(".acpmux-md")
          ?.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, composed: true }));
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-session-info"), { capMs: 3000 });
      },
    },
  },
});
