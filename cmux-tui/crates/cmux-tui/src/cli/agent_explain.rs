//! `cmux agent explain <terminal|name>` (and `cmux agent <t> explain`): why
//! the daemon holds the agent's state (bench round 4, herdr `agent explain`).
//!
//! The daemon's roster fold records the reason as it decides
//! (journal_reducers_state_reason.rs): the journal record that set the state,
//! how the fold took it, the state before, and the screen's last observation.
//! This command reads that record (`list-agents` `state_reason`), the session
//! snapshot for the agent's name and its shown status (done-until-seen), and
//! the named journal records for the screen text and the hook's tool. It
//! classifies nothing itself.
//!
//! The screen text is read from the journal under its own rules: a local
//! client may read `sensitive` records; a record that left the journal says
//! so (`retained: false`).

use std::collections::HashMap;
use std::io::BufReader;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{PROTOCOL, ResourceOperation};
use serde_json::{Map, Value, json};

use super::resolve::{self, Failure};
use super::terminal_talk::{roster, roster_names, send};
use super::{GlobalArgs, OutputMode, UsageError, wire};

type Reader = BufReader<Box<dyn transport::Stream>>;

/// How long the daemon may take for each answer.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// The most journal records one explain scans for its two records.
const MAX_SCANNED_RECORDS: usize = 512;
/// The most screen text lines shown.
const MAX_TEXT_LINES: usize = 12;

/// `Some(exit code)` for `agent explain <t>` and `agent <t> explain`;
/// `None` for any other command (and for `--help`, which the scope help prints).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    if super::has_help_option(&words) {
        return None;
    }
    let target = match parse(&words)? {
        Ok(target) => target,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    Some(run(&global, &target))
}

/// The target of an explain command, `None` when `words` are another command.
pub(super) fn parse(words: &[String]) -> Option<Result<String, UsageError>> {
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let target = match words.as_slice() {
        [scope, "explain", rest @ ..] if super::canonical_scope(scope) == "agent" => rest,
        [scope, target, "explain", rest @ ..] if super::canonical_scope(scope) == "agent" => {
            if !rest.is_empty() {
                return Some(Err(UsageError::new(format!(
                    "agent {target} explain takes no other word, not {}",
                    rest.join(" ")
                ))));
            }
            return Some(Ok((*target).to_owned()));
        }
        _ => return None,
    };
    Some(match target {
        [target] if !target.starts_with('-') => Ok((*target).to_owned()),
        [] => Err(UsageError::new("agent explain needs a terminal, tab or agent name")),
        other => Err(UsageError::new(format!(
            "agent explain takes one terminal, tab or agent name, not {}",
            other.join(" ")
        ))),
    })
}

fn run(global: &GlobalArgs, target: &str) -> i32 {
    // The resolver prints its own typed failure.
    let socket = match wire::resolve_socket_or_report(global) {
        Ok(socket) => socket,
        Err(exit) => return exit,
    };
    match gather(global, &socket, target) {
        Ok(value) => {
            match global.output {
                OutputMode::Human => {
                    let messages = &crate::localization::catalog().agent_state;
                    println!("{}", human(&value, messages, super::terminal_talk::now_ms()));
                }
                OutputMode::Quiet => {}
                OutputMode::Json | OutputMode::JsonLines => {
                    println!("{}", serde_json::to_string(&value).unwrap_or_default());
                }
            }
            0
        }
        Err(failure) => failure.report(global.output),
    }
}

