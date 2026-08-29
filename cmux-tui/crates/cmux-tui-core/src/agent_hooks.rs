use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::resource::TerminalPublicId;
use crate::{
    JournalClass, JournalEventSchema, JournalIngress, JournalProducerManifest, JournalReplayPolicy,
    JournalSensitivity, JournalSubject,
};

pub const AGENT_HOOK_PRODUCER_ID: &str = "cmux_agent";
pub const AGENT_HOOK_MANIFEST_VERSION: u32 = 1;
pub(crate) const AGENT_HOOK_FORMAT: &str = "cmux.agent-hook.v1";
const MAX_AGENT_SOURCE_BYTES: usize = 64;
const MAX_NATIVE_EVENT_BYTES: usize = 128;
const NORMALIZED_TEXT_BYTES: usize = 8 * 1024;
const MAX_AGENT_REDACTION_DEPTH: usize = 32;
const MAX_AGENT_REDACTION_NODES: usize = 4_096;
const REDACTED_AGENT_VALUE: &str = "[redacted]";
const STRUCTURE_LIMIT_REASON: &str = "structure_limit";

const AGENT_EVENT_KINDS: [&str; 12] = [
    "agent.session.started",
    "agent.turn.started",
    "agent.turn.completed",
    "agent.child.spawned",
    "agent.child.completed",
    "agent.child.failed",
    "agent.approval.requested",
    "agent.question.requested",
    "agent.plan_review.requested",
    "agent.error.reported",
    "agent.state.changed",
    "agent.session.ended",
];

pub fn agent_hook_journal_ingress(
    source: &str,
    native_event: &str,
    terminal_id: Option<&str>,
    native: Value,
) -> anyhow::Result<JournalIngress> {
    validate_agent_source(source)?;
    validate_native_event(native_event)?;
    let terminal_id = terminal_id.map(TerminalPublicId::parse).transpose()?;
    let native = redact_agent_native(native_event, native);
    let mut normalized = normalized_fields(&native);
    add_agent_topology(source, native_event, terminal_id.as_ref(), &mut normalized);
    let kind = semantic_kind(source, native_event, &normalized);
    let mut subjects = Vec::with_capacity(4);
    if let Some(terminal_id) = terminal_id {
        subjects.push(JournalSubject { kind: "terminal".into(), id: terminal_id.to_string() });
    }
    for (field, kind) in [
        ("agent_tree_id", "agent_tree"),
        ("agent_node_id", "agent_node"),
        ("parent_agent_node_id", "agent_parent"),
    ] {
        if let Some(id) = normalized.get(field).and_then(Value::as_str) {
            subjects.push(JournalSubject { kind: kind.into(), id: id.into() });
        }
    }
    Ok(JournalIngress {
        producer_id: AGENT_HOOK_PRODUCER_ID.into(),
        manifest_version: AGENT_HOOK_MANIFEST_VERSION,
        kind: kind.into(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects,
        sensitivity: Some(JournalSensitivity::Sensitive),
        payload: json!({
            "format":AGENT_HOOK_FORMAT,
            "adapter":{"id":source,"version":1},
            "native_event":native_event,
            "normalized":normalized,
            "native":native,
        }),
        causation_id: None,
        correlation_id: None,
    })
}

fn redact_agent_native(native_event: &str, mut native: Value) -> Value {
    if semantic_key(native_event) == "input" {
        return json!({"redacted":true,"reason":"raw_input"});
    }
    redact_agent_fields(&mut native);
    native
}

fn redact_agent_fields(value: &mut Value) {
    let mut budget = MAX_AGENT_REDACTION_NODES;
    redact_agent_value(value, false, 0, &mut budget);
}

/// Redact untrusted hook JSON with explicit structural limits. Returning
/// `false` makes the nearest containing value one bounded marker, which also
/// stops walking a hostile wide object or array after the budget is spent.
fn redact_agent_value(
    value: &mut Value,
    preserve_strings: bool,
    depth: usize,
    budget: &mut usize,
) -> bool {
    if depth > MAX_AGENT_REDACTION_DEPTH || *budget == 0 {
        *value = structure_limit_value();
        return false;
    }
    *budget -= 1;

    let mut complete = true;
    match value {
        Value::Object(fields) => {
            for (field, child) in fields.iter_mut() {
                if agent_field_is_sensitive(field) {
                    // Sensitive leaves bypass recursive traversal, so charge
                    // them explicitly. Otherwise an attacker can submit an
                    // arbitrarily wide object of credential-shaped fields
                    // without consuming the structural budget.
                    if *budget == 0 {
                        complete = false;
                        break;
                    }
                    *budget -= 1;
                    *child = Value::String(REDACTED_AGENT_VALUE.into());
                } else if !redact_agent_value(
                    child,
                    agent_string_field_is_structural(field),
                    depth + 1,
                    budget,
                ) {
                    complete = false;
                    break;
                }
            }
        }
        Value::Array(values) => {
            for child in values.iter_mut() {
                if !redact_agent_value(child, false, depth + 1, budget) {
                    complete = false;
                    break;
                }
            }
        }
        Value::String(_) if !preserve_strings => {
            *value = Value::String(REDACTED_AGENT_VALUE.into());
        }
        _ => {}
    }

    if !complete {
        *value = structure_limit_value();
    }
    complete
}

fn structure_limit_value() -> Value {
    json!({"redacted":true,"reason":STRUCTURE_LIMIT_REASON})
}

fn agent_string_field_is_structural(field: &str) -> bool {
    let field = semantic_key(field);
    field == "id"
        || field.ends_with("id")
        || [
            "cwd",
            "directory",
            "worktree",
            "path",
            "name",
            "type",
            "state",
            "status",
            "relation",
            "source",
            "provider",
            "kind",
            "role",
        ]
        .iter()
        .copied()
        .any(|marker| field == marker || field.ends_with(marker))
}

fn agent_field_is_sensitive(field: &str) -> bool {
    let field = semantic_key(field);
    field == "key"
        || field == "auth"
        || [
            "password",
            "passwd",
            "passphrase",
            "secret",
            "token",
            "credential",
            "authorization",
            "cookie",
            "privatekey",
            "apikey",
            "accesskey",
            "input",
            "prompt",
            "stdin",
            "paste",
        ]
        .iter()
        .copied()
        .any(|marker| field.contains(marker))
}

pub(crate) fn built_in_agent_producer_manifest() -> JournalProducerManifest {
    let payload_schema = json!({
        "type":"object",
        "required":["format","adapter","native_event","normalized","native"],
        "properties":{
            "format":{"const":AGENT_HOOK_FORMAT},
            "adapter":{
                "type":"object",
                "required":["id","version"],
                "properties":{
                    "id":{
                        "type":"string",
                        "minLength":1,
                        "maxLength":MAX_AGENT_SOURCE_BYTES,
                        "pattern":"^[a-z0-9_-]+$"
                    },
                    "version":{"const":1}
                },
                "additionalProperties":false
            },
            "native_event":{"type":"string","minLength":1,"maxLength":MAX_NATIVE_EVENT_BYTES},
            "normalized":{"type":"object"},
            "native":{}
        },
        "additionalProperties":false
    });
    JournalProducerManifest {
        producer_id: AGENT_HOOK_PRODUCER_ID.into(),
        namespace: "agent".into(),
        manifest_version: AGENT_HOOK_MANIFEST_VERSION,
        max_sensitivity: JournalSensitivity::Sensitive,
        permissions: vec!["journal.append.agent".into()],
        events: AGENT_EVENT_KINDS
            .into_iter()
            .map(|kind| JournalEventSchema {
                kind: kind.into(),
                schema_version: 1,
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                sensitivity: JournalSensitivity::Sensitive,
                payload_schema: payload_schema.clone(),
            })
            .collect(),
    }
}

fn validate_agent_source(source: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !source.is_empty()
            && source.len() <= MAX_AGENT_SOURCE_BYTES
            && source.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
            }),
        "agent source must contain 1 to {MAX_AGENT_SOURCE_BYTES} lowercase ASCII letters, digits, hyphens, or underscores"
    );
    Ok(())
}

