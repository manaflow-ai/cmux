//! Request fields, env vars and tags the CLI (`client.rs`) and the daemon (`hub`) both name:
//! session lineage (`hub/lineage.rs`), the caller session (`hub/start_gate.rs`) and the
//! spawned-by tag (`hub/views.rs`).

/// `_meta.acpmux` field of `session/new`: the parent asked for. Absent: the proven caller.
/// Null: none (an ephemeral run, a probe: never a child). A session id: the caller itself or
/// one of its descendants, else refused.
pub const PARENT_FIELD: &str = "parent";
/// `_meta.acpmux` field of `session/new`: the caller's tool call that runs it.
pub const TOOL_CALL_FIELD: &str = "spawnToolCallId";
/// The env var a harness may set to the id of the tool call that runs a command;
/// `acpmux new` sends it as [`TOOL_CALL_FIELD`].
pub const TOOL_CALL_ENV: &str = "ACPMUX_TOOL_CALL_ID";
/// `_meta.acpmux` field of a first `initialize`: `{sessionId, token}`.
pub const CALLER_FIELD: &str = "callerSession";
/// The tag naming the session whose agent started this one (`Hub::spawned_by`).
pub const SPAWNED_BY_TAG: &str = "spawnedBy";