fn gather(
    global: &GlobalArgs,
    (socket, derived): &(PathBuf, bool),
    target: &str,
) -> Result<Value, Failure> {
    // The snapshot as `terminal list --agents` reads it (names, shown status).
    let backend = super::mcp::cli_backend(global.clone());
    let snapshot = send::snapshot(&backend, None)
        .map_err(|failure| Failure::Local { error: failure.error, exit: 1 })?;
    let terminal = send::find_terminal(&snapshot, target)
        .map_err(|failure| Failure::Local { error: failure.failure.error, exit: failure.exit })?
        .clone();
    let terminal_id = terminal["id"].as_str().unwrap_or_default().to_owned();
    let connect = || {
        cmux_tui_core::server::connect_session_socket(socket, *derived)
            .map(|stream| {
                let _ = stream.set_read_timeout(Some(ANSWER_TIMEOUT));
                BufReader::new(stream)
            })
            .map_err(|error| Failure::Local {
                error: json!({
                    "code": "socket.unreachable",
                    "message": wire::connect_failure(socket, &error),
                    "details": {"socket": socket.display().to_string()},
                    "retryable": false,
                }),
                exit: 3,
            })
    };
    let rows = legacy_agents(&mut connect()?).unwrap_or_default();
    let row = rows.into_iter().find(|row| row["terminal_id"] == terminal_id.as_str());
    let wanted = wanted_sequences(row.as_ref());
    let session_id = snapshot["session"]["id"].as_str().unwrap_or_default().to_owned();
    let records = if wanted.is_empty() || session_id.is_empty() {
        HashMap::new()
    } else {
        let mut plan = super::agents::snapshot_plan();
        resolve::apply_global_route(global, &mut plan)
            .map_err(|error| Failure::Transport(format!("cmux: {error}")))?;
        let route = plan.params.as_object().cloned().unwrap_or_default();
        journal_records(&mut connect()?, &route, &session_id, &terminal_id, &wanted)
    };
    explain_value(&snapshot, &terminal, row.as_ref(), &records, &wanted).ok_or_else(|| {
        Failure::Local {
            error: json!({
                "code": "agent.not_found",
                "message": format!("no agent runs in {terminal_id}"),
                "details": {"terminal": terminal_id, "target": target},
                "retryable": false,
            }),
            exit: 1,
        }
    })
}

/// The daemon's `list-agents` rows (the private control protocol): each
/// roster row with its shown `status` and `state_reason`.
fn legacy_agents(reader: &mut Reader) -> Option<Vec<Value>> {
    let id = "cmux-agent-explain";
    let request = json!({"id": id, "cmd": "list-agents"});
    resolve::send(reader, request.to_string().as_bytes()).ok()?;
    loop {
        let value = wire::read_envelope(reader, false).ok()??;
        if value.get("type").is_some() || value.get("event").is_some() || value["id"] != id {
            continue;
        }
        if value["ok"] != true {
            return None;
        }
        return value["data"]["agents"].as_array().cloned();
    }
}

fn number(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

/// The journal sequences of the cause and of the screen's last observation.
fn wanted_sequences(row: Option<&Value>) -> Vec<u64> {
    let Some(reason) = row.map(|row| &row["state_reason"]) else { return Vec::new() };
    let mut wanted: Vec<u64> = [&reason["cause"]["sequence"], &reason["screen"]["sequence"]]
        .into_iter()
        .filter_map(number)
        .collect();
    wanted.sort_unstable();
    wanted.dedup();
    wanted
}

/// The journal records `wanted` (sorted), read from one bounded
/// `session.journal.subscribe` scan of the terminal's agent records. Records
/// the journal no longer keeps are absent.
fn journal_records(
    reader: &mut Reader,
    route: &Map<String, Value>,
    session_id: &str,
    terminal_id: &str,
    wanted: &[u64],
) -> HashMap<u64, Value> {
    let mut found = HashMap::new();
    let (Some(&first), Some(&last)) = (wanted.first(), wanted.last()) else { return found };
    let deadline = Instant::now() + ANSWER_TIMEOUT;
    let _ = reader.get_mut().set_read_timeout(Some(ANSWER_TIMEOUT));
    let Ok(id) = wire::random_request_id() else { return found };
    let Ok(stream_id) = super::command::random_prefixed("stream") else { return found };
    let mut params = route.clone();
    params.insert("stream_id".into(), json!(stream_id));
    params.insert(
        "cursor".into(),
        json!({"generation": session_id, "revision": first.saturating_sub(1).to_string()}),
    );
    params.insert("follow".into(), json!(false));
    params.insert(
        "filter".into(),
        json!({
            "kinds": ["agent.*", "plugin.*"],
            "subjects": [{"kind": "terminal", "id": terminal_id}],
            "max_sensitivity": "sensitive",
        }),
    );
    let request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": ResourceOperation::SessionJournalSubscribe.wire_name(),
        "params": params,
    });
    if resolve::send(reader, request.to_string().as_bytes()).is_err() {
        return found;
    }
    if !matches!(resolve::read_response(reader, &id), Ok(Ok(_))) {
        return found;
    }
    let mut scanned = 0;
    while scanned < MAX_SCANNED_RECORDS && Instant::now() < deadline {
        let Ok(Some(envelope)) = wire::read_envelope(reader, false) else { break };
        match envelope["type"].as_str() {
            Some("stream_item") if envelope["stream_id"] == stream_id.as_str() => {
                scanned += 1;
                let item = &envelope["item"];
                let Some(sequence) = number(&item["sequence"]) else { continue };
                if wanted.binary_search(&sequence).is_ok() {
                    found.insert(sequence, item.clone());
                }
                if sequence >= last {
                    break;
                }
            }
            Some("stream_end") if envelope["stream_id"] == stream_id.as_str() => break,
            _ => {}
        }
    }
    found
}