fn validate_native_event(native_event: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !native_event.trim().is_empty()
            && native_event.len() <= MAX_NATIVE_EVENT_BYTES
            && !native_event.chars().any(char::is_control),
        "native agent event must contain 1 to {MAX_NATIVE_EVENT_BYTES} non-control UTF-8 bytes"
    );
    Ok(())
}

fn semantic_kind(
    source: &str,
    native_event: &str,
    normalized: &Map<String, Value>,
) -> &'static str {
    let event = semantic_key(native_event);
    let tool =
        normalized.get("tool_name").and_then(Value::as_str).map(semantic_key).unwrap_or_default();
    if tool == "askuserquestion" {
        return "agent.question.requested";
    }
    if tool == "exitplanmode" {
        return "agent.plan_review.requested";
    }
    if event == "questionasked" {
        return "agent.question.requested";
    }
    match (source, event.as_str()) {
        // These providers use their session-end callback as a per-turn
        // boundary and expose a distinct finalization event where available.
        ("antigravity" | "hermes-agent", "sessionend" | "onsessionend") => "agent.turn.completed",
        ("opencode", "sessioncreated") => "agent.session.started",
        ("opencode", "sessionidle") => "agent.turn.completed",
        ("opencode", "sessiondeleted") => "agent.session.ended",
        (_, event) if is_child_spawn(event) => "agent.child.spawned",
        (_, event) if is_child_completion(event) => "agent.child.completed",
        (_, "subagentfailed" | "childfailed") => "agent.child.failed",
        // These Claude-compatible runtimes use Notification as their only
        // reliable completed-turn callback.
        ("copilot" | "codebuddy" | "factory", "notification") => "agent.turn.completed",
        (_, "sessionstart" | "onsessionstart" | "onsessionreset") => "agent.session.started",
        (
            _,
            "userpromptsubmit" | "beforesubmitprompt" | "beforeagent" | "prellmcall"
            | "preinvocation" | "agentstart" | "turnstart" | "beforeagentstart",
        ) => "agent.turn.started",
        (
            _,
            "stop" | "afteragent" | "afteragentresponse" | "postllmcall" | "oncomplete"
            | "turncompletion" | "agentend" | "taskcompleted" | "turnend" | "agentsettled",
        ) => "agent.turn.completed",
        (
            _,
            "permissionrequest" | "permissionasked" | "preapprovalrequest" | "ontoolpermission",
        ) => "agent.approval.requested",
        (_, "stopfailure" | "onerror" | "error" | "posttoolusefailure") => "agent.error.reported",
        (_, "sessionend" | "onsessionend" | "onsessionfinalize" | "sessionshutdown") => {
            "agent.session.ended"
        }
        _ => "agent.state.changed",
    }
}

fn is_child_spawn(event: &str) -> bool {
    matches!(
        event,
        "subagentstart"
            | "subagentstarted"
            | "subagentspawned"
            | "agentspawn"
            | "agentspawned"
            | "childstart"
            | "childstarted"
            | "childspawned"
    )
}

fn is_child_completion(event: &str) -> bool {
    matches!(
        event,
        "subagentstop"
            | "subagentended"
            | "subagentcompleted"
            | "childstop"
            | "childended"
            | "childcompleted"
    )
}

