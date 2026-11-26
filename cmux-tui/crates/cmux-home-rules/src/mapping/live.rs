//! `HomeLiveMapping` and `HomeAgentRunMapping`: a Chief's live frames and run records, local or
//! Cloud, as Home's live events and agent runs. Decoding only; HomeStore keeps the state.
//!
//! Home's live types are not `Codable`, so the replies are this module's own camelCase rows, one per
//! Swift type (`HomeLiveDelta`, `HomeLiveActivityFrame`, `HomeLiveRunSnapshot`, `HomeLiveRunChange`,
//! `HomeAgentRun`); dates are seconds since 1970.

use super::{Identity, author};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::Value;

// MARK: wire

/// `ConversationRunTool.Input`: only the fields Chief messages need, read leniently.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolInput {
    pub id: Option<String>,
    pub message: Option<String>,
    pub is_tell_envelope: bool,
    pub tasks: Option<Vec<String>>,
    pub is_spawn_envelope: bool,
    pub sender: Option<String>,
}

fn string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

fn strings(value: Option<&Value>) -> Option<Vec<String>> {
    value.and_then(|v| serde_json::from_value(v.clone()).ok())
}

impl ToolInput {
    /// `_meta.cmux.sender` when it is a string.
    fn sender(fields: &serde_json::Map<String, Value>) -> Option<String> {
        string(fields.get("_meta")?.get("cmux")?.get("sender"))
    }

    pub fn from_value(value: &Value) -> Self {
        let Some(fields) = value.as_object() else {
            return Self::default();
        };
        if let Some(arguments) = fields.get("arguments") {
            let Some(arguments) = arguments.as_object() else {
                return Self::default();
            };
            let server = string(fields.get("server"));
            let tool = string(fields.get("tool"));
            let optchat = server.as_deref() == Some("optchat");
            Self {
                id: string(arguments.get("id")),
                message: string(arguments.get("message")),
                is_tell_envelope: optchat && tool.as_deref() == Some("tell"),
                tasks: strings(arguments.get("tasks")),
                is_spawn_envelope: optchat && tool.as_deref() == Some("spawn"),
                sender: Self::sender(arguments).or_else(|| Self::sender(fields)),
            }
        } else {
            Self {
                id: string(fields.get("id")),
                message: string(fields.get("message")),
                tasks: strings(fields.get("tasks")),
                sender: Self::sender(fields),
                ..Self::default()
            }
        }
    }
}

/// `ConversationRunTool`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Tool {
    pub name: String,
    pub input: Option<ToolInput>,
    pub status: Option<String>,
    pub output: Option<String>,
    pub started_at: Option<f64>,
}

impl<'de> Deserialize<'de> for Tool {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        let Some(fields) = value.as_object() else {
            return Ok(Self::default());
        };
        let input = |key: &str| fields.get(key).filter(|v| !v.is_null()).map(ToolInput::from_value);
        Ok(Self {
            name: string(fields.get("name"))
                .or_else(|| string(fields.get("tool")))
                .unwrap_or_default(),
            input: input("input").or_else(|| input("arguments")),
            status: string(fields.get("status")),
            output: string(fields.get("output")),
            started_at: fields.get("started_at").and_then(Value::as_f64),
        })
    }
}

/// `ConversationRunRows.Step`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct Step {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub tool: Option<Tool>,
    #[serde(default)]
    pub status: Option<String>,
    /// The step's first write, in milliseconds since 1970.
    #[serde(default)]
    pub at: Option<f64>,
    #[serde(default)]
    pub truncated: Option<bool>,
    #[serde(default)]
    pub rev: Option<u64>,
    #[serde(default)]
    pub seq: Option<u64>,
}

/// `ConversationRunRows`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct Rows {
    pub steps: Vec<Step>,
    #[serde(default)]
    pub has_more: Option<bool>,
}

/// `ConversationRunSummary` (and `ConversationRunChanged.Run`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct RunSummary {
    pub id: String,
    pub author: String,
    #[serde(default)]
    pub turn: Option<String>,
    pub status: String,
    #[serde(default)]
    pub answers: Option<Vec<String>>,
    #[serde(default)]
    pub thread_root: Option<String>,
    #[serde(default)]
    pub started_at: Option<f64>,
    #[serde(default)]
    pub rev: Option<u64>,
    #[serde(default)]
    pub last_step_seq: Option<u64>,
}

