// l10n-allow-file: gallery fixtures, not shipped UI.
// The capture bar (CaptureBar.tsx) over a stand-in composer: the shortcut opens it, a target takes a
// screenshot that lands in the composer, Record runs until Stop and lands the recording. Three arms
// (captureBar.experiment.ts; view Compare arms): the band (shipped), a mode switch with one Capture
// button, and a row of icons. Leo, 2026-11-07: "could we also have a more native
// screenshot/screensharer (ergonomic one)/video recording of the app type thing/route?"
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { CaptureBarLook } from "./captureBar.experiment";
import { captureBarLook } from "./captureBar.experiment";
import type { CapturePhase } from "./captureModel";

type Props = { look?: CaptureBarLook; phase?: CapturePhase["kind"] };

const phase = (ctx: PlayContext) => ctx.document.querySelector("[data-stage-phase]")?.textContent ?? "";
const chips = (ctx: PlayContext) => ctx.document.querySelectorAll("[data-stage-chip]").length;

export const captureBarScript = [
  {
    name: "the shortcut opens the bar over the composer",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: '[data-stage="shortcut"]' });
      await ctx.waitFor(() => phase(ctx) === "open" && ctx.document.querySelector(".acpmux-capture__body") !== null);
    },
  },
  {
    name: "a click on Window takes it, and the screenshot lands in the composer",
    run: async (ctx: PlayContext) => {
      const segmented = ctx.document.querySelector('.acpmux-capture[data-look="segmented"]') !== null;
      await ctx.click({ selector: '.acpmux-capture__target[data-target="window"]' });
      if (segmented) await ctx.click({ selector: ".acpmux-capture__go" });
      await ctx.waitFor(() => chips(ctx) === 1 && phase(ctx) === "closed");
    },
  },
  {
    name: "Record runs the timer, Stop lands the recording",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: '[data-stage="shortcut"]' });
      await ctx.waitFor(() => phase(ctx) === "open");
      if (ctx.document.querySelector('.acpmux-capture[data-look="segmented"]')) {
        await ctx.click({ selector: '.acpmux-capture__mode[aria-pressed="false"]' });
        await ctx.click({ selector: ".acpmux-capture__go" });
      } else await ctx.click({ selector: ".acpmux-capture__record" });
      await ctx.waitFor(() => phase(ctx) === "recording");
      await ctx.click({ selector: ".acpmux-capture__stop" });
      await ctx.waitFor(() => chips(ctx) === 2 && phase(ctx) === "closed");
    },
  },
];

export default componentEntry<Props>({
  id: "agent-pane.capture-bar",
  title: "Capture bar: screenshots and recordings into the chat",
  area: "Agent pane",
  covers: ["agent-session/acpmux/capture/CaptureBar.tsx"],
  load: () => import("../../../gallery/fixtures/CaptureBarStage").then((module) => module.CaptureBarStage),
  pane: true,
  height: 260,
  experiment: { definition: captureBarLook, script: captureBarScript },
  variants: {
    band: {
      note: "Open, the band: Region, Window, Pane and cmux, Record with Pointer and Clicks, then Chat, Copy or Save.",
      props: { phase: "open" },
    },
    segmented: {
      note: "The mode switch arm: Screenshot or Record, then a target and Capture.",
      props: { phase: "open", look: "segmented" },
    },
    chip: {
      note: "The icon arm: one glyph per target and the record dot, names in tooltips.",
      props: { phase: "open", look: "chip" },
    },
    recording: {
      note: "Recording: the red dot, the time, what it films, and Stop.",
      props: { phase: "recording" },
    },
    play: {
      note: "Open with the shortcut, take a window screenshot into the composer, then record and stop.",
      props: {},
      play: async (ctx) => {
        for (const step of captureBarScript) await step.run(ctx);
      },
    },
  },
});
