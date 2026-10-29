// The transcript's row renderers by row kind (App.tsx VirtualTranscript), one module each in
// rows/; a user's registry.js adds or replaces them (window.cmuxAcpmuxRegistry).
import { ACTIVITY_LINE, DATE, PREVIEW, RENDER, THINKING, WORKED, WORKING } from "../conversation/turns";
import { QUEUED_MESSAGE, WAITING_MESSAGES } from "../model";
import { OFFER_RESULT } from "../offer/offersShown";
import { PERMISSION_RECORD } from "../permissions/record";
import { QUESTION_RECORD } from "../question/record";
import { ShellRow } from "../shell/ShellRow";
import { SHELL_ROW } from "../shell/shellRuns";
import { STARTED_SESSIONS } from "../started/startedSessions";
import { SUBAGENTS } from "../subagents/subagentFold";
import { SUBAGENT_DONE, SUBAGENT_OF, SUBAGENT_ROW, WORKFLOW_CARD } from "../subagents/subagentRows";
import { ActivityLineRow } from "./ActivityLineRow";
import { AgentPairRow } from "./AgentPairRow";
import { BackgroundTaskRow } from "./BackgroundTaskRow";
import { CompactionRow } from "./CompactionRow";
import { DateRow } from "./DateRow";
import { EditedFilesRow } from "./EditedFilesRow";
import { FailoverRow } from "./FailoverRow";
import { MessageRow } from "./MessageRow";
import { NoticeRow } from "./NoticeRow";
import { OfferResultRow } from "./OfferResultRow";
import { PermissionRecordRow } from "./PermissionRecordRow";
import { PermissionRow } from "./PermissionRow";
import { PlanRow } from "./PlanRow";
import { PolicyUnenforcedRow } from "./PolicyUnenforcedRow";
import { PreviewRow } from "./PreviewRow";
import { QueuedMessageRow } from "./QueuedMessageRow";
import { WaitingMessagesRow } from "./WaitingMessagesRow";
import { QuestionRecordRow } from "./QuestionRecordRow";
import { RenderRow } from "./RenderRow";
import { SessionOfferRow } from "./SessionOfferRow";
import { SessionStartRow } from "./SessionStartRow";
import { StartedSessionsRow } from "./StartedSessionsRow";
import { SubagentDoneRow } from "./SubagentDoneRow";
import { SubagentGroupRow } from "./SubagentGroupRow";
import { SubagentOfPillRow } from "./SubagentOfPillRow";
import { SubagentRow } from "./SubagentRow";
import { SummaryRow } from "./SummaryRow";
import { ThinkingRow } from "./ThinkingRow";
import { ToolActivityRow } from "./ToolActivityRow";
import { WorkedRow } from "./WorkedRow";
import { WorkflowCardRow } from "./WorkflowCardRow";
import { WorkingRow } from "./WorkingRow";
import type { NativeRegistry } from "./rowProps";

export const defaultRegistry: NativeRegistry = {
  user: MessageRow,
  assistant: MessageRow,
  activity: ToolActivityRow,
  [WORKED]: WorkedRow,
  [DATE]: DateRow,
  [THINKING]: ThinkingRow,
  [WORKING]: WorkingRow,
  [ACTIVITY_LINE]: ActivityLineRow,
  [PREVIEW]: PreviewRow,
  [RENDER]: RenderRow,
  editedFiles: EditedFilesRow,
  turnSummary: SummaryRow,
  notice: NoticeRow,
  plan: PlanRow,
  backgroundTask: BackgroundTaskRow,
  compaction: CompactionRow,
  failover: FailoverRow,
  policyUnenforced: PolicyUnenforcedRow,
  agentPair: AgentPairRow,
  sessionStart: SessionStartRow,
  sessionOffer: SessionOfferRow,
  [OFFER_RESULT]: OfferResultRow,
  [QUEUED_MESSAGE]: QueuedMessageRow,
  [WAITING_MESSAGES]: WaitingMessagesRow,
  [STARTED_SESSIONS]: StartedSessionsRow,
  typing: NoticeRow,
  permission: PermissionRow,
  [QUESTION_RECORD]: QuestionRecordRow,
  [PERMISSION_RECORD]: PermissionRecordRow,
  [SHELL_ROW]: ShellRow,
  [SUBAGENTS]: SubagentGroupRow,
  [SUBAGENT_ROW]: SubagentRow,
  [SUBAGENT_DONE]: SubagentDoneRow,
  [SUBAGENT_OF]: SubagentOfPillRow,
  [WORKFLOW_CARD]: WorkflowCardRow,
};

export const currentRegistry = (): NativeRegistry => ({
  ...defaultRegistry,
  ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined),
});
