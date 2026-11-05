// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { IndicatorDemo, type IndicatorDemoProps } from "./MotionDemos";

const switchTabs: Play = async (ctx) => {
  await ctx.click({ role: "tab", name: "Stats" });
  await ctx.waitFor(() => ctx.find({ testId: "motion-demo-receipt" }).textContent?.startsWith("Stats"));
  await ctx.click({ role: "tab", name: "Skills" });
  await ctx.click({ role: "button", name: "Session" });
  await ctx.waitFor(() => ctx.find({ testId: "motion-demo-receipt" }).textContent === "Skills · Session");
};

// Picked: pill-spring. The reference (a game character menu, private reference
// zenless-zone-zero/live/motion-sunbringer-menu-animation-sheet) is a chunky pill whose fill slides between tabs; the spring
// lands it fast (settled by ~140 ms) with a touch of give, while the labels change on the click.
export default componentEntry<IndicatorDemoProps>({
  id: "ui.motion-sliding-indicator",
  title: "Sliding selection indicator",
  area: "UI primitives",
  height: 220,
  anchors: [{ selector: ".motion-demo-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The highlight moves on transform only; nothing around the tabs moves." },
    settleMaxMs: {
      value: 300,
      reason: "The highlight travels on transform for the 240 ms spring after the click frame.",
    },
  },
  covers: ["ui/motion/SlidingIndicator.tsx", "ui/motion/MotionDemos.tsx#IndicatorDemo"],
  load: async () => IndicatorDemo,
  styles: () => Promise.all([import("./motion.css"), import("./motion.gallery.css")]),
  variants: {
    "pill-spring": { note: "Picked: chunky pill on the one spring.", props: { look: "pill" }, play: switchTabs },
    "pill-ease": {
      note: "The pill on the ease-out at 180 ms.",
      props: { look: "pill", travel: "ease" },
      play: switchTabs,
    },
    "plate-spring": { note: "The toolbar's quiet plate, travelling.", props: { look: "plate" }, play: switchTabs },
    "underline-spring": { note: "A 2 px underline.", props: { look: "underline" }, play: switchTabs },
    today: { note: "Before: each item fills itself at once.", props: { look: "today" }, play: switchTabs },
  },
});
