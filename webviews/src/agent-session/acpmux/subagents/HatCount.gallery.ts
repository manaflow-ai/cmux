// l10n-allow-file: gallery fixtures, not shipped UI.
// The tucked composer hat's count (TrayPullTab.tsx, HatCount.tsx): the real number, never "99+", and
// how it turns. Leo, 2026-11-22, of the pill reading "^ 99+": "this can probably afford to show more
// than 99 numbers. and have better animations for transitioning between numbers and digit lengths."
// Four arms (hatCount.experiment.ts; view Compare arms): rolling digits (ships), the whole number
// sliding, a crossfade, and the instant swap (before). The script steps across every digit length:
// 9 -> 10, 99 -> 100 -> 99, 999 -> 1k, and back down. Light and dark: ?colorScheme=light / dark.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { hatCountMotion } from "./hatCount.experiment";

type Props = { start?: number; side?: "left" | "middle" | "right"; capped?: boolean };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const count = (ctx: PlayContext) =>
  ctx.document.querySelector<HTMLElement>(".acpmux-tray-pull__count")?.dataset.count ?? "";
const step = (name: string, button: string, expected: string) => ({
  name,
  run: async (ctx: PlayContext) => {
    await ctx.click(stage(button));
    await ctx.waitFor(() => count(ctx) === expected);
  },
});

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-count",
  title: "Composer hat: the count turns, past 99",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/subagents/HatCount.tsx",
    "agent-session/acpmux/subagents/hatCount.experiment.ts",
    "agent-session/acpmux/subagents/trayPullTabModel.ts",
  ],
  keywords: ["composer hat", "count", "99+", "rolling digits", "odometer", "pull tab"],
  load: () => import("../../../gallery/fixtures/ComposerHatStage").then((module) => module.ComposerHatStage),
  pane: true,
  height: 220,
  experiment: {
    definition: hatCountMotion,
    script: [
      step("nine run", "count", "3"),
      step("ninety-nine run", "ninety-nine", "99"),
      step("one more: a digit is gained, the width eases", "more", "100"),
      step("one fewer: the digit leaves", "fewer", "99"),
      step("999 run", "nine-ninety-nine", "999"),
      step("one more: 1k, a unit in place of a digit", "more", "1k"),
      step("1,234 run", "many", "1.2k"),
    ],
  },
  variants: {
    before: {
      note: "Before: the count stopped at ^ 99+ however many ran, and each change swapped in one frame.",
      props: { start: 128, capped: true },
    },
    "three-digits": {
      note: "128 run: the pill reads ^ 128, not ^ 99+, one digit wider than 99.",
      props: { start: 128 },
    },
    thousand: {
      note: "1,234 run: ^ 1.2k, rounded down so it never claims more than runs; the point takes half a digit.",
      props: { start: 1_234 },
    },
    "ten-thousand": {
      note: "12,800 run: ^ 12k, three characters.",
      props: { start: 12_800 },
    },
    "at-the-end": {
      note: "128 run with the pill at the composer's end edge (beside Jump to latest): it widens to the left, its end corner holds.",
      props: { start: 128, side: "right" },
    },
    "one-digit": {
      note: "Nine run: one digit; One more rolls it to 10 and the pill eases one digit wider.",
      props: { start: 9 },
    },
  },
});
