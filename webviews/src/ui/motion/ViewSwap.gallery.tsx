// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SwapDemo, type SwapDemoProps } from "./MotionDemos";

// The new panel is interactive on the frame of the click: a card in it takes a click at once.
const swapAndClick: Play = async (ctx) => {
  await ctx.click({ role: "tab", name: "Stats" });
  await ctx.waitFor(() => ctx.find({ testId: "motion-demo-receipt" }).textContent === "Stats");
  await ctx.click({ role: "button", name: "HP 5,736" });
  await ctx.click({ role: "tab", name: "Overview" });
  await ctx.waitFor(() => ctx.find({ testId: "motion-demo-receipt" }).textContent === "Overview");
};

// Picked: slide. It says where the new view comes from in 8 px and never hides content; sweep is the
// stylised wipe of the reference (private reference zenless-zone-zero/live/motion-sunbringer-menu-animation-sheet) kept for
// surfaces that want a performance; wipe hides part of the new view for up to 180 ms.
export default componentEntry<SwapDemoProps>({
  id: "ui.motion-view-swap",
  title: "View swap",
  area: "UI primitives",
  height: 260,
  anchors: [{ selector: ".motion-demo-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The swap animates the new panel's paint, never the layout around it." },
    settleMaxMs: {
      value: 300,
      reason: "Every look and the tab highlight end within the 240 ms ceiling after the click frame.",
    },
  },
  covers: ["ui/motion/ViewSwap.tsx", "ui/motion/MotionDemos.tsx#SwapDemo"],
  load: async () => SwapDemo,
  styles: () => Promise.all([import("./motion.css"), import("./motion.gallery.css")]),
  variants: {
    slide: {
      note: "Picked: fade and 8 px from its side, on the spring.",
      props: { look: "slide" },
      play: swapAndClick,
    },
    fade: { note: "Fade in over 120 ms.", props: { look: "fade" }, play: swapAndClick },
    sweep: { note: "Shown at once; an accent band crosses it once.", props: { look: "sweep" }, play: swapAndClick },
    wipe: { note: "A slanted edge reveals it over 180 ms.", props: { look: "wipe" }, play: swapAndClick },
    none: { note: "Before: the panel changes in one frame.", props: { look: "none" }, play: swapAndClick },
  },
});