/// `ConversationRunChanged`.
#[derive(Debug, Clone, Deserialize)]
pub struct RunChanged {
    pub conversation: String,
    pub run: RunSummary,
    #[serde(default)]
    pub steps: Option<Vec<Step>>,
    #[serde(default)]
    pub account: Option<String>,
}

/// `ChiefLiveFrame.StepDelta`.
#[derive(Debug, Clone, Deserialize)]
pub struct StepDelta {
    pub conversation: String,
    pub run: String,
    pub step: String,
    pub kind: String,
    pub seq: u64,
    pub text: String,
    #[serde(default)]
    pub r#final: Option<bool>,
    #[serde(default)]
    pub author: Option<String>,
}

/// `ChiefLiveFrame.RunActivity`.
#[derive(Debug, Clone, Deserialize)]
pub struct RunActivity {
    pub conversation: String,
    pub run: String,
    pub line: String,
    pub since: f64,
    #[serde(default)]
    pub at: Option<f64>,
    #[serde(default)]
    pub author: Option<String>,
}

/// `ChiefLiveFrame.RunLive.Step`.
#[derive(Debug, Clone, Deserialize)]
pub struct LiveStep {
    pub step: String,
    pub kind: String,
    pub seq: u64,
    pub text: String,
}

/// `ChiefLiveFrame.RunLive.Activity`.
#[derive(Debug, Clone, Deserialize)]
pub struct LiveActivity {
    pub line: String,
    pub since: f64,
    #[serde(default)]
    pub at: Option<f64>,
}

/// `ChiefLiveFrame.RunLive.Run`.
#[derive(Debug, Clone, Deserialize)]
pub struct LiveRun {
    pub run: String,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub steps: Option<Vec<LiveStep>>,
    #[serde(default)]
    pub activity: Option<LiveActivity>,
}

/// `ChiefLiveFrame.RunLive`.
#[derive(Debug, Clone, Deserialize)]
pub struct RunLive {
    pub conversation: String,
    pub runs: Vec<LiveRun>,
}

/// `ChiefLiveFrame`, tagged by `type` (or `t`); an unknown type changes nothing.
#[derive(Debug, Clone)]
pub enum Frame {
    Delta(StepDelta),
    Activity(RunActivity),
    Snapshot(RunLive),
    Unknown,
}

impl<'de> Deserialize<'de> for Frame {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let value = Value::deserialize(deserializer)?;
        let kind = match (value.get("type"), value.get("t")) {
            (Some(Value::String(kind)), _)
            | (None | Some(Value::Null), Some(Value::String(kind))) => Some(kind.clone()),
            (None | Some(Value::Null), None | Some(Value::Null)) => None,
            _ => return Err(D::Error::custom("a frame type that is not a string")),
        };
        Ok(match kind.as_deref() {
            Some("step.delta") => {
                Frame::Delta(serde_json::from_value(value).map_err(D::Error::custom)?)
            }
            Some("run.activity") => {
                Frame::Activity(serde_json::from_value(value).map_err(D::Error::custom)?)
            }
            Some("run.live") => {
                Frame::Snapshot(serde_json::from_value(value).map_err(D::Error::custom)?)
            }
            _ => Frame::Unknown,
        })
    }
}

/// `ConversationLive`.
#[derive(Debug, Clone, Deserialize)]
pub struct Live {
    pub conversation: String,
    pub frame: Frame,
    #[serde(default)]
    pub account: Option<String>,
}

// MARK: Home rows

/// `HomeLiveDelta`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeDelta {
    pub conversation: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub run: String,
    pub step: String,
    pub is_talk: bool,
    pub seq: u64,
    pub text: String,
    pub is_final: bool,
}

/// `HomeLiveActivity`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HomeActivity {
    pub line: String,
    pub since: f64,
}

/// `HomeLiveActivityFrame`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HomeActivityFrame {
    pub conversation: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub run: String,
    pub activity: HomeActivity,
}

