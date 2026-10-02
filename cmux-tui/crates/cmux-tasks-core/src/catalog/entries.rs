//! Every Tasks op, once. Param names equal the op structs' field names
//! (tests/catalog.rs proves each mutation's params round-trip into `Op`).

use super::{Class, Entry, Expose, Param, Risk, Ty};
use crate::ids::prefix;

const fn p(name: &'static str, ty: Ty, doc: &'static str) -> Param {
    Param { name, ty, required: false, positional: false, repeated: false, doc }
}

impl Param {
    const fn req(self) -> Self {
        Self { required: true, ..self }
    }
    const fn pos(self) -> Self {
        Self { positional: true, required: true, ..self }
    }
    const fn many(self) -> Self {
        Self { repeated: true, ..self }
    }
}

const PRIORITY: Ty = Ty::Enum(&["none", "urgent", "high", "medium", "low"]);
const CATEGORY: Ty = Ty::Enum(&["triage", "backlog", "unstarted", "started", "completed", "canceled"]);
const SESSION_STATUS: Ty = Ty::Enum(&["working", "awaiting_input", "done", "failed"]);
const PROJECT_STATE: Ty = Ty::Enum(&["planned", "active", "paused", "completed", "canceled"]);
const RELATION_KIND: Ty = Ty::Enum(&["blocks", "related", "duplicate"]);
const ORDER: Ty = Ty::Enum(&["manual", "priority", "updated", "created"]);
const TASK: Param = p("task", Ty::TaskRef, "Task key (CMX-12), task_ id or unique id prefix").pos();

const fn id(prefix: &'static str, doc: &'static str) -> Param {
    p("id", Ty::Id { prefix, generate: true }, doc).req()
}

const LIST: &[Param] = &[
    p("mine", Ty::Bool, "Only tasks assigned or delegated to me"),
    p("status", Ty::Str, "Status name, id or category").many(),
    p("open", Ty::Bool, "Only open categories"),
    p("assignee", Ty::Str, "me, usr_ or agt_ id"),
    p("label", Ty::Str, "Label name or id (all must match)").many(),
    p("project", Ty::Str, "Project name or id"),
    p("search", Ty::Str, "Text in key, title or description"),
    p("attention", Ty::Bool, "Only tasks that need attention"),
    p("archived", Ty::Bool, "Archived tasks instead of active ones"),
    p("order", ORDER, "Sort order"),
    p("limit", Ty::U32, "Maximum number of tasks"),
];

const CREATE: &[Param] = &[
    id(prefix::TASK, "Client-chosen task id (generated when omitted)"),
    p("title", Ty::Str, "Title").req(),
    p("description", Ty::Str, "Markdown description"),
    p("status", Ty::Str, "Status name or id"),
    p("priority", PRIORITY, "Priority"),
    p("assignee", Ty::Str, "me or usr_ id"),
    p("labels", Ty::Str, "Label names or ids").many(),
    p("project", Ty::Str, "Project name or id"),
    p("parent", Ty::TaskRef, "Parent task"),
    p("estimate", Ty::U32, "Estimate points"),
    p("due", Ty::Str, "Due date YYYY-MM-DD"),
    p("sort_key", Ty::Str, "Fractional sort key"),
];

const UPDATE: &[Param] = &[
    TASK,
    p("title", Ty::Str, "New title"),
    p("status", Ty::Str, "Status name or id"),
    p("priority", PRIORITY, "Priority"),
    p("assignee", Ty::Str, "me or usr_ id"),
    p("unassign", Ty::Bool, "Clear the assignee"),
    p("add_labels", Ty::Str, "Labels to add").many(),
    p("remove_labels", Ty::Str, "Labels to remove").many(),
    p("project", Ty::Str, "Project name or id"),
    p("clear_project", Ty::Bool, "Remove from its project"),
    p("parent", Ty::TaskRef, "Parent task"),
    p("clear_parent", Ty::Bool, "Clear the parent"),
    p("estimate", Ty::U32, "Estimate points"),
    p("due", Ty::Str, "Due date YYYY-MM-DD"),
    p("description", Ty::Str, "Replacement description (needs if_version)"),
    p("if_version", Ty::U64, "Description version being replaced"),
];

