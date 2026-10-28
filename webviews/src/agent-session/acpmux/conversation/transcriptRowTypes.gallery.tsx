// l10n-allow-file: gallery fixtures (sample prompts, replies and notes), not shipped UI.
// Every transcript row type the pane's row registry draws, one variant each, drawn by the real
// VirtualTranscript over the rows of src/gallery/fixtures/transcriptRowTypes.ts. The same rows feed
// test/transcript-row-types.test.tsx, which pins each type's DOM; this entry is its visual side, so
// the gallery's screenshot runs show a row type that changed when its code moves (audit P10: the
// split of App.tsx by row type). A Worked-for line or a subagent group opens on a click.
import { useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { ROW_TYPE_ROWS, ROW_TYPES, ROW_TYPES_SESSION } from "../../../gallery/fixtures/transcriptRowTypes";
import { VirtualTranscript } from "../App";

type Props = { type: string };

function RowTypeStage({ type }: Props) {
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const toggle = (id: string) =>
    setExpanded((open) => {
      const next = new Set(open);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <div className="acpmux-main">
        <div className="acpmux-stage">
          <VirtualTranscript
            rows={ROW_TYPE_ROWS[type] ?? []}
            sessionId={ROW_TYPES_SESSION}
            onToggleActivity={toggle}
            expanded={expanded}
            showMinimap={false}
          />
        </div>
      </div>
    </div>
  );
}

const NOTES: Record<string, string> = {
  user: "The person's prompt: a bubble at the right with its action row.",
  "user-chief": "A Chief's message to its subagent: the Chief prompt bubble.",
  "user-notice": "A task notification sent as a prompt: one quiet line.",
  "user-received": "A started task's result sent as a prompt: its received line.",
  "user-queued": "A prompt queued behind a harness switch: its status, Cancel, and the CLI host.",
  assistant: "A finished reply as Markdown.",
  activity: "Tool calls as quiet rows: a read and a command.",
  editedFiles: "An edit call: the edited-files card.",
  worked: 'A finished turn\'s "Worked for" line; a click opens it.',
  date: "The date line over a prompt after a long gap.",
  thinking: "A running turn's status line before its first output.",
  working: "A running turn's line naming the call in flight.",
  activityLine: "The running turn's activity line under its todo list.",
  preview: "A turn's local web page card.",
  render: "A render call's card: nothing outside the app's own page scheme.",
  turnSummary: "A turn's footer.",
  notice: "A notice row: one muted line.",
  typing: "A typing row, drawn as a notice.",
  plan: "The agent's todo list of an ended turn.",
  "plan-text": "A plan row without entries: its text as a muted line.",
  backgroundTask: "A background shell's end, noted where it ended.",
  compaction: "A finished compaction note.",
  failover: "A failover note: the chat moved to its fallback harness.",
  policyUnenforced: "A policy the chat's harness cannot keep.",
  agentPair: "A paused agent pair with one held message and Resume.",
  sessionStart: "Where a Claude Code session started.",
  sessionOffer: "An agent's suggested task.",
  offerResult: "A task's result waiting in the queue.",
  startedSessions: "A chat this chat's agent started, as its card.",
  permission: "A pending permission ask in the transcript (no shortcuts).",
  "permission-empty": "A permission row whose ask is gone: the bare title.",
  questionRecord: "An answered question's record: the card's answered form.",
  permissionRecord: "A permission card's receipt: one muted line.",
  userShell: "A shell mode command's block.",
  subagents: "A batch of two subagents, closed; a click lists them.",
  "subagents-run": "An agent a shell call started (codex exec), as its own card.",
  subagent: "One subagent's row in an open group.",
  subagentDone: "Where a subagent ended.",
  subagentOf: 'The child view\'s "Subagent of" pill.',
  workflowCard: "A Claude workflow's card where it started.",
  unknown: "A row kind no renderer claims: the notice row's muted line.",
};

/// Variant names are lower kebab case: `editedFiles` is `edited-files`.
const variantName = (type: string) => type.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);

export default componentEntry<Props>({
  id: "agent-pane.transcript-row-types",
  title: "Transcript row types",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/App.tsx#VirtualTranscript",
    "agent-session/acpmux/rows/ActivityLineRow.tsx",
    "agent-session/acpmux/rows/AgentPairRow.tsx",
    "agent-session/acpmux/rows/BackgroundTaskRow.tsx",
    "agent-session/acpmux/rows/CompactionRow.tsx",
    "agent-session/acpmux/rows/DateRow.tsx",
    "agent-session/acpmux/rows/EditedFilesRow.tsx",
    "agent-session/acpmux/rows/FailoverRow.tsx",
    "agent-session/acpmux/rows/MessageRow.tsx",
    "agent-session/acpmux/rows/NoticeRow.tsx",
    "agent-session/acpmux/rows/OfferResultRow.tsx",
    "agent-session/acpmux/rows/PermissionAsk.tsx",
    "agent-session/acpmux/rows/PermissionRecordRow.tsx",
    "agent-session/acpmux/rows/PermissionRow.tsx",
    "agent-session/acpmux/rows/PlanRow.tsx",
    "agent-session/acpmux/rows/PolicyUnenforcedRow.tsx",
    "agent-session/acpmux/rows/PreviewRow.tsx",
    "agent-session/acpmux/rows/QuestionRecordRow.tsx",
    "agent-session/acpmux/rows/RenderRow.tsx",
    "agent-session/acpmux/rows/SessionOfferRow.tsx",
    "agent-session/acpmux/rows/SessionStartRow.tsx",
    "agent-session/acpmux/rows/StartedSessionsRow.tsx",
    "agent-session/acpmux/rows/SubagentDoneRow.tsx",
    "agent-session/acpmux/rows/SubagentGroupRow.tsx",
    "agent-session/acpmux/rows/SubagentOfPillRow.tsx",
    "agent-session/acpmux/rows/SubagentRow.tsx",
    "agent-session/acpmux/rows/SummaryRow.tsx",
    "agent-session/acpmux/rows/ThinkingRow.tsx",
    "agent-session/acpmux/rows/ToolActivityRow.tsx",
    "agent-session/acpmux/rows/WorkedRow.tsx",
    "agent-session/acpmux/rows/WorkflowCardRow.tsx",
    "agent-session/acpmux/rows/WorkingRow.tsx",
  ],
  load: async () => RowTypeStage,
  pane: true,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: Object.fromEntries(
    ROW_TYPES.map((type): [string, ComponentVariant<Props>] => [
      variantName(type),
      { note: NOTES[type] ?? type, props: { type } },
    ]),
  ),
});