/// `HomeLiveRunSnapshot.Step`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeStep {
    pub step: String,
    pub is_talk: bool,
    pub seq: u64,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place: Option<u64>,
}

/// `HomeLiveRunSnapshot`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HomeRunSnapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub run: String,
    pub steps: Vec<HomeStep>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity: Option<HomeActivity>,
}

/// `HomeLiveEvent`, the cases a frame makes.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HomeLiveEvent {
    Delta(HomeDelta),
    Activity(HomeActivityFrame),
    Snapshot { conversation: String, runs: Vec<HomeRunSnapshot> },
}

/// `HomeAgentRun.Message`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AgentMessage {
    pub id: String,
    pub sequence: u64,
    pub revision: u64,
    pub peer: String,
    pub outgoing: bool,
    pub text: String,
    pub date: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender: Option<String>,
    pub queued: bool,
}

/// `HomeAgentRun`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRun {
    pub conversation: String,
    pub id: String,
    pub author: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    pub answers: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_root: Option<String>,
    pub revision: u64,
    pub messages: Vec<AgentMessage>,
}

/// `HomeLiveRunChange`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeRunChange {
    pub conversation: String,
    pub author: String,
    pub run: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    pub status: String,
    pub agent_run: AgentRun,
}

// MARK: mapping

fn activity(line: &str, since_ms: f64) -> Option<HomeActivity> {
    let line = line.trim();
    (!line.is_empty()).then(|| HomeActivity { line: line.to_string(), since: since_ms / 1000.0 })
}

/// `HomeLiveMapping.event(_: ConversationLive)`: nil for an unknown frame or an empty activity line.
pub fn event(live: &Live, identity: Option<&Identity>) -> Option<HomeLiveEvent> {
    let map = |id: &Option<String>| id.as_deref().map(|id| author(identity, id));
    match &live.frame {
        Frame::Delta(delta) => Some(HomeLiveEvent::Delta(HomeDelta {
            conversation: live.conversation.clone(),
            author: map(&delta.author),
            run: delta.run.clone(),
            step: delta.step.clone(),
            is_talk: delta.kind == "talk",
            seq: delta.seq,
            text: delta.text.clone(),
            is_final: delta.r#final == Some(true),
        })),
        Frame::Activity(frame) => Some(HomeLiveEvent::Activity(HomeActivityFrame {
            conversation: live.conversation.clone(),
            author: map(&frame.author),
            run: frame.run.clone(),
            activity: activity(&frame.line, frame.since)?,
        })),
        Frame::Snapshot(snapshot) => Some(HomeLiveEvent::Snapshot {
            conversation: snapshot.conversation.clone(),
            runs: snapshot
                .runs
                .iter()
                .map(|run| HomeRunSnapshot {
                    author: map(&run.author),
                    run: run.run.clone(),
                    steps: run
                        .steps
                        .iter()
                        .flatten()
                        .map(|step| HomeStep {
                            step: step.step.clone(),
                            is_talk: step.kind == "talk",
                            seq: step.seq,
                            text: step.text.clone(),
                            place: None,
                        })
                        .collect(),
                    activity: run.activity.as_ref().and_then(|a| activity(&a.line, a.since)),
                })
                .collect(),
        }),
        Frame::Unknown => None,
    }
}

/// `HomeLiveMapping.event(_: ConversationRunChanged)`.
pub fn run_changed(
    changed: &RunChanged,
    identity: Option<&Identity>,
    failure_label: Option<&str>,
) -> HomeRunChange {
    HomeRunChange {
        conversation: changed.conversation.clone(),
        author: author(identity, &changed.run.author),
        run: changed.run.id.clone(),
        turn: changed.run.turn.clone(),
        status: changed.run.status.clone(),
        agent_run: agent_run(
            &changed.run,
            &changed.conversation,
            changed.steps.as_deref().unwrap_or_default(),
            identity,
            failure_label,
        ),
    }
}

/// `HomeLiveMapping.talkRows`: a run's talk rows; a cut row gives only its place.
pub fn talk_rows(rows: &Rows) -> Vec<HomeStep> {
    rows.steps
        .iter()
        .filter(|step| step.kind == "talk")
        .map(|step| HomeStep {
            step: step.id.clone(),
            is_talk: true,
            seq: 0,
            text: if step.truncated == Some(true) {
                String::new()
            } else {
                step.text.clone().unwrap_or_default()
            },
            place: step.seq,
        })
        .collect()
}