const SESSION: Param = p("session", Ty::Id { prefix: prefix::SESSION, generate: false }, "Agent session id").pos();
const COMMENT: Param = p("comment", Ty::Id { prefix: prefix::COMMENT, generate: false }, "Comment id").pos();

static ENTRIES: &[Entry] = &[
    Entry { name: "task.list", class: Class::Read, risk: Risk::Read, cli: "task list", mcp: Expose::Default, palette: None, docs: "List tasks with filters.", params: LIST },
    Entry { name: "task.get", class: Class::Read, risk: Risk::Read, cli: "task view", mcp: Expose::Default, palette: None, docs: "Read one task with comments, relations and agent sessions.", params: &[TASK] },
    Entry { name: "task.subscribe", class: Class::Stream, risk: Risk::Read, cli: "task watch", mcp: Expose::Never, palette: None, docs: "Stream task events in commit order.", params: &[p("after_seq", Ty::U64, "Resume after this sequence")] },
    Entry { name: "task.create", class: Class::Mutation, risk: Risk::MutateShared, cli: "task create", mcp: Expose::Default, palette: Some("New Task"), docs: "Create a task.", params: CREATE },
    Entry { name: "task.update", class: Class::Mutation, risk: Risk::MutateShared, cli: "task update", mcp: Expose::Default, palette: Some("Change Task Status"), docs: "Change a task's fields.", params: UPDATE },
    Entry { name: "task.move", class: Class::Mutation, risk: Risk::MutateShared, cli: "task move", mcp: Expose::OptIn, palette: None, docs: "Reorder a task between two others.", params: &[TASK, p("after", Ty::TaskRef, "Task that precedes it"), p("before", Ty::TaskRef, "Task that follows it")] },
    Entry { name: "task.archive", class: Class::Mutation, risk: Risk::MutateShared, cli: "task archive", mcp: Expose::Default, palette: Some("Archive Task"), docs: "Archive a task.", params: &[TASK] },
    Entry { name: "task.unarchive", class: Class::Mutation, risk: Risk::MutateShared, cli: "task unarchive", mcp: Expose::OptIn, palette: None, docs: "Restore an archived task.", params: &[TASK] },
    Entry { name: "task.delete", class: Class::Mutation, risk: Risk::Destructive, cli: "task delete", mcp: Expose::OptIn, palette: Some("Delete Task"), docs: "Delete a task; its relations go with it.", params: &[TASK] },
    Entry { name: "task.delegate", class: Class::Mutation, risk: Risk::Execute, cli: "task delegate", mcp: Expose::Default, palette: Some("Delegate Task to Agent"), docs: "Hand a task to an agent; a dispatcher starts the agent session.", params: &[
        TASK,
        p("session", Ty::Id { prefix: prefix::SESSION, generate: true }, "Client-chosen session id (generated when omitted)").req(),
        p("harness", Ty::Str, "Agent harness: claude, codex, opencode, …").req(),
        p("agent", Ty::Id { prefix: prefix::AGENT, generate: false }, "Agent principal"),
        p("class", Ty::Enum(&["mux", "ordinary"]), "Agent class"),
        p("target", Ty::Str, "local, vm or host:<id>"),
        p("prompt", Ty::Str, "Extra instructions"),
    ] },
    Entry { name: "task.session.list", class: Class::Read, risk: Risk::Read, cli: "task session list", mcp: Expose::Default, palette: None, docs: "List agent sessions, optionally of one task.", params: &[p("task", Ty::TaskRef, "Task"), p("active", Ty::Bool, "Only active sessions")] },
    Entry { name: "task.session.claim", class: Class::Mutation, risk: Risk::MutateShared, cli: "task session claim", mcp: Expose::Never, palette: None, docs: "Claim a pending agent session for a host (one dispatcher wins).", params: &[SESSION, p("host", Ty::Str, "Host that will run it").req()] },
    Entry { name: "task.session.attach", class: Class::Mutation, risk: Risk::MutateShared, cli: "task session attach", mcp: Expose::OptIn, palette: None, docs: "Link a running agent session to its task session.", params: &[SESSION, p("acp_session", Ty::Str, "acpmux session id").req(), p("workspace", Ty::Str, "Workspace id"), p("host", Ty::Str, "Host id")] },
    Entry { name: "task.session.update", class: Class::Mutation, risk: Risk::MutateOwn, cli: "task session update", mcp: Expose::Default, palette: None, docs: "Report an agent session's status, plan or PR.", params: &[SESSION, p("status", SESSION_STATUS, "Session status"), p("plan", Ty::Json, "Plan steps [{content, status}]"), p("pr", Ty::Str, "Pull request URL")] },
    Entry { name: "task.session.cancel", class: Class::Mutation, risk: Risk::MutateShared, cli: "task session cancel", mcp: Expose::OptIn, palette: None, docs: "Cancel an agent session.", params: &[SESSION] },
    Entry { name: "task.comment.list", class: Class::Read, risk: Risk::Read, cli: "task comment list", mcp: Expose::Default, palette: None, docs: "List a task's comments.", params: &[TASK] },
    Entry { name: "task.comment.add", class: Class::Mutation, risk: Risk::MutateShared, cli: "task comment add", mcp: Expose::Default, palette: Some("Comment on Task"), docs: "Comment on a task.", params: &[TASK, id(prefix::COMMENT, "Client-chosen comment id (generated when omitted)"), p("body", Ty::Str, "Markdown body").req(), p("reply_to", Ty::Id { prefix: prefix::COMMENT, generate: false }, "Thread's first comment")] },
    Entry { name: "task.comment.update", class: Class::Mutation, risk: Risk::MutateOwn, cli: "task comment update", mcp: Expose::OptIn, palette: None, docs: "Edit your comment.", params: &[COMMENT, p("body", Ty::Str, "New body").req(), p("if_version", Ty::U64, "Version being replaced").req()] },
    Entry { name: "task.comment.delete", class: Class::Mutation, risk: Risk::MutateOwn, cli: "task comment delete", mcp: Expose::OptIn, palette: None, docs: "Delete your comment.", params: &[COMMENT] },
    Entry { name: "task.relation.add", class: Class::Mutation, risk: Risk::MutateShared, cli: "task relation add", mcp: Expose::Default, palette: None, docs: "Relate two tasks (blocks, related, duplicate).", params: &[id(prefix::RELATION, "Client-chosen relation id (generated when omitted)"), p("kind", RELATION_KIND, "Relation kind").req(), p("from", Ty::TaskRef, "From task").req(), p("to", Ty::TaskRef, "To task").req()] },
    Entry { name: "task.relation.remove", class: Class::Mutation, risk: Risk::MutateShared, cli: "task relation remove", mcp: Expose::OptIn, palette: None, docs: "Remove a relation.", params: &[p("relation", Ty::Id { prefix: prefix::RELATION, generate: false }, "Relation id").pos()] },
    Entry { name: "task.label.list", class: Class::Read, risk: Risk::Read, cli: "task label list", mcp: Expose::Default, palette: None, docs: "List labels.", params: &[] },
    Entry { name: "task.label.create", class: Class::Mutation, risk: Risk::MutateShared, cli: "task label create", mcp: Expose::OptIn, palette: None, docs: "Create a label.", params: &[id(prefix::LABEL, "Client-chosen label id (generated when omitted)"), p("name", Ty::Str, "Name").req(), p("color", Ty::U32, "Ghostty palette index 0-15")] },
    Entry { name: "task.label.update", class: Class::Mutation, risk: Risk::MutateShared, cli: "task label update", mcp: Expose::OptIn, palette: None, docs: "Rename or recolor a label.", params: &[p("label", Ty::Str, "Label name or id").pos(), p("name", Ty::Str, "New name"), p("color", Ty::U32, "Ghostty palette index 0-15")] },
    Entry { name: "task.label.delete", class: Class::Mutation, risk: Risk::MutateShared, cli: "task label delete", mcp: Expose::OptIn, palette: None, docs: "Delete a label and remove it from tasks.", params: &[p("label", Ty::Str, "Label name or id").pos()] },
    Entry { name: "task.status.list", class: Class::Read, risk: Risk::Read, cli: "task status list", mcp: Expose::Default, palette: None, docs: "List workflow statuses.", params: &[] },
    Entry { name: "task.status.create", class: Class::Mutation, risk: Risk::MutateShared, cli: "task status create", mcp: Expose::OptIn, palette: None, docs: "Add a workflow status.", params: &[id(prefix::STATUS, "Client-chosen status id (generated when omitted)"), p("name", Ty::Str, "Name").req(), p("category", CATEGORY, "Category").req(), p("color", Ty::U32, "Ghostty palette index 0-15"), p("position", Ty::I64, "Position")] },
    Entry { name: "task.status.update", class: Class::Mutation, risk: Risk::MutateShared, cli: "task status update", mcp: Expose::OptIn, palette: None, docs: "Rename, recolor or reorder a status.", params: &[p("status", Ty::Str, "Status name or id").pos(), p("name", Ty::Str, "New name"), p("color", Ty::U32, "Ghostty palette index 0-15"), p("position", Ty::I64, "Position")] },
    Entry { name: "task.status.delete", class: Class::Mutation, risk: Risk::MutateShared, cli: "task status delete", mcp: Expose::OptIn, palette: None, docs: "Delete a status; its tasks move to the replacement.", params: &[p("status", Ty::Str, "Status name or id").pos(), p("replacement", Ty::Str, "Status for its tasks").req()] },
    Entry { name: "task.project.list", class: Class::Read, risk: Risk::Read, cli: "task project list", mcp: Expose::Default, palette: None, docs: "List projects.", params: &[] },
    Entry { name: "task.project.create", class: Class::Mutation, risk: Risk::MutateShared, cli: "task project create", mcp: Expose::OptIn, palette: None, docs: "Create a project.", params: &[id(prefix::PROJECT, "Client-chosen project id (generated when omitted)"), p("name", Ty::Str, "Name").req(), p("state", PROJECT_STATE, "State")] },
    Entry { name: "task.project.update", class: Class::Mutation, risk: Risk::MutateShared, cli: "task project update", mcp: Expose::OptIn, palette: None, docs: "Rename a project or change its state.", params: &[p("project", Ty::Str, "Project name or id").pos(), p("name", Ty::Str, "New name"), p("state", PROJECT_STATE, "State")] },
    Entry { name: "task.project.archive", class: Class::Mutation, risk: Risk::MutateShared, cli: "task project archive", mcp: Expose::OptIn, palette: None, docs: "Archive a project; its tasks leave it.", params: &[p("project", Ty::Str, "Project name or id").pos()] },
    Entry { name: "task.settings.get", class: Class::Read, risk: Risk::Read, cli: "task settings get", mcp: Expose::OptIn, palette: None, docs: "Read the team's task settings.", params: &[] },
    Entry { name: "task.settings.update", class: Class::Mutation, risk: Risk::MutateShared, cli: "task settings update", mcp: Expose::OptIn, palette: None, docs: "Change key prefix, default statuses or the agent flow.", params: &[
        p("key_prefix", Ty::Str, "Task key prefix, e.g. CMX"),
        p("default_status", Ty::Str, "Status for new tasks"),
        p("started_status", Ty::Str, "Status when an agent starts"),
        p("review_status", Ty::Str, "Status when an agent is done"),
        p("clear_review_status", Ty::Bool, "No review status"),
        p("agent_flow", Ty::Enum(&["forward", "off"]), "Whether status follows agent activity"),
    ] },
];

pub fn all() -> &'static [Entry] {
    ENTRIES
}
