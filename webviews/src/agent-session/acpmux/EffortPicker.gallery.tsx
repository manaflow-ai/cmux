// l10n-allow-file: gallery choices are fixture labels; the trigger uses the translated Effort label.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

const efforts = [
  { id: "low", name: "Low" },
  { id: "medium", name: "Medium" },
  { id: "high", name: "High" },
];

type Props = Record<string, never>;

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
  height: 300,
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
    return function GalleryEffortPicker() {
      const [current, setCurrent] = useState("medium");
      return <EffortPicker label="effort" efforts={efforts} current={current} onPick={setCurrent} />;
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
  },
});
