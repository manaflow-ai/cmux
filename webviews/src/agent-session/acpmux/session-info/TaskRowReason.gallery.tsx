// l10n-allow-file: gallery fixtures (sample commands), not shipped UI.
// A background command with nothing to open (no call that started it, or its terminal on another
// machine) said why as row text, so at 420 px "No terminal to open" squeezed "bun test …" to "bun t…"
// and the reason ran wider than what it explains (think tank cmuxterm-hq#19495, Session Info #2).
// Arms: the shipped one, the reason in the row's tooltip and aria-description only; the same with a
// small trailing info mark; the reason as a second muted line under the command. Every arm draws the
// same rows in the same panel.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { sessionSummary } from "../summary/sessionSummary";
import { SessionInfo, SessionInfoPanel } from "./SessionInfo";

type Arm = "tooltip" | "glyph" | "line";
type Props = { arm: Arm };

const transcript = chat([], { branch: "feat/next-session-info" });
const summary = { ...transcript.summary!, branch: "feat/next-session-info" };
const processes = [
  // No call that started it: nothing to open.
  {
    id: "p/test",
    command: "bun test test/session-info-tasks.test.tsx --watch",
    startedAt: minutesAgo(62),
    state: "running" as const,
  },
  { id: "p/dev", command: "bun run dev --port 5173", startedAt: minutesAgo(1), state: "running" as const },
];

/// The rejected arms only; the shipped arm adds nothing.
const ARM_CSS: Record<Arm, string> = {
  tooltip: "",
  glyph: `[data-arm="glyph"] .acpmux-session-info-task[data-closed]::after {
    content: "i"; flex: none; box-sizing: border-box; width: 12px; height: 12px; margin-inline-end: var(--grid-gap);
    border: 1px solid currentColor; border-radius: 50%; color: var(--agent-muted);
    font-family: var(--font-sans, system-ui); font-weight: 600; font-size: var(--text-caption); line-height: 10px; text-align: center; font-style: italic;
  }`,
  line: `[data-arm="line"] .acpmux-session-info-task[data-closed] { flex-wrap: wrap; }
  [data-arm="line"] .acpmux-session-info-task[data-closed]::after {
    content: attr(title); flex: 1 0 100%; box-sizing: border-box; margin-top: calc(var(--grid-base) * -1.5);
    padding: 0 var(--grid-gap) var(--grid-pill-inset) calc(var(--grid-gap) * 2 + var(--grid-icon-box));
    color: var(--agent-muted); font-size: var(--text-detail); letter-spacing: var(--text-detail--letter-spacing);
  }`,
};

function TaskRowReason({ arm }: Props) {
  return (
    <div className="acpmux-shell" style={{ height: "100%" } as CSSProperties} data-arm={arm}>
      {ARM_CSS[arm] && <style>{ARM_CSS[arm]}</style>}
      <SessionInfoPanel width={420} placement="overlay">
        <SessionInfo
          summary={summary}
          machineName="Studio"
          made={sessionSummary(transcript.rows)}
          processes={processes}
          onStopProcess={async () => undefined}
          onOpenUrl={() => undefined}
          remoteControl={{ on: false, set: () => undefined }}
        />
      </SessionInfoPanel>
    </div>
  );
}

/// The shipped arm: the command is whole, no reason text in the row, and the reason is the row's
/// tooltip and the button's aria-description.
const commandKeepsTheRow: Play = async (ctx) => {
  const closed = ".acpmux-session-info-task--command[data-closed]";
  await ctx.waitFor(() => ctx.document.querySelector(closed));
  const row = ctx.document.querySelector<HTMLElement>(closed)!;
  const command = row.querySelector<HTMLElement>(".acpmux-session-info-task__command");
  if (!command) throw new Error("The closed row drew no command");
  if (command.scrollWidth > command.clientWidth + 0.5)
    throw new Error(`The command is cut: ${command.scrollWidth}px in ${command.clientWidth}px`);
  if (row.querySelector(".acpmux-session-info-task__why")) throw new Error("The reason is still row text");
  if (!row.title) throw new Error("The closed row has no tooltip");
  const button = row.querySelector("button");
  if (button?.getAttribute("aria-description") !== row.title)
    throw new Error("The button's aria-description is not the tooltip's reason");
};

export default componentEntry<Props>({
  id: "agent-pane.session-info-task-row-reason",
  title: "Session Info Background tasks: why a row does not open",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 420, normal: 600 },
  covers: [
    "agent-session/acpmux/session-info/TasksSection.tsx#TasksSection",
    "agent-session/acpmux/session-info/sessionInfo.css",
  ],
  load: async () => TaskRowReason,
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  variants: {
    tooltip: {
      note: "Shipped: the command keeps the row whole; why it does not open (\"No terminal to open\") is the row's tooltip and the button's aria-description, and the row keeps its disabled ink.",
      props: { arm: "tooltip" },
      play: commandKeepsTheRow,
    },
    glyph: {
      note: "Rejected: the tooltip plus a small trailing info mark, so the row says it has a reason before the hover. It takes a column every other row lacks and still looks clickable.",
      props: { arm: "glyph" },
    },
    line: {
      note: "Rejected: the reason as a second muted line under the command. Nothing is cut, but the row grows taller than its neighbours and the panel's densest list loses a row per command.",
      props: { arm: "line" },
    },
  },
});
