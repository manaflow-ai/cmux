// l10n-allow-file: sample transcript and comparison labels, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

// A chat long enough that a view in its middle has rows under both soft edges.
const snapshot = chat(
  Array.from({ length: 30 }, (_, index) => [
    user(`Check retry case ${index + 1}`, 80 - index * 2),
    assistant(
      `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt.\n\nThe next check verifies that the same response reaches the caller exactly once.`,
      79 - index * 2,
    ),
  ]).flat(),
);

const STYLE_ID = "soft-edges-gallery";

/// The soft edges as they were drawn before: the mask on the scroller, over the same opaque page.
const SCROLLER_MASK = `
  :root .acpmux-scroll > .acpmux-edges { display: none !important; }
  :root .acpmux-scroll.acpmux-scroll:is([data-fade-top], [data-fade-bottom], [data-docked]) {
    -webkit-mask-image: var(--acpmux-view-mask), linear-gradient(#000, #000),
      var(--acpmux-find-hole, linear-gradient(transparent, transparent)) !important;
    mask-image: var(--acpmux-view-mask), linear-gradient(#000, #000),
      var(--acpmux-find-hole, linear-gradient(transparent, transparent)) !important;
  }`;

/// The other candidate: one still layer over the whole view in the page's color, cut by the same
/// ramp as a mask. The same pixels as the bands, but its mask is an offscreen pass over the whole view.
const STATIC_MASK = `
  :root .acpmux-edges__veil::before, :root .acpmux-edges__veil::after { content: none !important; }
  :root .acpmux-edges__veil {
    bottom: auto;
    background: linear-gradient(var(--acpmux-veil-ink), var(--acpmux-veil-ink)), var(--acpmux-veil-ground);
    --ramp: linear-gradient(to bottom, #000 var(--acpmux-veil-top),
      transparent calc(var(--acpmux-veil-top) + var(--acpmux-veil-top-fade)),
      transparent calc(100% - var(--acpmux-veil-dock) - var(--acpmux-veil-bottom-fade)),
      #000 calc(100% - var(--acpmux-veil-dock)));
    -webkit-mask-image: var(--ramp);
    mask-image: var(--ramp);
  }`;

/// The view rests in the chat's middle, scrolled up from the latest row: both edges draw at full reach.
const middle =
  (css?: string, seeThrough = false): Play =>
  async (ctx) => {
    ctx.document.getElementById(STYLE_ID)?.remove();
    if (css) {
      const style = ctx.document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = css;
      ctx.document.head.append(style);
    }
    if (seeThrough) {
      const root = ctx.document.documentElement;
      root.setAttribute("data-cmux-see-through", "");
      root.style.setProperty("--cmux-surface-background", "transparent");
    }
    await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 2_000);
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_200);
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest:not(.acpmux-jump-up)[data-shown]"));
    const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const veil = scroller.querySelector<HTMLElement>(".acpmux-edges");
    const veiled = veil !== null && getComputedStyle(veil).display !== "none";
    const masked = getComputedStyle(scroller).maskImage.includes("gradient");
    if (veiled === masked) throw new Error(`soft edges drawn by ${veiled ? "both" : "neither"} the veil and the mask`);
  };

export default agentPaneEntry({
  id: "agent-pane.soft-edges",
  title: "Transcript soft edges: veil or mask",
  area: "Agent pane",
  height: 700,
  covers: ["agent-session/acpmux/conversation/conversation.css", "agent-session/acpmux/VirtualTranscript.tsx"],
  checks: {
    anchorMovePx: { value: 0, reason: "How the edges are drawn must not move the transcript or the composer." },
  },
  variants: {
    veil: {
      note: "Selected, opaque page: two still gradient bands in the page's color over the rows. The same pixels as the mask, with no mask pass on any scrolled frame.",
      snapshot,
      play: middle(),
    },
    "static-mask": {
      note: "Alternative, opaque page: one still layer in the page's color cut by the edge ramp as a mask. Same look; the mask still costs an offscreen pass over the whole view each frame.",
      snapshot,
      play: middle(STATIC_MASK),
    },
    "scroller-mask": {
      note: "Before, opaque page: the mask on the scroller, applied again to the whole view on every scrolled frame.",
      snapshot,
      play: middle(SCROLLER_MASK),
    },
    "see-through": {
      note: "See-through window: the backdrop is not one color, so the scroller's mask stays and rows dissolve into the window behind.",
      snapshot,
      play: middle(undefined, true),
    },
  },
});