fn normalized_fields(native: &Value) -> Map<String, Value> {
    let mut normalized = Map::new();
    for (field, paths) in [
        (
            "agent_session_id",
            &[
                &["session_id"][..],
                &["sessionId"][..],
                &["sessionID"][..],
                &["conversation_id"][..],
                &["thread_id"][..],
                &["session", "id"][..],
                &["properties", "sessionID"][..],
                &["properties", "sessionId"][..],
                &["properties", "info", "id"][..],
                &["event", "properties", "sessionID"][..],
                &["event", "properties", "sessionId"][..],
                &["event", "properties", "info", "id"][..],
                &["event", "properties", "info", "sessionID"][..],
                &["event", "properties", "info", "sessionId"][..],
                &["event", "session_id"][..],
                &["event", "sessionId"][..],
                &["event", "thread", "id"][..],
                &["context", "session_id"][..],
                &["context", "sessionId"][..],
                &["context", "thread", "id"][..],
            ][..],
        ),
        (
            "turn_id",
            &[
                &["turn_id"][..],
                &["turnId"][..],
                &["message_id"][..],
                &["messageId"][..],
                &["tool_use_id"][..],
                &["event", "turn_id"][..],
                &["event", "turnId"][..],
                &["event", "message_id"][..],
                &["event", "messageId"][..],
                &["context", "turn_id"][..],
                &["context", "turnId"][..],
            ][..],
        ),
        (
            "tool_use_id",
            &[
                &["tool_use_id"][..],
                &["toolUseId"][..],
                &["call_id"][..],
                &["callId"][..],
                &["event", "tool_use_id"][..],
                &["event", "toolUseId"][..],
                &["event", "call_id"][..],
                &["event", "callId"][..],
            ][..],
        ),
        (
            "cwd",
            &[
                &["cwd"][..],
                &["directory"][..],
                &["workspace", "root"][..],
                &["properties", "cwd"][..],
                &["properties", "info", "directory"][..],
                &["event", "properties", "cwd"][..],
                &["event", "properties", "directory"][..],
                &["event", "properties", "info", "directory"][..],
                &["event", "cwd"][..],
                &["event", "directory"][..],
                &["context", "cwd"][..],
                &["context", "directory"][..],
            ][..],
        ),
        (
            "transcript_path",
            &[
                &["transcript_path"][..],
                &["transcriptPath"][..],
                &["transcript", "path"][..],
                &["event", "transcript_path"][..],
                &["event", "transcriptPath"][..],
                &["context", "transcript_path"][..],
                &["context", "transcriptPath"][..],
            ][..],
        ),
        (
            "tool_name",
            &[
                &["tool_name"][..],
                &["toolName"][..],
                &["tool", "name"][..],
                &["properties", "tool"][..],
                &["properties", "tool_name"][..],
                &["event", "properties", "tool", "name"][..],
                &["event", "properties", "tool_name"][..],
                &["event", "tool_name"][..],
                &["event", "toolName"][..],
                &["event", "tool", "name"][..],
                &["context", "tool_name"][..],
                &["context", "toolName"][..],
            ][..],
        ),
        (
            "message",
            &[
                &["message"][..],
                &["last_assistant_message"][..],
                &["response"][..],
                &["summary"][..],
                &["properties", "message"][..],
                &["event", "properties", "message"][..],
                &["event", "properties", "info", "message"][..],
                &["event", "message"][..],
                &["event", "last_assistant_message"][..],
                &["event", "response"][..],
                &["event", "summary"][..],
                &["context", "message"][..],
            ][..],
        ),
        (
            "native_agent_id",
            &[
                &["agent_id"][..],
                &["agentId"][..],
                &["agent", "id"][..],
                &["event", "agent_id"][..],
                &["event", "agentId"][..],
                &["event", "agent", "id"][..],
                &["context", "agent_id"][..],
                &["context", "agentId"][..],
            ][..],
        ),
        (
            "native_child_agent_id",
            &[
                &["child_agent_id"][..],
                &["childAgentId"][..],
                &["subagent_id"][..],
                &["subagentId"][..],
                &["child", "agent_id"][..],
                &["child", "agentId"][..],
                &["child", "id"][..],
                &["event", "child_agent_id"][..],
                &["event", "childAgentId"][..],
                &["event", "subagent_id"][..],
                &["event", "subagentId"][..],
                &["event", "child", "agent_id"][..],
                &["event", "child", "agentId"][..],
                &["event", "child", "id"][..],
                &["context", "child_agent_id"][..],
                &["context", "childAgentId"][..],
            ][..],
        ),
        (
            "native_parent_agent_id",
            &[
                &["parent_agent_id"][..],
                &["parentAgentId"][..],
                &["parent", "agent_id"][..],
                &["parent", "agentId"][..],
                &["parent", "id"][..],
                &["event", "parent_agent_id"][..],
                &["event", "parentAgentId"][..],
                &["event", "parent", "agent_id"][..],
                &["event", "parent", "agentId"][..],
                &["event", "parent", "id"][..],
                &["context", "parent_agent_id"][..],
                &["context", "parentAgentId"][..],
            ][..],
        ),
        (
            "native_root_agent_id",
            &[
                &["root_agent_id"][..],
                &["rootAgentId"][..],
                &["root", "agent_id"][..],
                &["root", "agentId"][..],
                &["root", "id"][..],
                &["event", "root_agent_id"][..],
                &["event", "rootAgentId"][..],
                &["event", "root", "agent_id"][..],
                &["event", "root", "agentId"][..],
                &["event", "root", "id"][..],
                &["context", "root_agent_id"][..],
                &["context", "rootAgentId"][..],
            ][..],
        ),
        (
            "root_agent_session_id",
            &[
                &["root_session_id"][..],
                &["rootSessionId"][..],
                &["root_thread_id"][..],
                &["rootThreadId"][..],
                &["rootThreadID"][..],
                &["event", "root_session_id"][..],
                &["event", "rootSessionId"][..],
                &["event", "root_thread_id"][..],
                &["event", "rootThreadId"][..],
                &["context", "root_session_id"][..],
                &["context", "rootSessionId"][..],
                &["context", "rootSessionID"][..],
                &["context", "thread", "root_session_id"][..],
                &["context", "thread", "rootSessionId"][..],
            ][..],
        ),
        (
            "parent_agent_session_id",
            &[
                &["parent_session_id"][..],
                &["parentSessionId"][..],
                &["parent_thread_id"][..],
                &["parentThreadId"][..],
                &["parentThreadID"][..],
                &["parent_id"][..],
                &["parentId"][..],
                &["parentID"][..],
                &["properties", "parentID"][..],
                &["properties", "parentId"][..],
                &["properties", "info", "parentID"][..],
                &["properties", "info", "parentId"][..],
                &["event", "properties", "parentID"][..],
                &["event", "properties", "parentId"][..],
                &["event", "properties", "info", "parentID"][..],
                &["event", "properties", "info", "parentId"][..],
                &["event", "parent_session_id"][..],
                &["event", "parentSessionId"][..],
                &["event", "parent_thread_id"][..],
                &["event", "parentThreadId"][..],
                &["context", "parent_session_id"][..],
                &["context", "parentSessionId"][..],
                &["context", "parentSessionID"][..],
                &["context", "thread", "parent_session_id"][..],
                &["context", "thread", "parentSessionId"][..],
            ][..],
        ),
        (
            "agent_name",
            &[
                &["agent_name"][..],
                &["agentName"][..],
                &["agent_display_name"][..],
                &["agentDisplayName"][..],
                &["event", "agent_name"][..],
                &["event", "agentName"][..],
                &["event", "agent_display_name"][..],
                &["event", "agentDisplayName"][..],
            ][..],
        ),
        (
            "agent_type",
            &[
                &["agent_type"][..],
                &["agentType"][..],
                &["event", "agent_type"][..],
                &["event", "agentType"][..],
                &["context", "agent_type"][..],
                &["context", "agentType"][..],
            ][..],
        ),
    ] {
        if let Some(value) = first_string_at(native, paths) {
            normalized
                .insert(field.into(), Value::String(truncate_utf8(value, NORMALIZED_TEXT_BYTES)));
        }
    }
    if let Some(depth) = first_value_at(
        native,
        &[
            &["agent_depth"][..],
            &["agentDepth"][..],
            &["depth"][..],
            &["event", "agent_depth"][..],
            &["event", "agentDepth"][..],
            &["event", "depth"][..],
            &["context", "agent_depth"][..],
            &["context", "agentDepth"][..],
        ],
    ) && let Some(depth) = depth.as_u64().or_else(|| depth.as_str()?.parse().ok())
    {
        normalized.insert("agent_depth".into(), Value::from(depth));
    }
    normalized
}