const TELL: &[&str] = &["tell", "optchat.tell", "mcp__optchat__tell"];
const SPAWN: &[&str] = &["spawn", "optchat.spawn", "mcp__optchat__spawn"];

/// `HomeAgentRunMapping.run`: the run's messages with its agents. Only authenticated tells (with the
/// prompt's `_meta.cmux.sender`), finished spawns and the Chief producer's `report:` notes count.
/// `failure_label` is `StatusIndicatorState.error.shortLabel` (localized, so Swift sends it); with
/// none, a failed tell gets no suffix.
pub fn agent_run(
    run: &RunSummary,
    conversation: &str,
    steps: &[Step],
    identity: Option<&Identity>,
    failure_label: Option<&str>,
) -> AgentRun {
    let messages = steps
        .iter()
        .flat_map(|step| {
            let at = step
                .at
                .or_else(|| step.tool.as_ref().and_then(|t| t.started_at))
                .or(run.started_at);
            let date = at.unwrap_or(0.0) / 1000.0;
            let sequence = step.seq.unwrap_or(0);
            let revision = step.rev.unwrap_or(0);
            let sender =
                step.tool.as_ref().and_then(|t| t.input.as_ref()).and_then(|i| i.sender.clone());
            if let Some(spawned) = spawned(step) {
                return spawned
                    .into_iter()
                    .map(|(peer, task, queued)| AgentMessage {
                        id: format!("{}:{peer}", step.id),
                        sequence,
                        revision,
                        peer,
                        outgoing: true,
                        text: task,
                        date,
                        sender: sender.clone(),
                        queued,
                    })
                    .collect::<Vec<_>>();
            }
            let message = |peer: String,
                           text: String,
                           outgoing: bool,
                           sender: Option<String>,
                           queued: bool| {
                vec![AgentMessage {
                    id: step.id.clone(),
                    sequence,
                    revision,
                    peer,
                    outgoing,
                    text,
                    date,
                    sender,
                    queued,
                }]
            };
            if let Some(tool) = step.tool.as_ref().filter(|_| step.kind == "tool") {
                let input = tool.input.as_ref();
                let is_tell =
                    TELL.contains(&tool.name.as_str()) || input.is_some_and(|i| i.is_tell_envelope);
                if let (true, Some(id), Some(text)) = (
                    is_tell,
                    input.and_then(|i| i.id.as_ref()).filter(|id| !id.trim().is_empty()),
                    input.and_then(|i| i.message.as_ref()),
                ) {
                    let mut body = text.clone();
                    let reason = tool.output.as_deref().unwrap_or_default().trim();
                    let refused =
                        reason == "outcome: refused" || reason.starts_with("outcome: refused.");
                    let failed = step.status.as_deref() == Some("failed")
                        || tool.status.as_deref() == Some("failed");
                    if let (true, Some(label)) = (failed || refused, failure_label) {
                        if reason.is_empty() {
                            body.push_str(&format!("\n[{label}]"));
                        } else {
                            body.push_str(&format!("\n[{label}: {reason}]"));
                        }
                    }
                    let queued =
                        reason == "outcome: queued" || reason.starts_with("outcome: queued.");
                    return message(id.clone(), body, true, sender, queued);
                }
            }
            if step.kind == "note" && step.id.starts_with("report:") {
                if let Some(rest) = step.text.as_deref().and_then(|body| body.strip_prefix('[')) {
                    if let Some((peer, text)) = rest.split_once("] ") {
                        return message(peer.to_string(), text.to_string(), false, None, false);
                    }
                }
            }
            Vec::new()
        })
        .collect();
    AgentRun {
        conversation: conversation.to_string(),
        id: run.id.clone(),
        author: author(identity, &run.author),
        turn: run.turn.clone(),
        answers: run.answers.clone().unwrap_or_default(),
        thread_root: run.thread_root.clone(),
        revision: run.rev.unwrap_or(0),
        messages,
    }
}

