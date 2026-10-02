// Generated from cmux-tasks-core::catalog. Do not edit.
/** List tasks with filters. */
export interface TaskListParams {
  /** Only tasks assigned or delegated to me */
  mine?: boolean;
  /** Status name, id or category */
  status?: Array<string>;
  /** Only open categories */
  open?: boolean;
  /** me, usr_ or agt_ id */
  assignee?: string;
  /** Label name or id (all must match) */
  label?: Array<string>;
  /** Project name or id */
  project?: string;
  /** Text in key, title or description */
  search?: string;
  /** Only tasks that need attention */
  attention?: boolean;
  /** Archived tasks instead of active ones */
  archived?: boolean;
  /** Sort order */
  order?: "manual" | "priority" | "updated" | "created";
  /** Maximum number of tasks */
  limit?: number;
}
/** Read one task with comments, relations and agent sessions. */
export interface TaskGetParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
}
/** Stream task events in commit order. */
export interface TaskSubscribeParams {
  /** Resume after this sequence */
  after_seq?: number;
}
/** Create a task. */
export interface TaskCreateParams {
  /** Client-chosen task id (generated when omitted) */
  id: string;
  /** Title */
  title: string;
  /** Markdown description */
  description?: string;
  /** Status name or id */
  status?: string;
  /** Priority */
  priority?: "none" | "urgent" | "high" | "medium" | "low";
  /** me or usr_ id */
  assignee?: string;
  /** Label names or ids */
  labels?: Array<string>;
  /** Project name or id */
  project?: string;
  /** Parent task */
  parent?: string;
  /** Estimate points */
  estimate?: number;
  /** Due date YYYY-MM-DD */
  due?: string;
  /** Fractional sort key */
  sort_key?: string;
}
/** Change a task's fields. */
export interface TaskUpdateParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
  /** New title */
  title?: string;
  /** Status name or id */
  status?: string;
  /** Priority */
  priority?: "none" | "urgent" | "high" | "medium" | "low";
  /** me or usr_ id */
  assignee?: string;
  /** Clear the assignee */
  unassign?: boolean;
  /** Labels to add */
  add_labels?: Array<string>;
  /** Labels to remove */
  remove_labels?: Array<string>;
  /** Project name or id */
  project?: string;
  /** Remove from its project */
  clear_project?: boolean;
  /** Parent task */
  parent?: string;
  /** Clear the parent */
  clear_parent?: boolean;
  /** Estimate points */
  estimate?: number;
  /** Due date YYYY-MM-DD */
  due?: string;
  /** Replacement description (needs if_version) */
  description?: string;
  /** Description version being replaced */
  if_version?: number;
}
/** Reorder a task between two others. */
export interface TaskMoveParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
  /** Task that precedes it */
  after?: string;
  /** Task that follows it */
  before?: string;
}
/** Archive a task. */
export interface TaskArchiveParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
}
/** Restore an archived task. */
export interface TaskUnarchiveParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
}
/** Delete a task; its relations go with it. */
export interface TaskDeleteParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
}
/** Hand a task to an agent; a dispatcher starts the agent session. */
export interface TaskDelegateParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
  /** Client-chosen session id (generated when omitted) */
  session: string;
  /** Agent harness: claude, codex, opencode, … */
  harness: string;
  /** Agent principal */
  agent?: string;
  /** Agent class */
  class?: "mux" | "ordinary";
  /** local, vm or host:<id> */
  target?: string;
  /** Extra instructions */
  prompt?: string;
}
/** List agent sessions, optionally of one task. */
export interface TaskSessionListParams {
  /** Task */
  task?: string;
  /** Only active sessions */
  active?: boolean;
}
/** Claim a pending agent session for a host (one dispatcher wins). */
export interface TaskSessionClaimParams {
  /** Agent session id */
  session: string;
  /** Host that will run it */
  host: string;
}
/** Link a running agent session to its task session. */
export interface TaskSessionAttachParams {
  /** Agent session id */
  session: string;
  /** acpmux session id */
  acp_session: string;
  /** Workspace id */
  workspace?: string;
  /** Host id */
  host?: string;
}
/** Report an agent session's status, plan or PR. */
export interface TaskSessionUpdateParams {
  /** Agent session id */
  session: string;
  /** Session status */
  status?: "working" | "awaiting_input" | "done" | "failed";
  /** Plan steps [{content, status}] */
  plan?: unknown;
  /** Pull request URL */
  pr?: string;
}
/** Cancel an agent session. */
export interface TaskSessionCancelParams {
  /** Agent session id */
  session: string;
}
/** List a task's comments. */
export interface TaskCommentListParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
}
/** Comment on a task. */
export interface TaskCommentAddParams {
  /** Task key (CMX-12), task_ id or unique id prefix */
  task: string;
  /** Client-chosen comment id (generated when omitted) */
  id: string;
  /** Markdown body */
  body: string;
  /** Thread's first comment */
  reply_to?: string;
}
/** Edit your comment. */
export interface TaskCommentUpdateParams {
  /** Comment id */
  comment: string;
  /** New body */
  body: string;
  /** Version being replaced */
  if_version: number;
}
/** Delete your comment. */
export interface TaskCommentDeleteParams {
  /** Comment id */
  comment: string;
}
/** Relate two tasks (blocks, related, duplicate). */
export interface TaskRelationAddParams {
  /** Client-chosen relation id (generated when omitted) */
  id: string;
  /** Relation kind */
  kind: "blocks" | "related" | "duplicate";
  /** From task */
  from: string;
  /** To task */
  to: string;
}
/** Remove a relation. */
export interface TaskRelationRemoveParams {
  /** Relation id */
  relation: string;
}
/** List labels. */
export interface TaskLabelListParams {
}
/** Create a label. */
export interface TaskLabelCreateParams {
  /** Client-chosen label id (generated when omitted) */
  id: string;
  /** Name */
  name: string;
  /** Ghostty palette index 0-15 */
  color?: number;
}
/** Rename or recolor a label. */
export interface TaskLabelUpdateParams {
  /** Label name or id */
  label: string;
  /** New name */
  name?: string;
  /** Ghostty palette index 0-15 */
  color?: number;
}
/** Delete a label and remove it from tasks. */
export interface TaskLabelDeleteParams {
  /** Label name or id */
  label: string;
}
/** List workflow statuses. */
export interface TaskStatusListParams {
}
/** Add a workflow status. */
export interface TaskStatusCreateParams {
  /** Client-chosen status id (generated when omitted) */
  id: string;
  /** Name */
  name: string;
  /** Category */
  category: "triage" | "backlog" | "unstarted" | "started" | "completed" | "canceled";
  /** Ghostty palette index 0-15 */
  color?: number;
  /** Position */
  position?: number;
}
/** Rename, recolor or reorder a status. */
export interface TaskStatusUpdateParams {
  /** Status name or id */
  status: string;
  /** New name */
  name?: string;
  /** Ghostty palette index 0-15 */
  color?: number;
  /** Position */
  position?: number;
}
/** Delete a status; its tasks move to the replacement. */
export interface TaskStatusDeleteParams {
  /** Status name or id */
  status: string;
  /** Status for its tasks */
  replacement: string;
}
/** List projects. */
export interface TaskProjectListParams {
}
/** Create a project. */
export interface TaskProjectCreateParams {
  /** Client-chosen project id (generated when omitted) */
  id: string;
  /** Name */
  name: string;
  /** State */
  state?: "planned" | "active" | "paused" | "completed" | "canceled";
}
/** Rename a project or change its state. */
export interface TaskProjectUpdateParams {
  /** Project name or id */
  project: string;
  /** New name */
  name?: string;
  /** State */
  state?: "planned" | "active" | "paused" | "completed" | "canceled";
}
/** Archive a project; its tasks leave it. */
export interface TaskProjectArchiveParams {
  /** Project name or id */
  project: string;
}
/** Read the team's task settings. */
export interface TaskSettingsGetParams {
}
/** Change key prefix, default statuses or the agent flow. */
export interface TaskSettingsUpdateParams {
  /** Task key prefix, e.g. CMX */
  key_prefix?: string;
  /** Status for new tasks */
  default_status?: string;
  /** Status when an agent starts */
  started_status?: string;
  /** Status when an agent is done */
  review_status?: string;
  /** No review status */
  clear_review_status?: boolean;
  /** Whether status follows agent activity */
  agent_flow?: "forward" | "off";
}
export interface OpResult { id: string; key?: string }
export interface TaskEvent { seq: number; index: number; tx: string; kind: string; details?: unknown; change: unknown }
export interface Mux {
  task: {
    /** List tasks with filters. */
    list(params: TaskListParams): Promise<unknown>;
    /** Read one task with comments, relations and agent sessions. */
    get(params: TaskGetParams): Promise<unknown>;
    /** Stream task events in commit order. */
    subscribe(params: TaskSubscribeParams): Promise<AsyncIterable<TaskEvent>>;
    /** Create a task. */
    create(params: TaskCreateParams): Promise<OpResult>;
    /** Change a task's fields. */
    update(params: TaskUpdateParams): Promise<OpResult>;
    /** Reorder a task between two others. */
    move(params: TaskMoveParams): Promise<OpResult>;
    /** Archive a task. */
    archive(params: TaskArchiveParams): Promise<OpResult>;
    /** Restore an archived task. */
    unarchive(params: TaskUnarchiveParams): Promise<OpResult>;
    /** Delete a task; its relations go with it. */
    delete(params: TaskDeleteParams): Promise<OpResult>;
    /** Hand a task to an agent; a dispatcher starts the agent session. */
    delegate(params: TaskDelegateParams): Promise<OpResult>;
    /** List agent sessions, optionally of one task. */
    session_list(params: TaskSessionListParams): Promise<unknown>;
    /** Claim a pending agent session for a host (one dispatcher wins). */
    session_claim(params: TaskSessionClaimParams): Promise<OpResult>;
    /** Link a running agent session to its task session. */
    session_attach(params: TaskSessionAttachParams): Promise<OpResult>;
    /** Report an agent session's status, plan or PR. */
    session_update(params: TaskSessionUpdateParams): Promise<OpResult>;
    /** Cancel an agent session. */
    session_cancel(params: TaskSessionCancelParams): Promise<OpResult>;
    /** List a task's comments. */
    comment_list(params: TaskCommentListParams): Promise<unknown>;
    /** Comment on a task. */
    comment_add(params: TaskCommentAddParams): Promise<OpResult>;
    /** Edit your comment. */
    comment_update(params: TaskCommentUpdateParams): Promise<OpResult>;
    /** Delete your comment. */
    comment_delete(params: TaskCommentDeleteParams): Promise<OpResult>;
    /** Relate two tasks (blocks, related, duplicate). */
    relation_add(params: TaskRelationAddParams): Promise<OpResult>;
    /** Remove a relation. */
    relation_remove(params: TaskRelationRemoveParams): Promise<OpResult>;
    /** List labels. */
    label_list(params: TaskLabelListParams): Promise<unknown>;
    /** Create a label. */
    label_create(params: TaskLabelCreateParams): Promise<OpResult>;
    /** Rename or recolor a label. */
    label_update(params: TaskLabelUpdateParams): Promise<OpResult>;
    /** Delete a label and remove it from tasks. */
    label_delete(params: TaskLabelDeleteParams): Promise<OpResult>;
    /** List workflow statuses. */
    status_list(params: TaskStatusListParams): Promise<unknown>;
    /** Add a workflow status. */
    status_create(params: TaskStatusCreateParams): Promise<OpResult>;
    /** Rename, recolor or reorder a status. */
    status_update(params: TaskStatusUpdateParams): Promise<OpResult>;
    /** Delete a status; its tasks move to the replacement. */
    status_delete(params: TaskStatusDeleteParams): Promise<OpResult>;
    /** List projects. */
    project_list(params: TaskProjectListParams): Promise<unknown>;
    /** Create a project. */
    project_create(params: TaskProjectCreateParams): Promise<OpResult>;
    /** Rename a project or change its state. */
    project_update(params: TaskProjectUpdateParams): Promise<OpResult>;
    /** Archive a project; its tasks leave it. */
    project_archive(params: TaskProjectArchiveParams): Promise<OpResult>;
    /** Read the team's task settings. */
    settings_get(params: TaskSettingsGetParams): Promise<unknown>;
    /** Change key prefix, default statuses or the agent flow. */
    settings_update(params: TaskSettingsUpdateParams): Promise<OpResult>;
  };
}

