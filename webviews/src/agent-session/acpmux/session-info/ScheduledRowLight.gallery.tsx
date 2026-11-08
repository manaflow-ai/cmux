// l10n-allow-file: gallery fixtures (sample commands and wakeups), not shipped UI.
// The wakeup row in Background tasks under the pointer, beside the running command it sits under
// (Leo, 2026-11-06: "it is kind of weird that there is this, what is it, so-called fallback
// heartbeat, and it doesn't get highlighted in the same way that the other ones do"). Three arms:
// the shipped one, where the wakeup shows the call that made it and lights as the command does;
// a tint with no click behind it (rejected: a lit row that does nothing on click is a dead target,
// and the native panel lights only rows with an action); and the plain row base drew.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { SummaryWakeup } from "../summary/sessionSummary";
import { SessionInfoPanel } from "./SessionInfo";
import { TasksSection } from "./TasksSection";

type Props = { arm: "opens-call" | "tint-only" | "plain" };

const command = {
  id: "proc-reach",
  processId: "proc-reach",
  toolCallId: "toolu_reach",
  command: "cd /tmp; timeout 3000 reach review-router 'check the PR'",
  state: "running" as const,
  startedAt: minutesAgo(3),
};
const heartbeat: SummaryWakeup = {
  id: "toolu_heartbeat",
  kind: "wakeup",
  text: "Fallback heartbeat; the local review may still be running",
  startedAt: minutesAgo(2),
  dueAt: Date.now() + 25 * 60_000,
};
const calls = new Set([command.toolCallId, heartbeat.id]);

function ScheduledRowLight({ arm }: Props) {
  const opens = arm === "opens-call";
  return (
    <div className="acpmux-shell" style={{ height: "100%" }} data-arm={arm}>
      {arm === "tint-only" && (
        // The rejected arm only: a plain wakeup row tinted on hover, with nothing behind the click.
        <style>{`[data-arm="tint-only"] li.acpmux-session-info-task[data-kind]:hover { background: var(--acpmux-session-info-row-hover); border-radius: var(--acpmux-session-info-row-radius); }`}</style>
      )}
      <SessionInfoPanel width={320} placement="overlay">
        <div className="acpmux-session-info__body" data-layout="glance">
          <TasksSection
            commands={[command]}
            scheduled={[heartbeat]}
            local={false}
            calls={opens ? calls : new Set([command.toolCallId])}
            onShowCall={() => true}
          />
        </div>
      </SessionInfoPanel>
    </div>
  );
}

const hoverWakeup = async (ctx: { hover(target: { selector: string }): Promise<void> }) =>
  ctx.hover({ selector: 'li.acpmux-session-info-task[data-kind="wakeup"]' });

export default componentEntry<Props>({
  id: "agent-pane.session-info-scheduled-row-light",
  title: "Session Info wakeup row on hover",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 360, normal: 600 },
  covers: ["agent-session/acpmux/session-info/TasksSection.tsx#TasksSection"],
  load: async () => ScheduledRowLight,
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  variants: {
    "opens-call": {
      note: "Shipped: the wakeup is a button that shows the call that made it; under the pointer it lights edge to edge with the command row's tint and radius.",
      props: { arm: "opens-call" },
      play: hoverWakeup,
    },
    "tint-only": {
      note: "Rejected: the same tint on a row with no click behind it; it promises an action that is not there, and the native panel would still draw it plain.",
      props: { arm: "tint-only" },
      play: hoverWakeup,
    },
    plain: {
      note: "Base: the wakeup row under the pointer draws nothing, unlike the command row above it.",
      props: { arm: "plain" },
      play: hoverWakeup,
    },
  },
});
