// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { HoverDemo, type HoverDemoProps } from "./MotionDemos";

const openMenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "More for Session Info tabs" });
  await ctx.waitFor(() => ctx.find({ testId: "motion-demo-receipt" }).textContent === "Menu open on row 2");
};

// Picked: scale. Hover fill over 80 ms, a revealed control in over 120 ms and out over 80 ms, nothing on
// the press (design/motion-and-polish.md rules 6 and 8). blink is what Leo called jarring, slow lags the
// pointer, press-dip is the click flash he called out.
export default componentEntry<HoverDemoProps>({
  id: "ui.motion-hover-feedback",
  title: "Hover and press feedback",
  area: "UI primitives",
  height: 200,
  covers: ["ui/motion/MotionDemos.tsx#HoverDemo"],
  load: async () => HoverDemo,
  styles: () => Promise.all([import("./motion.css"), import("./motion.gallery.css")]),
  variants: {
    scale: {
      note: "Picked: fill 80 ms; reveal in 120 / out 80; no press.",
      props: { timing: "scale" },
      play: openMenu,
    },
    blink: { note: "Before: appears and disappears in one frame.", props: { timing: "blink" }, play: openMenu },
    slow: { note: "Everything at 180 ms.", props: { timing: "slow" }, play: openMenu },
    "press-dip": { note: "Rejected: a dip and shrink on the press.", props: { timing: "press-dip" }, play: openMenu },
  },
});