fn add_agent_topology(
    source: &str,
    native_event: &str,
    terminal_id: Option<&TerminalPublicId>,
    normalized: &mut Map<String, Value>,
) {
    let scope = [
        ("root_agent_session_id", "session"),
        // A session scopes the whole agent tree while provider agent IDs
        // identify nodes inside it. Keeping that distinction stable also
        // lets later child events reveal an explicit root-session alias.
        ("agent_session_id", "session"),
        ("native_root_agent_id", "agent"),
        ("parent_agent_session_id", "session"),
        ("transcript_path", "transcript"),
    ]
    .into_iter()
    .find_map(|(field, identity_kind)| {
        normalized
            .get(field)
            .and_then(Value::as_str)
            .map(|identity| (identity_kind, identity.to_string()))
    })
    .or_else(|| terminal_id.map(|terminal| ("terminal", terminal.as_str().to_string())));
    let Some((scope_kind, scope_identity)) = scope else {
        return;
    };
    let tree_id = stable_topology_id("agenttree", &[source, scope_kind, &scope_identity]);
    normalized.insert("agent_tree_id".into(), Value::String(tree_id.clone()));
    let root_node_id = stable_agent_node_id(&tree_id, scope_kind, &scope_identity);

    let event = semantic_key(native_event);
    let child_event = is_child_spawn(&event)
        || is_child_completion(&event)
        || matches!(event.as_str(), "subagentfailed" | "childfailed");
    let native_agent_id =
        normalized.get("native_agent_id").and_then(Value::as_str).map(str::to_owned);
    let native_root_agent_id =
        normalized.get("native_root_agent_id").and_then(Value::as_str).map(str::to_owned);
    let session_id = normalized.get("agent_session_id").and_then(Value::as_str).map(str::to_owned);
    let parent_session_id =
        normalized.get("parent_agent_session_id").and_then(Value::as_str).map(str::to_owned);
    let node_identity = if child_event {
        normalized
            .get("native_child_agent_id")
            .and_then(Value::as_str)
            .or(native_agent_id.as_deref())
            .map(|identity| ("agent", identity, "native"))
    } else {
        session_id
            .as_deref()
            .map(|identity| ("session", identity, "session"))
            .or_else(|| native_agent_id.as_deref().map(|identity| ("agent", identity, "native")))
            .or_else(|| {
                native_root_agent_id.as_deref().map(|identity| ("agent", identity, "native_root"))
            })
    };
    let fallback_agent_name =
        child_event.then(|| normalized.get("agent_name").and_then(Value::as_str)).flatten();
    let (node_id, identity_quality) = match node_identity {
        Some((identity_kind, identity, quality)) => {
            let is_root = (identity_kind == scope_kind && identity == scope_identity.as_str())
                || (identity_kind == "agent"
                    && native_root_agent_id.as_deref() == Some(identity)
                    && parent_session_id.is_none());
            let node_id = if is_root {
                root_node_id.clone()
            } else {
                stable_agent_node_id(&tree_id, identity_kind, identity)
            };
            (node_id, quality.to_string())
        }
        None if !child_event => (root_node_id.clone(), "session_root".into()),
        None if fallback_agent_name.is_some() => {
            let name = fallback_agent_name.expect("presence checked");
            let turn = normalized.get("turn_id").and_then(Value::as_str).unwrap_or("");
            let tool = normalized.get("tool_use_id").and_then(Value::as_str).unwrap_or("");
            if turn.is_empty() && tool.is_empty() {
                normalized.insert("agent_relation".into(), Value::String("unknown".into()));
                return;
            }
            let identity = format!("name:{name}\0turn:{turn}\0tool:{tool}");
            (stable_agent_node_id(&tree_id, "name_fallback", &identity), "name_fallback".into())
        }
        None => {
            normalized.insert("agent_relation".into(), Value::String("unknown".into()));
            return;
        }
    };
    normalized.insert("agent_node_id".into(), Value::String(node_id));
    normalized.insert("agent_identity_quality".into(), Value::String(identity_quality));

    if let Some(parent) = parent_session_id.as_deref() {
        let parent_id = if scope_kind == "session" && parent == scope_identity.as_str() {
            root_node_id
        } else {
            stable_agent_node_id(&tree_id, "session", parent)
        };
        normalized.insert("parent_agent_node_id".into(), Value::String(parent_id));
        normalized.insert("agent_relation".into(), Value::String("explicit".into()));
    } else if let Some(parent) = normalized.get("native_parent_agent_id").and_then(Value::as_str) {
        let parent_id = if native_root_agent_id.as_deref() == Some(parent) {
            root_node_id
        } else {
            stable_agent_node_id(&tree_id, "agent", parent)
        };
        normalized.insert("parent_agent_node_id".into(), Value::String(parent_id));
        normalized.insert("agent_relation".into(), Value::String("explicit".into()));
    } else if matches!(source, "claude" | "claude-code") && child_event {
        // Claude Code's command-hook contract exposes a stable child ID but
        // no parent ID, and its subagents cannot spawn subagents. The parent
        // is therefore the root of the shared session tree.
        normalized.insert("parent_agent_node_id".into(), Value::String(root_node_id));
        normalized.insert("agent_relation".into(), Value::String("provider_root".into()));
    } else if child_event
        || normalized.get("agent_node_id").and_then(Value::as_str) != Some(root_node_id.as_str())
    {
        normalized.insert("agent_relation".into(), Value::String("unknown".into()));
    } else {
        normalized.insert("agent_relation".into(), Value::String("root".into()));
    }
}

