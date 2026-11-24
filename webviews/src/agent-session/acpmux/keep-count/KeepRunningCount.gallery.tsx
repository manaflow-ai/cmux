// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { KeepRunningCount } from "./KeepRunningCount";
import type { KeepCount } from "./keepCount";

type Props = Parameters<typeof KeepRunningCount>[0];

// The counts cmux-cloud-start-core `keep_count::count` answers for each case (its tests hold the
// same numbers).
const plus2: KeepCount = {
  plan: "plus",
  kept: 2,
  slots: 3,
  hoursUsed: 41,
  hours: 100,
  window: "month",
  hoursLow: false,
  next: { do: "keeps", after: 3 },
};
const plusFull: KeepCount = { ...plus2, kept: 3, next: { do: "full" } };
const plusOn: KeepCount = { ...plus2, kept: 3, next: { do: "frees", after: 2 } };
const plusLow: KeepCount = { ...plus2, kept: 1, hoursUsed: 86, hoursLow: true, next: { do: "keeps", after: 2 } };
const plusSpent: KeepCount = { ...plus2, kept: 1, hoursUsed: 100, hoursLow: true, next: { do: "hoursUsedUp" } };
const noPlan: KeepCount = {
  plan: null,
  kept: 0,
  slots: 0,
  hoursUsed: null,
  hours: null,
  window: null,
  hoursLow: false,
  next: { do: "startsTrial", slots: 1, hours: 10 },
};
const trial: KeepCount = {
  plan: "trial",
  kept: 1,
  slots: 1,
  hoursUsed: 3,
  hours: 10,
  window: "week",
  hoursLow: false,
  next: { do: "frees", after: 0 },
};
const max: KeepCount = {
  plan: "max",
  kept: 12,
  slots: 50,
  hoursUsed: 2_310,
  hours: 10_000,
  window: "month",
  hoursLow: false,
  next: { do: "keeps", after: 13 },
};

const LOOKS = {
  inline:
    'Inline: the count sits on the switch\'s own row ("2 of 3") and one quiet line under it gives the hours and what flipping it does. Costs one 15 px line.',
  stack:
    'Stack (lead): under the switch, RFD 0135\'s own words ("2 of 3 kept running, 41 of 100 hours used"), then what flipping it does. Two quiet lines; the count reads as a sentence, not a widget.',
  meter:
    "Meter: one dot a slot and an hours bar, each with its figure, then the next line. Reads at a glance but costs three lines and draws a bar for a plan past 10 slots.",
} as const;

const CASES: Record<string, { count: KeepCount; on: boolean; note: string }> = {
  keeps: { count: plus2, on: false, note: "Plus, 2 of 3 kept, 41 of 100 hours: turning it on keeps this one too." },
  full: {
    count: plusFull,
    on: false,
    note: "Plus, 3 of 3: full, so the line says to turn one off first (the slot rule's holders menu is the owner's).",
  },
  on: { count: plusOn, on: true, note: "This chat is kept: turning it off frees its place." },
  "hours-low": {
    count: plusLow,
    on: false,
    note: "86 of 100 hours: on Plus the hours run out before the slots, so the hours turn to the warning tone first.",
  },
  "hours-used-up": {
    count: plusSpent,
    on: false,
    note: "100 of 100 hours: turning it on keeps nothing until they reset.",
  },
  "no-plan": {
    count: noPlan,
    on: false,
    note: "No plan: no count yet; the line says turning it on starts the no-card taste (RFD 0052).",
  },
  trial: { count: trial, on: true, note: "On the taste: 1 of 1, hours counted over its 7 days." },
  max: { count: max, on: false, note: "Max, 12 of 50: the meter draws a bar past 10 slots." },
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const [look, lookNote] of Object.entries(LOOKS)) {
  for (const [name, { count, on, note }] of Object.entries(CASES)) {
    variants[`${look}-${name}`] = {
      note: `${lookNote} ${note}`,
      props: { count, on, look: look as Props["look"], onChange: () => undefined },
    };
  }
}

export default componentEntry<Props>({
  id: "agent-pane.keep-running-count",
  title: "Keep-running switch: how many it keeps and what another does (RFD 0135)",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/keep-count/KeepRunningCount.tsx#KeepRunningCount"],
  pane: true,
  load: () => import("./KeepRunningCount").then((module) => module.KeepRunningCount),
  widths: { narrow: 280, normal: 320, wide: 420 },
  height: 110,
  variants,
});
