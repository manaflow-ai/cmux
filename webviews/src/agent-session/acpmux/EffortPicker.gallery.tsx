// l10n-allow-file: gallery choices are fixture labels; the trigger uses the translated Effort label.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

const efforts = [
  { id: "low", name: "Low" },
  { id: "medium", name: "Medium" },
  { id: "high", name: "High", recommended: true },
  { id: "max", name: "Max" },
];

const speedChoices = [
  { id: "off", name: "Off" },
  { id: "on", name: "On" },
];

/// `slider`: the Debug Settings opt-in `agent.reasoningSlider`; `speed`: a Fast Mode section under it.
type Props = { slider?: boolean; sliderStyle?: "accent" | "minimal"; speed?: boolean };

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
};

const sliderKeyboard: Play = async (ctx) => {
  ctx.motion.start({
    kind: "reasoning-slider",
    target: ".acpmux-effort-track",
    visual: ".acpmux-effort-thumb",
    maxMs: 1200,
  });
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.activeElement?.classList.contains("acpmux-effort-range") ?? false);
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-effort-slider-level")?.textContent === "High");
  await ctx.press("End");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-effort-slider-level")?.textContent === "Max");
  const motion = ctx.motion.stop();
  if (!motion || motion.status === "fail")
    throw new Error(motion?.problems.join("; ") ?? "reasoning slider motion was not sampled");
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const trigger = ctx.find({ role: "button", name: "Effort" });
    return !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger;
  });
};

const keyboard: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => {
    const selected = ctx.document.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]');
    return selected !== null && ctx.document.activeElement === selected;
  });
  await ctx.press("ArrowDown");
  await ctx.waitFor(
    () =>
      ctx.document
        .querySelector<HTMLElement>('[role="menuitemradio"][data-highlighted]')
        ?.textContent?.includes("High") ?? false,
  );
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.document.querySelector(".acpmux-effort .acpmux-picker-button > span")?.textContent === "High",
  );
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const trigger = ctx.find({ role: "button", name: "Effort" });
    return !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger;
  });
};

export default componentEntry<Props>({
  id: "agent-pane.effort-picker",
  title: "Effort picker",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 320, normal: 420, wide: 560 },
  anchors: [{ selector: ".acpmux-effort" }],
  covers: ["agent-session/acpmux/EffortPicker.tsx#EffortPicker"],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening and closing the local effort menu must not move its trigger anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The effort menu must stay out of document flow while its position is measured.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Effort picker keyboard interaction should remain responsive on the gallery host.",
    },
  },
  load: async () => {
    const { EffortPicker } = await import("./EffortPicker");
    return function GalleryEffortPicker({ slider, sliderStyle, speed }: Props) {
      const [current, setCurrent] = useState("medium");
      const [fast, setFast] = useState("off");
      return (
        <EffortPicker
          label="effort"
          efforts={efforts}
          current={current}
          onPick={setCurrent}
          slider={slider}
          sliderStyle={sliderStyle}
          speed={
            speed ? { title: "Fast Mode", choices: speedChoices, current: fast, on: "on", onPick: setFast } : undefined
          }
        />
      );
    };
  },
  styles: () => Promise.all([import("./styles.css"), import("./composerControls.css")]),
  variants: {
    closed: { props: {} },
    keyboard: {
      note: "Opening focuses the selected effort row, ArrowDown changes the level, and Escape returns focus to Effort.",
      props: {},
      play: keyboard,
    },
    "list-open": { note: "The default reasoning menu: one checked row per level.", props: {}, play: open },
    "slider-open": {
      note: "Debug Settings agent.reasoningSlider on: the Reasoning section is the stepped slider.",
      props: { slider: true },
      play: open,
    },
    "slider-minimal-open": {
      note: "Debug Settings agent.reasoningSliderStyle=minimal: quieter fill and an outlined thumb.",
      props: { slider: true, sliderStyle: "minimal" },
      play: open,
    },
    "slider-speed-open": {
      note: "The slider above the Fast Mode rows.",
      props: { slider: true, speed: true },
      play: open,
    },
    "slider-keyboard": {
      note: "Opening focuses the slider, ArrowRight and End step it, and Escape returns focus to Effort.",
      props: { slider: true },
      play: sliderKeyboard,
    },
  },
});
