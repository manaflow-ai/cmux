// l10n-allow-file: gallery choices are fixture labels; EffortTrack owns translated ends and aria text.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { Choice } from "./ComposerPickers";
import { EffortTrack } from "./EffortTrack";

const efforts: Choice[] = [
  { id: "low", name: "Low" },
  { id: "medium", name: "Medium" },
  { id: "high", name: "High", recommended: true },
  { id: "max", name: "Max" },
];

type Props = {
  current?: string;
  fallback?: string;
};

function GalleryEffortTrack({ current: initialCurrent, fallback }: Props) {
  const [current, setCurrent] = useState(initialCurrent);
  return (
    <div className="acpmux-effort-track-gallery">
      <EffortTrack efforts={efforts} current={current} fallback={fallback} onPick={setCurrent} />
    </div>
  );
}

const keyboard: Play = async (ctx) => {
  const selector = ".acpmux-effort-range";
  await ctx.focus({ selector });
  await ctx.press("End");
  await ctx.waitFor(() => ctx.document.querySelector<HTMLInputElement>(selector)?.value === "3");
  await ctx.press("Home");
  await ctx.waitFor(() => ctx.document.querySelector<HTMLInputElement>(selector)?.value === "0");
};

export default componentEntry<Props>({
  id: "agent-pane.effort-track",
  title: "Effort track",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 320, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-effort-track" }],
  covers: ["agent-session/acpmux/EffortTrack.tsx#EffortTrack"],
  styles: () => Promise.all([import("./styles.css"), import("./composerControls.css")]),
  load: async () => GalleryEffortTrack,
  variants: {
    "default-high": {
      note: "The agent's default rests on the recommended High level without committing a pick.",
      props: { fallback: "high" },
    },
    "picked-medium": {
      note: "A committed Medium choice moves the native range thumb and fills the track to that stop.",
      props: { current: "medium", fallback: "high" },
    },
    "picked-max": {
      note: "The far-right Max choice keeps the thumb aligned with the track's rounded end.",
      props: { current: "max", fallback: "high" },
    },
    keyboard: {
      note: "Home and End step the real range input across all offered effort levels.",
      props: { current: "medium", fallback: "high" },
      play: keyboard,
    },
  },
});
