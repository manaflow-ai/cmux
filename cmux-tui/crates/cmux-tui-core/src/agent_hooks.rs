use serde_json::{Map, Value, json};

use crate::resource::TerminalPublicId;
use crate::{
    JournalClass, JournalEventSchema, JournalIngress, JournalProducerManifest, JournalReplayPolicy,
    JournalSensitivity, JournalSubject,
};

pub const AGENT_HOOK_PRODUCER_ID: &str = "cmux_agent";
pub const AGENT_HOOK_MANIFEST_VERSION: u32 = 1;
const AGENT_HOOK_FORMAT: &str = "cmux.agent-hook.v1";
const MAX_AGENT_SOURCE_BYTES: usize = 64;
const MAX_NATIVE_EVENT_BYTES: usize = 128;
const NORMALIZED_TEXT_BYTES: usize = 8 * 1024;

const AGENT_EVENT_KINDS: [&str; 9] = [
    "agent.session.started",
    "agent.turn.started",
    "agent.turn.completed",
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
    let normalized = normalized_fields(&native);
    let kind = semantic_kind(source, native_event, &normalized);
    let mut subjects = Vec::with_capacity(1);
    if let Some(terminal_id) = terminal_id {
        subjects.push(JournalSubject { kind: "terminal".into(), id: terminal_id.to_string() });
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
    match (source, event.as_str()) {
        // These providers use their session-end callback as a per-turn
        // boundary and expose a distinct finalization event where available.
        ("grok" | "antigravity" | "hermes-agent", "sessionend" | "onsessionend") => {
            "agent.turn.completed"
        }
        // These Claude-compatible runtimes use Notification as their only
        // reliable completed-turn callback.
        ("copilot" | "codebuddy" | "factory", "notification") => "agent.turn.completed",
        (_, "sessionstart" | "onsessionstart" | "onsessionreset" | "agentspawn") => {
            "agent.session.started"
        }
        (
            _,
            "userpromptsubmit" | "beforesubmitprompt" | "beforeagent" | "prellmcall"
            | "preinvocation" | "agentstart",
        ) => "agent.turn.started",
        (
            _,
            "stop" | "afteragent" | "afteragentresponse" | "postllmcall" | "oncomplete"
            | "turncompletion" | "agentend" | "taskcompleted",
        ) => "agent.turn.completed",
        (_, "permissionrequest" | "preapprovalrequest" | "ontoolpermission") => {
            "agent.approval.requested"
        }
        (_, "stopfailure" | "onerror" | "error" | "posttoolusefailure") => "agent.error.reported",
        (_, "sessionend" | "onsessionend" | "onsessionfinalize") => "agent.session.ended",
        _ => "agent.state.changed",
    }
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
            ][..],
        ),
        (
            "transcript_path",
            &[&["transcript_path"][..], &["transcriptPath"][..], &["transcript", "path"][..]][..],
        ),
        (
            "tool_name",
            &[
                &["tool_name"][..],
                &["toolName"][..],
                &["tool", "name"][..],
                &["properties", "tool"][..],
                &["properties", "tool_name"][..],
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
            ][..],
        ),
    ] {
        if let Some(value) = first_string_at(native, paths) {
            normalized
                .insert(field.into(), Value::String(truncate_utf8(value, NORMALIZED_TEXT_BYTES)));
        }
    }
    normalized
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
            assert_eq!(ingress.payload["native"], native);
            assert_eq!(ingress.payload["normalized"]["agent_session_id"], "native-1");
            assert_eq!(ingress.payload["adapter"]["id"], source);
            assert_eq!(ingress.sensitivity, Some(JournalSensitivity::Sensitive));
        }
    }

    #[test]
    fn dedicated_question_and_plan_tools_are_semantic_events() {
        let question = agent_hook_journal_ingress(
            "claude",
            "PermissionRequest",
            None,
            json!({"tool_name":"AskUserQuestion"}),
        )
        .unwrap();
        let plan = agent_hook_journal_ingress(
            "claude",
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
            ("grok", "SessionEnd"),
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
        assert_eq!(
            ingress.subjects,
            vec![JournalSubject { kind: "terminal".into(), id: terminal.into() }]
        );
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
            json!({"session_id":"native-session","opaque":{"v":42}}),
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
