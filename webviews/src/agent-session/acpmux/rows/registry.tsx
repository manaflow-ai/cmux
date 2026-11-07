import { QUEUED_MESSAGE, PENDING_MESSAGES, LANE_NOTICE_BATCH, MESSAGE_RUN } from "../model";
import { QUESTION_RECORD } from "../question/record";
import { PERMISSION_RECORD } from "../permissions/record";
import { TASK_LINE } from "../conversation/taskLineKind";
import { BACKGROUND_TURN } from "../conversation/backgroundTurns";
import { ACTIVITY_LINE, DATE, NEXT_STEP, RENDER, THINKING, WORKED, WORKING } from "../conversation/turns";
import { SHELL_ROW } from "../shell/shellRuns";
import { SUBAGENTS } from "../subagents/subagentFold";
import { SubagentEmptyRow } from "../subagents/SubagentEmptyRow";
import { SUBAGENT_DONE, SUBAGENT_EMPTY, SUBAGENT_OF, SUBAGENT_ROW, WORKFLOW_CARD } from "../subagents/subagentRows";
import { ShellRow } from "../shell/ShellRow";
import { type BtwRow as InlineBtwRow } from "../aside/btwNotes";
import { BtwAside } from "../aside/BtwAside";
import { OFFER_RESULT } from "../offer/offersShown";
import { STARTED_SESSIONS } from "../started/startedSessions";
import { type NativeRegistry } from "./rowProps";
import { MessageRow } from "./MessageRow";
import { QueuedMessageRow } from "./QueuedMessageRow";
import { ToolActivityRow } from "./ToolActivityRow";
import { WorkedRow } from "./WorkedRow";
import { BackgroundTurnRow } from "./BackgroundTurnRow";
import { MessageRunRow } from "./MessageRunRow";
import { DateRow } from "./DateRow";
import { ThinkingRow } from "./ThinkingRow";
import { WorkingRow } from "./WorkingRow";
import { ActivityLineRow } from "./ActivityLineRow";
import { NextStepRow } from "./NextStepRow";
import { ReadOnlyNextStepRow } from "./ReadOnlyNextStepRow";
import { RenderRow } from "./RenderRow";
import { SummaryRow } from "./SummaryRow";
import { PlanRow } from "./PlanRow";
import { BackgroundTaskRow } from "./BackgroundTaskRow";
import { CompactionRow } from "./CompactionRow";
import { FailoverRow } from "./FailoverRow";
import { RecapRow } from "./RecapRow";
import { PolicyUnenforcedRow } from "./PolicyUnenforcedRow";
import { AgentPairRow } from "./AgentPairRow";
import { SessionStartRow } from "./SessionStartRow";
import { NoticeRow } from "./NoticeRow";
import { PermissionRow } from "./PermissionRow";
import { QuestionRecordRow } from "./QuestionRecordRow";
import { PermissionRecordRow } from "./PermissionRecordRow";
import { SubagentGroupRow } from "./SubagentGroupRow";
import { SubagentRow } from "./SubagentRow";
import { SubagentDoneRow } from "./SubagentDoneRow";
import { WorkflowCardRow } from "./WorkflowCardRow";
import { SubagentOfPillRow } from "./SubagentOfPillRow";
import { EditedFilesRow } from "./EditedFilesRow";
import { PendingMessagesRow } from "./PendingMessagesRow";
import { LaneNoticeBatchRow } from "./LaneNoticeBatchRow";
import { SessionOfferRow } from "./SessionOfferRow";
import { OfferResultRow } from "./OfferResultRow";
import { TaskLineRow } from "./TaskLineRow";
import { StartedSessionsRow } from "./StartedSessionsRow";
import { ReadOnlyPermissionRow } from "./ReadOnlyPermissionRow";
import { ReadOnlyQueuedMessageRow } from "./ReadOnlyQueuedMessageRow";
import { ReadOnlyAgentPairRow } from "./ReadOnlyAgentPairRow";

export const defaultRegistry: NativeRegistry = {
  btw: ({ row }) => {
    const aside = row as InlineBtwRow;
    return <BtwAside note={aside.btw} onDismiss={aside.dismissBtw} />;
  },
  user: MessageRow,
  assistant: MessageRow,
  activity: ToolActivityRow,
  [WORKED]: WorkedRow,
  [BACKGROUND_TURN]: BackgroundTurnRow,
  [MESSAGE_RUN]: MessageRunRow,
  [DATE]: DateRow,
  [THINKING]: ThinkingRow,
  [WORKING]: WorkingRow,
  [ACTIVITY_LINE]: ActivityLineRow,
  [NEXT_STEP]: NextStepRow,
  [RENDER]: RenderRow,
  editedFiles: EditedFilesRow,
  turnSummary: SummaryRow,
  notice: NoticeRow,
  plan: PlanRow,
  backgroundTask: BackgroundTaskRow,
  compaction: CompactionRow,
  failover: FailoverRow,
  recap: RecapRow,
  policyUnenforced: PolicyUnenforcedRow,
  agentPair: AgentPairRow,
  sessionStart: SessionStartRow,
  sessionOffer: SessionOfferRow,
  [OFFER_RESULT]: OfferResultRow,
  [QUEUED_MESSAGE]: QueuedMessageRow,
  [PENDING_MESSAGES]: PendingMessagesRow,
  [LANE_NOTICE_BATCH]: LaneNoticeBatchRow,
  [STARTED_SESSIONS]: StartedSessionsRow,
  [TASK_LINE]: TaskLineRow,
  typing: NoticeRow,
  permission: PermissionRow,
  [QUESTION_RECORD]: QuestionRecordRow,
  [PERMISSION_RECORD]: PermissionRecordRow,
  [SHELL_ROW]: ShellRow,
  [SUBAGENTS]: SubagentGroupRow,
  [SUBAGENT_ROW]: SubagentRow,
  [SUBAGENT_DONE]: SubagentDoneRow,
  [SUBAGENT_OF]: SubagentOfPillRow,
  [SUBAGENT_EMPTY]: SubagentEmptyRow,
  [WORKFLOW_CARD]: WorkflowCardRow,
};

/// A read-only transcript's rows (conversation/readOnly.ts): the default rows, except where a row is
/// only a control on the owner's machine or another of the owner's chats. A pending ask reads as a
/// line (the guest page says who answers it); another agent's waiting message as its received line;
/// a paused agent pair without Resume. Suggested tasks, started chats, a turn's local page and its
/// render frame are the owner's own and draw nothing.
const NoRow = () => null;

export const readOnlyRegistry: NativeRegistry = {
  ...defaultRegistry,
  permission: ReadOnlyPermissionRow,
  [QUEUED_MESSAGE]: ReadOnlyQueuedMessageRow,
  agentPair: ReadOnlyAgentPairRow,
  sessionOffer: NoRow,
  [OFFER_RESULT]: NoRow,
  [STARTED_SESSIONS]: NoRow,
  [TASK_LINE]: NoRow,
  [NEXT_STEP]: ReadOnlyNextStepRow,
  [RENDER]: NoRow,
};