fn stable_agent_node_id(tree_id: &str, identity_kind: &str, identity: &str) -> String {
    stable_topology_id("agentnode", &[tree_id, identity_kind, identity])
}

fn stable_topology_id(prefix: &str, components: &[&str]) -> String {
    let mut digest = Sha256::new();
    for component in components {
        digest.update((component.len() as u64).to_be_bytes());
        digest.update(component.as_bytes());
    }
    let digest = digest.finalize();
    let mut id = String::with_capacity(prefix.len() + 1 + 32);
    id.push_str(prefix);
    id.push('_');
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in digest[..16].iter().copied() {
        id.push(char::from(HEX[usize::from(byte >> 4)]));
        id.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    id
}

fn first_string_at<'a>(native: &'a Value, paths: &[&[&str]]) -> Option<&'a str> {
    paths.iter().find_map(|path| {
        path.iter()
            .try_fold(native, |value, component| value.get(*component))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    })
}

fn first_value_at<'a>(native: &'a Value, paths: &[&[&str]]) -> Option<&'a Value> {
    paths
        .iter()
        .find_map(|path| path.iter().try_fold(native, |value, component| value.get(*component)))
}

fn truncate_utf8(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.into();
    }
    let mut boundary = max_bytes;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value[..boundary].into()
}