/// The screen text a plugin record carried (`native.evidence`), its lines
/// cut to [`MAX_TEXT_LINES`] from the end.
fn screen_text(record: &Value) -> Option<String> {
    let text = record.pointer("/payload/native/evidence")?.as_str()?;
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(MAX_TEXT_LINES);
    Some(lines[start..].join("\n")).filter(|text| !text.trim().is_empty())
}

/// What a journal record adds to the reason that names it.
fn with_record(mut reason: Value, records: &HashMap<u64, Value>, wanted: &[u64]) -> Value {
    let Some(sequence) = number(&reason["sequence"]) else { return reason };
    if !wanted.contains(&sequence) {
        return reason;
    }
    let Some(record) = records.get(&sequence) else {
        reason.set("retained", json!(false));
        return reason;
    };
    reason.set("retained", json!(true));
    if let Some(text) = screen_text(record) {
        reason.set("screen_text", json!(text));
    }
    let tool = ["/payload/normalized/tool_name", "/payload/native/tool_name"]
        .into_iter()
        .find_map(|pointer| record.pointer(pointer).and_then(Value::as_str));
    if let Some(tool) = tool {
        reason.set("tool", json!(tool));
    }
    reason
}

/// The `agent explain` value of `terminal`, or `None` when no agent runs
/// there: its name, harness and shown status (done-until-seen), the roster's
/// state and source, and the reason (`row.state_reason`) with the screen
/// text and tool of the journal records it names.
pub(super) fn explain_value(
    snapshot: &Value,
    terminal: &Value,
    row: Option<&Value>,
    records: &HashMap<u64, Value>,
    wanted: &[u64],
) -> Option<Value> {
    let terminal_id = terminal["id"].as_str()?;
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let notifications = snapshot["notifications"].as_array().map(Vec::as_slice);
    let unseen = wire::unseen_terminals(notifications.unwrap_or_default()).contains(terminal_id);
    let shown = roster::agent_of_terminal(terminal, agents, unseen);
    let facts = roster_names::facts(snapshot);
    let name = facts.get(terminal_id).and_then(|facts| facts.name()).map(str::to_owned);
    let mut value = json!({
        "terminal": terminal_id,
        "name": name,
        "harness": shown.as_ref().map(|row| super::agent_vocabulary::harness_name(&row.harness)),
        "status": shown.as_ref().map(roster::AgentRow::status_word),
    });
    if let Some(row) = row {
        let reason = &row["state_reason"];
        let state = row["state"].as_str().unwrap_or("unknown");
        value.set("state", json!(state));
        let source = row["source"].as_str().map(super::agent_vocabulary::source_name);
        value.set("source", json!(source));
        value.set(
            "since_ms",
            number(&reason["since_ms"])
                .or_else(|| number(&row["since_ms"]))
                .map(|ms| ms.to_string())
                .into(),
        );
        value.set("updated_at_ms", number(&row["updated_at_ms"]).map(|ms| ms.to_string()).into());
        if reason["cause"].is_object() {
            value.set("cause", with_record(reason["cause"].clone(), records, wanted));
        }
        if reason["previous"].is_object() {
            value.set("previous", reason["previous"].clone());
        }
        if reason["screen"].is_object() {
            let mut screen = with_record(reason["screen"].clone(), records, wanted);
            screen.set("agrees", json!(screen["state"] == state));
            value.set("screen", screen);
        }
        if value["status"] == "done" && state == "idle" {
            value.set("status_reason", json!("unread_notification"));
        }
        return Some(value);
    }
    // No roster row: an agent the terminal's own OSC 7501 status names (or a
    // daemon too old to say why).
    let shown = shown?;
    value.set("state", json!(shown.status_word()));
    value.set("source", json!(super::agent_vocabulary::source_name(&shown.source)));
    value.set("updated_at_ms", shown.updated_at_ms.map(|ms| ms.to_string()).into());
    if shown.source == "program_status" {
        value.set(
            "cause",
            json!({
                "decision": "program_status",
                "program": shown.harness,
                "at_ms": shown.updated_at_ms.map(|ms| ms.to_string()),
            }),
        );
    }
    Some(value)
}