/// A finished spawn's agents, tasks and whether each waits in the Chief's queue: one `- a<N>: …`
/// line per task, in order. Nil for any other step, a spawn with no answer yet, or an answer that
/// names a different count of agents than it had tasks.
fn spawned(step: &Step) -> Option<Vec<(String, String, bool)>> {
    let tool = step.tool.as_ref().filter(|_| step.kind == "tool")?;
    let input = tool.input.as_ref()?;
    let tasks = input.tasks.as_ref().filter(|tasks| !tasks.is_empty())?;
    if !(SPAWN.contains(&tool.name.as_str()) || input.is_spawn_envelope) {
        return None;
    }
    let output = tool.output.as_ref()?;
    // Swift's `split(separator: "\n")` drops empty pieces; a CRLF stays one Character, so no split there.
    let ids: Vec<(String, bool)> = swift_lines(output)
        .into_iter()
        .filter_map(|line| {
            if !line.starts_with("- a") {
                return None;
            }
            let colon = line.find(':')?;
            let id = &line[2..colon];
            let digits = &id[1..];
            if id.chars().count() <= 1 || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let outcome = line[colon + 1..].trim_start_matches(' ');
            let queued = outcome == "queued"
                || outcome.starts_with("queued ")
                || outcome.starts_with("queued(");
            Some((id.to_string(), queued))
        })
        .collect();
    if ids.len() != tasks.len() {
        return None;
    }
    Some(
        ids.into_iter().zip(tasks).map(|((id, queued), task)| (id, task.clone(), queued)).collect(),
    )
}

/// Swift's `split(separator: "\n")` over Characters: empty pieces dropped, and `\r\n` is one
/// Character, so it never splits there.
fn swift_lines(text: &str) -> Vec<&str> {
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'\n' && (i == 0 || bytes[i - 1] != b'\r') {
            if i > start {
                lines.push(&text[start..i]);
            }
            start = i + 1;
        }
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

// MARK: ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LiveEventRequest {
    live: Live,
    #[serde(default)]
    identity: Option<Identity>,
}

#[derive(Serialize)]
struct LiveEventReply {
    event: Option<HomeLiveEvent>,
}

/// `mapping.liveEvent {live, identity?}` → `{event}` (null: nothing to show).
pub fn live_event_op(request: &Value) -> Result<Value, OpError> {
    let request: LiveEventRequest = ops::parse(request)?;
    ops::reply(&LiveEventReply { event: event(&request.live, request.identity.as_ref()) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunChangedRequest {
    changed: RunChanged,
    #[serde(default)]
    identity: Option<Identity>,
    #[serde(default)]
    failure_label: Option<String>,
}

/// `mapping.runChanged {changed, identity?, failureLabel?}` → `HomeLiveRunChange`.
pub fn run_changed_op(request: &Value) -> Result<Value, OpError> {
    let request: RunChangedRequest = ops::parse(request)?;
    ops::reply(&run_changed(
        &request.changed,
        request.identity.as_ref(),
        request.failure_label.as_deref(),
    ))
}

#[derive(Deserialize)]
struct TalkRowsRequest {
    rows: Rows,
}

#[derive(Serialize)]
struct TalkRowsReply {
    steps: Vec<HomeStep>,
}

/// `mapping.talkRows {rows}` → `{steps}`.
pub fn talk_rows_op(request: &Value) -> Result<Value, OpError> {
    let request: TalkRowsRequest = ops::parse(request)?;
    ops::reply(&TalkRowsReply { steps: talk_rows(&request.rows) })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentRunRequest {
    run: RunSummary,
    conversation: String,
    #[serde(default)]
    steps: Vec<Step>,
    #[serde(default)]
    identity: Option<Identity>,
    #[serde(default)]
    failure_label: Option<String>,
}

/// `mapping.agentRun {run, conversation, steps, identity?, failureLabel?}` → `HomeAgentRun`.
pub fn agent_run_op(request: &Value) -> Result<Value, OpError> {
    let request: AgentRunRequest = ops::parse(request)?;
    ops::reply(&agent_run(
        &request.run,
        &request.conversation,
        &request.steps,
        request.identity.as_ref(),
        request.failure_label.as_deref(),
    ))
}