fn semantic_key(value: &str) -> String {
    value
        .bytes()
        .filter(|byte| byte.is_ascii_alphanumeric())
        .map(|byte| byte.to_ascii_lowercase() as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_hooks_share_one_semantic_kind_and_keep_native_payload() {
        for (source, event) in [
            ("codex", "Stop"),
            ("claude", "Stop"),
            ("gemini", "AfterAgent"),
            ("cursor", "afterAgentResponse"),
            ("hermes-agent", "post_llm_call"),
            ("rovodev", "on_complete"),
        ] {
            let native = json!({"session_id":"native-1","message":"done","opaque":{"v":42}});
            let ingress = agent_hook_journal_ingress(source, event, None, native.clone()).unwrap();
            assert_eq!(ingress.kind, "agent.turn.completed");
            assert_eq!(ingress.payload["native"]["session_id"], native["session_id"]);
            assert_eq!(ingress.payload["native"]["message"], REDACTED_AGENT_VALUE);
            assert_eq!(ingress.payload["native"]["opaque"]["v"], 42);
            assert_eq!(ingress.payload["normalized"]["agent_session_id"], "native-1");
            assert_eq!(ingress.payload["adapter"]["id"], source);
            assert_eq!(ingress.sensitivity, Some(JournalSensitivity::Sensitive));
        }
    }

    #[test]
    fn raw_input_and_credentials_are_redacted_before_ingress() {
        let ingress = agent_hook_journal_ingress(
            "pi",
            "input",
            None,
            json!({
                "input":"do not persist this prompt",
                "context":{"session_id":"do not persist this token"}
            }),
        )
        .unwrap();
        assert_eq!(ingress.payload["native"]["redacted"], true);
        let encoded = serde_json::to_string(&ingress.payload).unwrap();
        assert!(!encoded.contains("do not persist this prompt"));
        assert!(!encoded.contains("do not persist this token"));

        let credential = agent_hook_journal_ingress(
            "codex",
            "Stop",
            None,
            json!({
                "session_id":"safe-session",
                "api_token":"do not persist this credential",
                "nested":{"tool_input":"do not persist this tool input","opaque":42}
            }),
        )
        .unwrap();
        assert_eq!(credential.payload["normalized"]["agent_session_id"], "safe-session");
        assert_eq!(credential.payload["native"]["nested"]["opaque"], 42);
        let encoded = serde_json::to_string(&credential.payload).unwrap();
        assert!(!encoded.contains("do not persist this credential"));
        assert!(!encoded.contains("do not persist this tool input"));
        assert!(encoded.contains(REDACTED_AGENT_VALUE));
    }

    #[test]
    fn hostile_agent_structure_is_bounded_during_redaction() {
        let mut deeply_nested = json!("secret-leaf");
        for _ in 0..64 {
            deeply_nested = json!({"nested": deeply_nested});
        }
        let wide = (0..8_192).map(|_| json!({"value":"secret"})).collect::<Vec<_>>();
        let ingress = agent_hook_journal_ingress(
            "codex",
            "Stop",
            None,
            json!({"deep": deeply_nested, "wide": wide}),
        )
        .unwrap();
        let encoded = serde_json::to_string(&ingress.payload).unwrap();
        assert!(encoded.contains("\"reason\":\"structure_limit\""));
        assert!(!encoded.contains("secret-leaf"));
    }

    #[test]
    fn dedicated_question_and_plan_tools_are_semantic_events() {
        let question = agent_hook_journal_ingress(
            "claude-code",
            "PermissionRequest",
            None,
            json!({"tool_name":"AskUserQuestion"}),
        )
        .unwrap();
        let plan = agent_hook_journal_ingress(
            "claude-code",
            "PermissionRequest",
            None,
            json!({"tool_name":"ExitPlanMode"}),
        )
        .unwrap();
        assert_eq!(question.kind, "agent.question.requested");
        assert_eq!(plan.kind, "agent.plan_review.requested");
    }

    #[test]
    fn provider_specific_turn_boundaries_do_not_end_restorable_sessions() {
        for (source, event) in [
            ("antigravity", "SessionEnd"),
            ("hermes-agent", "on_session_end"),
            ("copilot", "Notification"),
            ("codebuddy", "Notification"),
            ("factory", "Notification"),
        ] {
            let ingress = agent_hook_journal_ingress(source, event, None, json!({})).unwrap();
            assert_eq!(ingress.kind, "agent.turn.completed", "{source}:{event}");
        }
        let finalized =
            agent_hook_journal_ingress("hermes-agent", "on_session_finalize", None, json!({}))
                .unwrap();
        assert_eq!(finalized.kind, "agent.session.ended");
        let grok = agent_hook_journal_ingress("grok", "SessionEnd", None, json!({})).unwrap();
        assert_eq!(grok.kind, "agent.session.ended");
    }

    #[test]
    fn provider_envelopes_normalize_structural_fields_and_redact_message_data() {
        let native = json!({
            "event": {
                "thread": {"id":"amp-thread-1"},
                "turnId":"turn-7",
                "tool":{"name":"Bash"},
                "last_assistant_message":"done"
            },
            "context":{"cwd":"/tmp/project"},
            "provider_only":{"opaque":42}
        });
        let ingress = agent_hook_journal_ingress("amp", "Stop", None, native.clone()).unwrap();
        assert_eq!(ingress.kind, "agent.turn.completed");
        assert_eq!(ingress.payload["native"]["provider_only"], native["provider_only"]);
        assert_eq!(ingress.payload["normalized"]["agent_session_id"], "amp-thread-1");
        assert_eq!(ingress.payload["normalized"]["turn_id"], "turn-7");
        assert_eq!(ingress.payload["normalized"]["cwd"], "/tmp/project");
        assert_eq!(ingress.payload["normalized"]["tool_name"], "Bash");
        assert_eq!(ingress.payload["normalized"]["message"], REDACTED_AGENT_VALUE);
    }

    #[test]
    fn opencode_idle_is_a_completed_turn_not_a_session_end() {
        let idle = agent_hook_journal_ingress("opencode", "session.idle", None, json!({})).unwrap();
        assert_eq!(idle.kind, "agent.turn.completed");
        let deleted =
            agent_hook_journal_ingress("opencode", "session.deleted", None, json!({})).unwrap();
        assert_eq!(deleted.kind, "agent.session.ended");
    }

    #[test]
    fn wrapped_opencode_events_keep_native_shape_and_normalize_properties() {
        let native = json!({
            "event": {
                "type":"session.created",
                "properties": {
                    "info": {
                        "id":"opencode-session",
                        "directory":"/tmp/opencode"
                    }
                }
            },
            "context": {"worktree":"/tmp/opencode"}
        });
        let ingress =
            agent_hook_journal_ingress("opencode", "session.created", None, native.clone())
                .unwrap();
        assert_eq!(ingress.payload["native"], native);
        assert_eq!(ingress.payload["normalized"]["agent_session_id"], "opencode-session");
        assert_eq!(ingress.payload["normalized"]["cwd"], "/tmp/opencode");
        assert_eq!(ingress.kind, "agent.session.started");

        let approval = agent_hook_journal_ingress(
            "opencode",
            "permission.asked",
            None,
            json!({"event":{"properties":{"sessionID":"opencode-session"}}}),
        )
        .unwrap();
        assert_eq!(approval.kind, "agent.approval.requested");
        let question = agent_hook_journal_ingress(
            "opencode",
            "question.asked",
            None,
            json!({"event":{"properties":{"sessionID":"opencode-session"}}}),
        )
        .unwrap();
        assert_eq!(question.kind, "agent.question.requested");
    }

    #[test]
    fn nested_agent_edges_are_stable_and_indexable_without_payload_scans() {
        let root = agent_hook_journal_ingress(
            "codex",
            "SessionStart",
            None,
            json!({
                "session_id":"tree-session",
                "root_session_id":"tree-session",
                "agent_id":"root-agent",
                "root_agent_id":"root-agent"
            }),
        )
        .unwrap();
        let parent = agent_hook_journal_ingress(
            "codex",
            "SubagentStart",
            None,
            json!({
                "session_id":"tree-session",
                "root_session_id":"tree-session",
                "agent_id":"child-a",
                "parent_agent_id":"root-agent",
                "root_agent_id":"root-agent",
                "agent_depth":1
            }),
        )
        .unwrap();
        let child = agent_hook_journal_ingress(
            "codex",
            "SubagentStart",
            None,
            json!({
                "session_id":"tree-session",
                "root_session_id":"tree-session",
                "agent_id":"emitting-parent",
                "child_agent_id":"child-b",
                "parent_agent_id":"child-a",
                "root_agent_id":"root-agent",
                "agent_depth":2
            }),
        )
        .unwrap();
        let completed = agent_hook_journal_ingress(
            "codex",
            "subagent.completed",
            None,
            json!({
                "session_id":"tree-session",
                "root_session_id":"tree-session",
                "agent_id":"emitting-parent",
                "child_agent_id":"child-b",
                "parent_agent_id":"child-a",
                "root_agent_id":"root-agent"
            }),
        )
        .unwrap();

        assert_eq!(parent.kind, "agent.child.spawned");
        assert_eq!(child.kind, "agent.child.spawned");
        assert_eq!(completed.kind, "agent.child.completed");
        assert_eq!(child.payload["normalized"]["agent_depth"], 2);
        assert_eq!(child.payload["normalized"]["native_agent_id"], "emitting-parent");
        assert_eq!(child.payload["normalized"]["native_child_agent_id"], "child-b");
        assert_eq!(child.payload["normalized"]["agent_relation"], "explicit");
        assert_eq!(root.payload["normalized"]["agent_relation"], "root");
        assert_eq!(
            parent.payload["normalized"]["parent_agent_node_id"],
            root.payload["normalized"]["agent_node_id"]
        );
        assert_eq!(
            child.payload["normalized"]["parent_agent_node_id"],
            parent.payload["normalized"]["agent_node_id"]
        );
        assert_eq!(
            completed.payload["normalized"]["agent_node_id"],
            child.payload["normalized"]["agent_node_id"]
        );
        assert_eq!(
            child.payload["normalized"]["agent_tree_id"],
            parent.payload["normalized"]["agent_tree_id"]
        );
        for (field, subject_kind) in [
            ("agent_tree_id", "agent_tree"),
            ("agent_node_id", "agent_node"),
            ("parent_agent_node_id", "agent_parent"),
        ] {
            let id = child.payload["normalized"][field].as_str().unwrap();
            assert!(
                child
                    .subjects
                    .iter()
                    .any(|subject| subject.kind == subject_kind && subject.id == id)
            );
        }
    }

    #[test]
    fn progressive_root_identity_keeps_parent_and_child_in_one_tree() {
        let root = agent_hook_journal_ingress(
            "codex",
            "SessionStart",
            None,
            json!({
                "session_id":"tree-session",
                "agent_id":"root-agent",
                "root_agent_id":"root-agent"
            }),
        )
        .unwrap();
        let child = agent_hook_journal_ingress(
            "codex",
            "SubagentStart",
            None,
            json!({
                "session_id":"tree-session",
                "root_session_id":"tree-session",
                "agent_id":"child-agent",
                "parent_agent_id":"root-agent",
                "root_agent_id":"root-agent"
            }),
        )
        .unwrap();

        assert_eq!(
            child.payload["normalized"]["agent_tree_id"],
            root.payload["normalized"]["agent_tree_id"]
        );
        assert_eq!(
            child.payload["normalized"]["parent_agent_node_id"],
            root.payload["normalized"]["agent_node_id"]
        );
    }

    #[test]
    fn nested_agent_sessions_form_one_tree_without_provider_agent_ids() {
        let root = agent_hook_journal_ingress(
            "codex",
            "SessionStart",
            None,
            json!({"session_id":"root-session","root_session_id":"root-session"}),
        )
        .unwrap();
        let child = agent_hook_journal_ingress(
            "codex",
            "SessionStart",
            None,
            json!({
                "session_id":"child-session",
                "parent_session_id":"root-session",
                "root_session_id":"root-session"
            }),
        )
        .unwrap();
        let grandchild = agent_hook_journal_ingress(
            "codex",
            "SessionStart",
            None,
            json!({
                "session_id":"grandchild-session",
                "parent_session_id":"child-session",
                "root_session_id":"root-session"
            }),
        )
        .unwrap();

        assert_eq!(child.payload["normalized"]["agent_relation"], "explicit");
        assert_eq!(grandchild.payload["normalized"]["agent_relation"], "explicit");
        assert_eq!(
            child.payload["normalized"]["parent_agent_node_id"],
            root.payload["normalized"]["agent_node_id"]
        );
        assert_eq!(
            grandchild.payload["normalized"]["parent_agent_node_id"],
            child.payload["normalized"]["agent_node_id"]
        );
        assert_ne!(
            child.payload["normalized"]["agent_node_id"],
            root.payload["normalized"]["agent_node_id"]
        );
        assert_ne!(
            grandchild.payload["normalized"]["agent_node_id"],
            child.payload["normalized"]["agent_node_id"]
        );
        assert_eq!(
            grandchild.payload["normalized"]["agent_tree_id"],
            root.payload["normalized"]["agent_tree_id"]
        );
    }

    #[test]
    fn claude_direct_children_attach_to_the_shared_session_root() {
        for source in ["claude", "claude-code"] {
            let root = agent_hook_journal_ingress(
                source,
                "SessionStart",
                None,
                json!({"session_id":"claude-session"}),
            )
            .unwrap();
            let child = agent_hook_journal_ingress(
                source,
                "SubagentStart",
                None,
                json!({"session_id":"claude-session","agent_id":"child-a"}),
            )
            .unwrap();

            assert_eq!(child.payload["normalized"]["agent_relation"], "provider_root", "{source}");
            assert_eq!(
                child.payload["normalized"]["parent_agent_node_id"],
                root.payload["normalized"]["agent_node_id"],
                "{source}"
            );
            assert_eq!(
                child.payload["normalized"]["agent_tree_id"],
                root.payload["normalized"]["agent_tree_id"],
                "{source}"
            );
        }
    }

    #[test]
    fn absent_parent_metadata_stays_an_orphan_instead_of_inventing_an_edge() {
        let child = agent_hook_journal_ingress(
            "codex",
            "SubagentStart",
            None,
            json!({"session_id":"child-session","agent_id":"child-a"}),
        )
        .unwrap();
        assert_eq!(child.payload["normalized"]["agent_relation"], "unknown");
        assert!(child.payload["normalized"].get("parent_agent_node_id").is_none());
        assert!(!child.subjects.iter().any(|subject| subject.kind == "agent_parent"));

        let ambiguous = agent_hook_journal_ingress(
            "copilot",
            "subagentStart",
            None,
            json!({"sessionId":"copilot-session","agentName":"Explore"}),
        )
        .unwrap();
        assert_eq!(ambiguous.payload["normalized"]["agent_relation"], "unknown");
        assert!(ambiguous.payload["normalized"].get("agent_node_id").is_none());
        assert!(ambiguous.subjects.iter().any(|subject| subject.kind == "agent_tree"));
    }

    #[test]
    fn terminal_identity_is_a_subject_and_unknown_events_remain_lossless() {
        let terminal = "term_00000000000000000000000000000001";
        let native = json!({"future":true});
        let ingress = agent_hook_journal_ingress(
            "future-agent",
            "NewLifecycle",
            Some(terminal),
            native.clone(),
        )
        .unwrap();
        assert_eq!(ingress.kind, "agent.state.changed");
        assert_eq!(ingress.payload["native"], native);
        assert!(
            ingress
                .subjects
                .iter()
                .any(|subject| subject.kind == "terminal" && subject.id == terminal)
        );
        assert!(ingress.subjects.iter().any(|subject| subject.kind == "agent_tree"));
        assert!(ingress.subjects.iter().any(|subject| subject.kind == "agent_node"));
    }

    #[test]
    fn built_in_agent_ingress_is_immediately_appendable_and_idempotent() {
        let root = std::env::temp_dir().join(format!(
            "cmux-agent-hook-journal-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = crate::Mux::open_persistent(
            "agent-hook-journal",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let ingress = agent_hook_journal_ingress(
            "codex",
            "Stop",
            None,
            json!({
                "session_id":"native-session",
                "api_token":"persistent-secret-sentinel",
                "opaque":{"v":42,"prompt":"persistent-input-sentinel"}
            }),
        )
        .unwrap();
        let first = mux.append_journal_ingress(&ingress, "client_test", "agent_hook_once").unwrap();
        let replay =
            mux.append_journal_ingress(&ingress, "client_test", "agent_hook_once").unwrap();
        assert!(!first.replayed);
        assert!(replay.replayed);
        assert_eq!(first.event_id, replay.event_id);

        let record = mux
            .session_journal_after(first.sequence.saturating_sub(1), 1)
            .unwrap()
            .records
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(record.kind, "agent.turn.completed");
        assert_eq!(record.producer.kind, "agent_adapter");
        assert_eq!(record.producer.id, AGENT_HOOK_PRODUCER_ID);
        assert_eq!(record.authority.as_ref().unwrap().role, "agent.adapter");
        assert_eq!(record.payload["native"]["opaque"]["v"], 42);
        let encoded = serde_json::to_string(&record.payload).unwrap();
        assert!(!encoded.contains("persistent-secret-sentinel"));
        assert!(!encoded.contains("persistent-input-sentinel"));
        assert!(encoded.contains(REDACTED_AGENT_VALUE));
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_agent_ingress_returns_every_durable_receipt() {
        const AGENTS: usize = 32;
        let root = std::env::temp_dir().join(format!(
            "cmux-agent-hook-concurrent-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = crate::Mux::open_persistent(
            "agent-hook-concurrent",
            crate::SurfaceOptions::default(),
            &root,
        )
        .unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(AGENTS));
        let handles = (0..AGENTS)
            .map(|agent| {
                let mux = mux.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    let ingress = agent_hook_journal_ingress(
                        "codex",
                        "Stop",
                        None,
                        json!({"session_id":format!("agent-{agent}")}),
                    )
                    .unwrap();
                    barrier.wait();
                    mux.append_journal_ingress(
                        &ingress,
                        "client_test",
                        &format!("agent_concurrent_{agent}"),
                    )
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        let mut sequences =
            handles.into_iter().map(|handle| handle.join().unwrap().sequence).collect::<Vec<_>>();
        sequences.sort_unstable();
        sequences.dedup();
        assert_eq!(sequences.len(), AGENTS);
        let records = mux.session_journal_after(0, 1024).unwrap().records;
        assert_eq!(
            records.iter().filter(|record| record.kind == "agent.turn.completed").count(),
            AGENTS
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