fn age(now_ms: u64, at: &Value) -> Option<String> {
    number(at).map(|at| roster::age(now_ms.saturating_sub(at)))
}

fn fill(template: &str, values: &[&str]) -> String {
    let mut text = template.to_owned();
    for value in values {
        text = text.replacen("{}", value, 1);
    }
    text
}

fn decision_text(
    messages: &crate::localization::AgentStateMessages,
    decision: &str,
) -> Option<&'static str> {
    Some(match decision {
        "hook" => messages.decision_hook,
        "hook_report" => messages.decision_hook_report,
        "socket_report" => messages.decision_socket_report,
        "screen" => messages.decision_screen,
        "screen_after_stale_hook" => messages.decision_screen_after_stale_hook,
        "screen_cleared_hook_blocker" => messages.decision_screen_cleared_hook_blocker,
        "screen_ended_hook_turn" => messages.decision_screen_ended_hook_turn,
        "screen_legacy" => messages.decision_screen_legacy,
        "program_status_cleared_hook_blocker" => {
            messages.decision_program_status_cleared_hook_blocker
        }
        _ => return None,
    })
}

fn basis_text(
    messages: &crate::localization::AgentStateMessages,
    basis: &str,
) -> Option<&'static str> {
    Some(match basis {
        "idle_fallback" => messages.basis_idle_fallback,
        "output_activity" => messages.basis_output_activity,
        "process_identity" => messages.basis_process_identity,
        "process_exit" => messages.basis_process_exit,
        _ => return None,
    })
}

/// What one record says: hook event and tool, or rule, basis and manifest,
/// then its age and journal sequence.
fn record_parts(
    messages: &crate::localization::AgentStateMessages,
    record: &Value,
    now_ms: u64,
) -> Vec<String> {
    let mut parts = Vec::new();
    if record["decision"] == "program_status" {
        let program = record["program"].as_str().unwrap_or("-");
        parts.push(fill(messages.program_status, &[program]));
    } else if record.get("producer").is_none()
        && record["decision"] != "program_status_cleared_hook_blocker"
        && let Some(event) = record["event"].as_str()
    {
        parts.push(fill(messages.hook_event, &[event]));
    }
    if let Some(tool) = record["tool"].as_str() {
        parts.push(fill(messages.tool, &[tool]));
    }
    if let Some(rule) = record["rule"].as_str() {
        parts.push(fill(messages.rule, &[rule]));
    }
    if let Some(basis) = record["basis"].as_str().and_then(|basis| basis_text(messages, basis)) {
        parts.push(basis.to_owned());
    }
    if let Some(version) = record["manifest"]["version"].as_str() {
        let source = record["manifest"]["source"].as_str().unwrap_or("-");
        parts.push(fill(messages.manifest, &[version, source]));
    }
    let at = if record["observed_at_ms"].is_null() {
        &record["at_ms"]
    } else {
        &record["observed_at_ms"]
    };
    if let Some(age) = age(now_ms, at) {
        parts.push(fill(messages.ago, &[&age]));
    }
    if let Some(sequence) = record["sequence"].as_str() {
        parts.push(fill(messages.journal, &[sequence]));
    }
    if record["retained"] == false {
        parts.push(messages.record_gone.to_owned());
    }
    parts
}

