// l10n-allow-file: gallery fixtures (sample commands, wakeups and cron jobs), not shipped UI.
// Background tasks' row icons beside Environment's (Leo, 2026-11-07, of the wakeup row's clock:
// "this is too big"). The clock, the cron arrow, the >_ and the server globe drew in a forced 16px
// box with the row crop and no optical fit, so the clock's ring ran 14.3px across (its path, stroke
// left out), past every Environment glyph (13.1px at most) and Subagents' (12.5px). Arms: the shipped
// one and the two other glyph sizes it was picked from, each in the same 16px icon column. Every arm
// draws the same rows in the same panel.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { sessionSummary, type SummaryWakeup } from "../summary/sessionSummary";
import { SessionInfo, SessionInfoPanel } from "./SessionInfo";

type Arm = "fit-14" | "fit-16" | "fit-12";
type Props = { arm: Arm };

const transcript = chat([], { branch: "feat/next-session-info" });
const summary = { ...transcript.summary!, branch: "feat/next-session-info" };
const scheduled: SummaryWakeup[] = [
  {
    id: "w-nightly",
    kind: "wakeup",
    text: "Eight reviews still running; wake when the nightly finishes",
    startedAt: minutesAgo(2),
    dueAt: Date.now() + 25 * 60_000,
  },
  { id: "c-hourly", kind: "cron", cron: "17 * * * *", text: "Hourly coordinator pass", startedAt: minutesAgo(90) },
];
const processes = [
  { id: "p/test", command: "bun test --watch", startedAt: minutesAgo(62), state: "running" as const },
  { id: "p/dev", command: "bun run dev --port 5173", startedAt: minutesAgo(1), state: "running" as const },
];

/// The rejected arms only: the same rows with the task glyph drawn at another size in the same
/// column. The shipped arm adds nothing.
const ARM_CSS: Record<Arm, string> = {
  "fit-14": "",
  "fit-16": `[data-arm="fit-16"] .acpmux-session-info :is(.acpmux-session-info-task, .acpmux-session-info-task__open) > svg.acpmux-row-glyph { --acpmux-session-info-task-glyph: var(--grid-icon-box); }`,
  "fit-12": `[data-arm="fit-12"] .acpmux-session-info :is(.acpmux-session-info-task, .acpmux-session-info-task__open) > svg.acpmux-row-glyph { --acpmux-session-info-task-glyph: calc(var(--grid-icon-box) - var(--grid-base)); }`,
};

function TaskRowIcons({ arm }: Props) {
  return (
    <div className="acpmux-shell" style={{ height: "100%" } as CSSProperties} data-arm={arm}>
      {ARM_CSS[arm] && <style>{ARM_CSS[arm]}</style>}
      <SessionInfoPanel width={320} placement="overlay">
        <SessionInfo
          summary={summary}
          machineName="Studio"
          made={{ ...sessionSummary(transcript.rows), scheduled }}
          processes={processes}
          onStopProcess={async () => undefined}
          onOpenUrl={() => undefined}
          remoteControl={{ on: false, set: () => undefined }}
        />
      </SessionInfoPanel>
    </div>
  );
}

/// The ink of `svg` in CSS pixels: its drawn shapes' box, stroke included.
function ink(svg: SVGSVGElement) {
  let left = Infinity;
  let top = Infinity;
  let right = -Infinity;
  let bottom = -Infinity;
  for (const shape of svg.querySelectorAll<SVGGraphicsElement>("path, circle, rect, line, polyline, ellipse")) {
    const box = shape.getBBox();
    const matrix = shape.getScreenCTM();
    if (!matrix) continue;
    const half = (parseFloat(getComputedStyle(shape).strokeWidth) || 0) / 2;
    for (const [x, y] of [
      [box.x - half, box.y - half],
      [box.x + box.width + half, box.y + box.height + half],
    ] as const) {
      const point = new DOMPoint(x, y).matrixTransform(matrix);
      left = Math.min(left, point.x);
      top = Math.min(top, point.y);
      right = Math.max(right, point.x);
      bottom = Math.max(bottom, point.y);
    }
  }
  return { width: right - left, height: bottom - top, centerX: (left + right) / 2 };
}

/// The shipped arm: every task glyph's ink is no larger than Environment's largest, each sits on the
/// panel's one icon column (its centre on Environment's), and the label starts where Environment's do.
const sameColumn: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-session-info-task[data-kind="wakeup"] svg'));
  const envIcons = [...ctx.document.querySelectorAll<SVGSVGElement>(".acpmux-session-info-row > svg[data-icon]")];
  if (envIcons.length === 0) throw new Error("No Environment row icon drew");
  const envLargest = Math.max(...envIcons.map((svg) => Math.max(ink(svg).width, ink(svg).height)));
  const envCenter = ink(envIcons[0]!).centerX;
  const envBox = envIcons[0]!.getBoundingClientRect();
  const taskIcons = [
    ...ctx.document.querySelectorAll<SVGSVGElement>(
      ":is(.acpmux-session-info-task, .acpmux-session-info-task__open) > svg.acpmux-row-glyph",
    ),
  ];
  if (taskIcons.length < 4) throw new Error(`${taskIcons.length} task glyphs drew, expected 4`);
  for (const svg of taskIcons) {
    const own = ink(svg);
    const largest = Math.max(own.width, own.height);
    if (largest > envLargest + 0.25)
      throw new Error(
        `${svg.dataset.icon} ink is ${largest.toFixed(1)}px, past Environment's ${envLargest.toFixed(1)}px`,
      );
    const box = svg.getBoundingClientRect();
    const boxCenter = box.left + box.width / 2;
    if (Math.abs(boxCenter - (envBox.left + envBox.width / 2)) > 0.5)
      throw new Error(`${svg.dataset.icon} leaves the icon column (${boxCenter} vs ${envCenter})`);
    const label = svg.nextElementSibling?.getBoundingClientRect();
    if (label && Math.abs(label.left - (envBox.right + 8)) > 0.75)
      throw new Error(
        `${svg.dataset.icon}'s label starts at ${label.left}, not on the text column ${envBox.right + 8}`,
      );
  }
};

export default componentEntry<Props>({
  id: "agent-pane.session-info-task-row-icons",
  title: "Session Info Background tasks row icons",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 344, normal: 600 },
  covers: [
    "agent-session/acpmux/session-info/TasksSection.tsx#TasksSection",
    "agent-session/acpmux/session-info/ServersSection.tsx",
    "agent-session/acpmux/session-info/sessionInfo.css",
  ],
  load: async () => TaskRowIcons,
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  variants: {
    "fit-14": {
      note: "Shipped: each task glyph is fitted (one ink box and stroke, as Environment's are) in a 14px box, the row text's icon size, centred on the 16px icon column. The clock's ring is 11.4px across, under Environment's largest glyph (13.1px), and the >_, clock, arrow and globe read as one size. The unfitted 14px crop was also measured: the clock 12.5px but the >_ 8.8px wide, so the kinds stopped matching.",
      props: { arm: "fit-14" },
      play: sameColumn,
    },
    "fit-16": {
      note: "Rejected: Environment's own 16px box. The clock's ring is 13.1px, as wide as the folder, and still reads heavier than the label beside it; the >_ grows to 13.1px wide, the opposite of the ask.",
      props: { arm: "fit-16" },
    },
    "fit-12": {
      note: "Rejected: a 12px box (the status-mark size). The clock's ring is 9.8px and its stroke thins to 0.94px, lighter and smaller than every other row icon in the panel.",
      props: { arm: "fit-12" },
    },
  },
});