fn text_block(lines: &mut Vec<String>, label: &str, text: Option<&str>) {
    let Some(text) = text else { return };
    lines.push(format!("  {label}:"));
    lines.extend(text.lines().map(|line| format!("    | {line}")));
}

/// The human text of an [`explain_value`].
pub(super) fn human(
    value: &Value,
    messages: &crate::localization::AgentStateMessages,
    now_ms: u64,
) -> String {
    let terminal = value["terminal"].as_str().unwrap_or("-");
    let header = [value["name"].as_str(), Some(terminal), value["harness"].as_str()]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("  ");
    let mut lines = vec![header];
    let state = value["state"].as_str().unwrap_or("unknown");
    let mut state_line =
        format!("{state}, {}", fill(messages.source, &[value["source"].as_str().unwrap_or("-")]));
    if let Some(age) = age(now_ms, &value["since_ms"]) {
        state_line.push_str(", ");
        state_line.push_str(&fill(messages.for_duration, &[&age]));
    }
    lines.push(format!("{}: {state_line}", messages.state));
    if value["status_reason"] == "unread_notification" {
        lines.push(format!("{}: {}", messages.shown_as, messages.done_unseen));
    }
    match value.get("cause") {
        Some(cause) => {
            let decision = cause["decision"].as_str().unwrap_or_default();
            let mut parts = Vec::new();
            if let Some(text) = decision_text(messages, decision) {
                parts.push(text.to_owned());
            }
            parts.extend(record_parts(messages, cause, now_ms));
            lines.push(format!("{}: {}", messages.cause, parts.join(", ")));
            text_block(&mut lines, messages.screen_text, cause["screen_text"].as_str());
        }
        None => lines.push(format!("{}: {}", messages.cause, messages.no_cause)),
    }
    if let Some(previous) = value.get("previous") {
        let mut line = format!(
            "{}, {}",
            previous["state"].as_str().unwrap_or("-"),
            fill(messages.source, &[previous["source"].as_str().unwrap_or("-")])
        );
        if let (Some(since), Some(until)) =
            (number(&previous["since_ms"]), number(&previous["until_ms"]))
        {
            line.push_str(", ");
            line.push_str(&fill(
                messages.for_duration,
                &[&roster::age(until.saturating_sub(since))],
            ));
        }
        if let Some(age) = age(now_ms, &previous["until_ms"]) {
            line.push_str(", ");
            line.push_str(&fill(messages.ago, &[&age]));
        }
        lines.push(format!("{}: {line}", messages.before));
    }
    if let Some(screen) = value.get("screen") {
        let same_record = screen["sequence"] == value["cause"]["sequence"];
        if !same_record {
            let mut parts = vec![screen["state"].as_str().unwrap_or("-").to_owned()];
            parts.extend(record_parts(messages, screen, now_ms));
            if screen["agrees"] == false && value["source"] == "hook" {
                parts.push(messages.screen_ignored.to_owned());
            }
            lines.push(format!("{}: {}", messages.screen, parts.join(", ")));
            text_block(&mut lines, messages.screen_text, screen["screen_text"].as_str());
        }
    }
    lines.join("\n")
}

#[cfg(test)]
#[path = "agent_explain_tests.rs"]
mod tests;
