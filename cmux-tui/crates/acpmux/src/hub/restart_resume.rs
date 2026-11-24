//! A turn a daemon restart cut off goes on by itself. Leo, 2026-10-22: "OUR SHIT IS HARDLY EVER
//! GOING TO GO IDLE ... YOU'LL JUST HAVE TO ACCEPT IT BREAKING AT SOME POINT BUT IT RESUMES
//! WHATEVER IT INTERRUPTED". An update restarts the daemon mid-turn instead of waiting for idle.
//!
//! An agent under a live agent host outlives the daemon and is adopted, turn and all
//! (`hosts.rs`). When the agent ended with the daemon (agent hosts off, a reboot, a host that
//! died), the new daemon settles the open turn `outcome_unknown` (`mod.rs`
//! `mark_unknown_outcomes`) and, here, queues one continuation of it at the head of the chat's
//! queue: an acpmux prompt that quotes the cut turn's prompt and every message steered into it,
//! and tells the agent to check what finished before it goes on.
//!
//! - It is an ordinary `queued` record, so it runs through the restored queue (`queue.rs`
//!   `restore_queues`, `resume_queues`) before the prompts that waited behind the cut turn, and a
//!   crash before it ran puts it back like any queued prompt.
//! - Its prompt id is the cut prompt's next attempt (`P~resume-n`, as `auto_resume.rs`), and it
//!   is written before the cut turn's `turn_result`: a crash between the two finds the turn
//!   open again and the continuation already logged, so it is queued once.
//! - `auto_resume_scheduled` with `reason: "daemon_restart"` records it, and its `user_message`
//!   carries `_meta.provenance = {kind: "auto_resume", reason: "daemon_restart", ...}`.
//! - `autoResumeDelaysMs: []` turns it off, as it does the transport continuation, and a chain
//!   of restarts gives up after the attempts it configures ([`configured_attempts`]), as a
//!   transport cut does (`auto_resume_exhausted`). A move's continuation is not one of those
//!   attempts: a turn moves as many times as a person moves it.
//! - A crash between the continuation's `queued` record and its move to the head
//!   (`queue_order`) still restores it at the head (`queue.rs` `restore_queue`), and once.
//! - It goes through the trust gate as the cut turn did (`turn_started` records `trustGate`),
//!   and carries the images the cut turn's prompt and steers sent (`prompt_images.rs`).
//!
//! A move that stops a running turn (`transfer_begin` with `interrupt`, `transfer_out.rs`) logs
//! the same continuation, with `reason: "moved"` ([`Cut::Move`]), before it stops the turn. The
//! bundle carries it in the queue, so the turn goes on where the chat lands; a move that does not
//! happen gives it back to the queue here. #5846 item 1: a chat moves between a laptop and a
//! Cloud machine mid-turn and keeps working.

use super::{DEFAULT_DELAYS_MS, SUFFIX, configured_attempts, split_attempt};
use crate::hub::{Hub, Session};
use crate::store::{EventRecord, RecordHead};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::{Arc, LazyLock};

/// Longest quote of one cut prompt or steer, in characters.
const MAX_QUOTE_CHARS: usize = 4_000;
/// Longest prefix of one unfinished tool's input shown in a restart prompt.
const MAX_TOOL_INPUT_CHARS: usize = 300;
const MAX_TOOL_FIELD_CHARS: usize = 200;
/// Scan beyond the displayed prefix so secrets crossing its boundary are masked first.
const MAX_TOOL_SCAN_BYTES: usize = 4096;
/// Maximum unfinished calls listed in a restart prompt.
const MAX_UNFINISHED_TOOLS: usize = 32;
// One additional unfinished call proves that the rendered list has omissions.
const TOOL_PAGE_SIZE: usize = MAX_UNFINISHED_TOOLS + 1;

/// Fold one bounded page of complete tool histories. A digest orders identities, not
/// events: each page sees every update for its retained IDs, including terminal replays.
#[derive(Default)]
struct ToolPage {
    discarded: bool,
    calls: BTreeMap<[u8; 32], Option<UnfinishedTool>>,
}

impl ToolPage {
    fn note(&mut self, update: &Value) {
        let Some(id) = update.get("toolCallId").and_then(Value::as_str).filter(|id| !id.is_empty())
        else {
            return;
        };
        let digest: [u8; 32] = Sha256::digest(id.as_bytes()).into();
        if !self.calls.contains_key(&digest) {
            if self.calls.len() == TOOL_PAGE_SIZE {
                self.discarded = true;
                // The threshold only decreases during this pass. A rejected/evicted
                // identity cannot re-enter, so no retained history loses its start.
                if self.calls.last_key_value().is_some_and(|(last, _)| digest > *last) {
                    return;
                }
                self.calls.pop_last();
            }
            let name = update
                .get("title")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .or_else(|| update.get("kind").and_then(Value::as_str))
                .unwrap_or("tool");
            self.calls.insert(
                digest,
                Some(UnfinishedTool {
                    name: bounded_text(name),
                    id: bounded_text(id),
                    input: None,
                }),
            );
        }
        let Some(call) = self.calls.get_mut(&digest) else { return };
        if matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
            // Terminal is absorbing for a turn's tool identity: a replayed start or
            // late metadata update must not resurrect completed work.
            *call = None;
        } else if let Some(call) = call {
            enrich_tool(call, update);
        }
    }
}

/// Whether the bounded preview can prove another unfinished call exists, or merely
/// knows that it discarded histories whose final state it cannot determine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ToolOmission {
    None,
    Unfinished,
    Unknown,
}

/// Scan each current-turn payload once. Keeping the lowest digest histories preserves
/// all updates for each retained identity: an evicted ID can never re-enter. Unlike
/// paging through every identity, this has linear scan work even for long turns with
/// thousands of completed tools. Discarded histories are explicitly unknown, not
/// asserted to be unfinished.
fn collect_unfinished(mut scan: impl FnMut(&mut ToolPage)) -> (Vec<UnfinishedTool>, ToolOmission) {
    let mut page = ToolPage::default();
    scan(&mut page);
    let mut open: Vec<_> = page.calls.into_values().flatten().collect();
    let omitted = if open.len() > MAX_UNFINISHED_TOOLS {
        open.truncate(MAX_UNFINISHED_TOOLS);
        ToolOmission::Unfinished
    } else if page.discarded {
        ToolOmission::Unknown
    } else {
        ToolOmission::None
    };
    (open, omitted)
}

/// One tool call that started before the daemon restart and has no terminal update.
#[derive(Debug, Clone, PartialEq, Eq)]
struct UnfinishedTool {
    name: String,
    id: String,
    input: Option<String>,
}

/// The fields useful to a person resuming a cut turn. Tool updates are JSON-RPC notifications,
/// so the session update is nested under `params.update` in the journal record.
fn tool_update<'a>(record: &'a EventRecord, own_session_id: Option<&str>) -> Option<&'a Value> {
    let marked_subagent = record
        .msg
        .pointer("/params/_meta/acpmux/subagent")
        .or_else(|| record.msg.pointer("/_meta/acpmux/subagent"));
    let update_session_id = record.msg.pointer("/params/sessionId").and_then(Value::as_str);
    // Prefer harness session identity over arbitrary metadata. Root updates may
    // mention a child in _meta; actual child updates retain their own sessionId.
    let child = match (own_session_id, update_session_id) {
        (Some(own), Some(sender)) => own != sender,
        _ => marked_subagent.is_some(),
    };
    if child {
        return None;
    }
    record.msg.pointer("/params/update").filter(|update| {
        matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        )
    })
}

fn input_prefix(update: &Value) -> Option<String> {
    update.get("rawInput").and_then(|raw| {
        (!raw.is_null()).then(|| {
            let mut bytes = Vec::with_capacity(MAX_TOOL_SCAN_BYTES);
            let mut writer = BoundedJsonWriter { bytes: &mut bytes, limit: MAX_TOOL_SCAN_BYTES };
            let truncated = serde_json::to_writer(&mut writer, &MaskedInput::new(raw)).is_err();
            let valid = match std::str::from_utf8(&bytes) {
                Ok(text) => text.len(),
                Err(error) => error.valid_up_to(),
            };
            bytes.truncate(valid);
            let text = String::from_utf8(bytes).unwrap_or_default();
            let masked = safe_tool_text(&text, truncated, MAX_TOOL_INPUT_CHARS);
            // The input budget is also a byte budget, including multibyte characters.
            char_prefix(&masked, MAX_TOOL_INPUT_CHARS).to_owned()
        })
    })
}

/// Mask decoded strings before JSON escaping (e.g. PASSWORD="value" in a shell
/// command). Serialize lazily so the bounded writer still stops large arrays/objects.
struct MaskedInput<'a> {
    value: &'a Value,
    sensitive: bool,
}

impl<'a> MaskedInput<'a> {
    fn new(value: &'a Value) -> Self {
        Self { value, sensitive: false }
    }
    fn with_context(value: &'a Value, sensitive: bool) -> Self {
        Self { value, sensitive }
    }
}

impl serde::Serialize for MaskedInput<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::{SerializeMap, SerializeSeq};
        if self.sensitive {
            return serializer.serialize_str("[secret]");
        }
        match self.value {
            Value::String(text) => {
                let masked = masked_scan(text);
                serializer.serialize_str(&masked)
            }
            Value::Array(values) => {
                let mut seq = serializer.serialize_seq(Some(values.len()))?;
                for value in values {
                    seq.serialize_element(&MaskedInput::with_context(value, self.sensitive))?;
                }
                seq.end()
            }
            Value::Object(values) => {
                let mut map = serializer.serialize_map(Some(values.len()))?;
                for (key, value) in values {
                    let sensitive = self.sensitive || sensitive_key(key);
                    map.serialize_entry(
                        &masked_scan(key),
                        &MaskedInput::with_context(value, sensitive),
                    )?;
                }
                map.end()
            }
            value => serde::Serialize::serialize(value, serializer),
        }
    }
}

fn sensitive_key(key: &str) -> bool {
    // Oversize keys are opaque: redact the entire associated value. This bounds
    // both CPU and allocation even when the sensitive suffix is far beyond the preview.
    if key.len() > MAX_TOOL_FIELD_CHARS {
        return true;
    }
    crate::secret_scan::sensitive_field_name(key)
}

struct BoundedJsonWriter<'a> {
    bytes: &'a mut Vec<u8>,
    limit: usize,
}

impl std::io::Write for BoundedJsonWriter<'_> {
    fn write(&mut self, input: &[u8]) -> std::io::Result<usize> {
        let remaining = self.limit.saturating_sub(self.bytes.len());
        self.bytes.extend(input.iter().take(remaining));
        if input.len() > remaining {
            // Stop serialization immediately, rather than visiting the rest of a large input.
            Err(std::io::Error::other("restart input prefix is full"))
        } else {
            Ok(input.len())
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn bounded_text(value: &str) -> String {
    crate::hub::session::short_text(&masked_scan(value), MAX_TOOL_FIELD_CHARS)
        .chars()
        .take(MAX_TOOL_FIELD_CHARS)
        .collect()
}

/// A tool input may be shell, Python, JSON, or another language whose quote rules
/// conflict. Once it names a sensitive assignment, keep only the safe prefix and
/// redact the remainder of this already bounded preview. Do not guess where a
/// credential ends: preserving a later command suffix is less important than
/// avoiding disclosure across ordinary, escaped, concatenated or unclosed quotes.
fn mask_input_assignments(text: &str) -> String {
    static ASSIGNMENT: LazyLock<Option<regex::Regex>> =
        LazyLock::new(|| regex::Regex::new(r#"\b([a-zA-Z0-9_-]+)["']?\s*[=:]\s*"#).ok());
    let Some(assignment_pattern) = ASSIGNMENT.as_ref() else { return "[secret]".into() };
    for captures in assignment_pattern.captures_iter(text) {
        let Some(assignment) = captures.get(0) else { continue };
        if sensitive_key(&captures[1]) {
            return format!("{}[secret]", text.get(..assignment.end()).unwrap_or_default());
        }
    }
    text.to_owned()
}

fn masked_scan(value: &str) -> String {
    let head = char_prefix(value, MAX_TOOL_SCAN_BYTES);
    let masked = mask_input_assignments(head);
    safe_tool_text(&masked, head.len() < value.len(), MAX_TOOL_SCAN_BYTES)
}

/// The longest prefix of `text` that is at most `max` bytes and ends on a char boundary.
fn char_prefix(text: &str, max: usize) -> &str {
    let end = text
        .char_indices()
        .map(|(at, _)| at)
        .chain([text.len()])
        .take_while(|at| *at <= max)
        .last()
        .unwrap_or(0);
    text.get(..end).unwrap_or_default()
}

/// Like the hand-off preview, discard the word crossing the scan boundary: its partial
/// secret may not match a scanner rule. Mask before the much smaller display cut.
fn safe_tool_text(text: &str, truncated: bool, max: usize) -> String {
    let head = if truncated {
        text.rfind(|c: char| c.is_whitespace() || c.is_control())
            .and_then(|at| text.get(..at))
            .unwrap_or_default()
    } else {
        text
    };
    let normalized: String = head.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    crate::hub::session::short_text(&crate::secret_scan::mask(&normalized), max)
        .chars()
        .take(max)
        .collect()
}

fn enrich_tool(existing: &mut UnfinishedTool, update: &Value) {
    if let Some(name) = update.get("title").and_then(Value::as_str).filter(|n| !n.is_empty()) {
        existing.name = bounded_text(name);
    }
    if let Some(input) = input_prefix(update) {
        existing.input = Some(input);
    }
}

/// Collects tool calls in the cut turn for the journal-fold regression test.
#[cfg(test)]
fn unfinished_tools(records: &[EventRecord]) -> (Vec<UnfinishedTool>, ToolOmission) {
    collect_unfinished(|page| {
        for record in records {
            if let Some(update) = tool_update(record, None) {
                page.note(update);
            }
        }
    })
}

/// The opening of a move's continuation when the move did not happen ([`Cut::unmoved`]).
const STAYED: &str = "This chat did not move: a move to another machine stopped your previous \
                      turn and then did not happen. You are still on this machine, with the same \
                      files; processes you started may have ended with the turn.";

/// The provenance key of a continuation the harness may run from its own transcript, with no
/// prompt written ([`Cut::MoveAtBoundary`]).
const SILENT: &str = "silent";

/// Whether `provenance` is such a continuation's.
pub(in crate::hub) fn silent(provenance: Option<&Value>) -> bool {
    provenance.is_some_and(|p| {
        p.get("kind").and_then(Value::as_str) == Some("auto_resume")
            && p.get(SILENT).and_then(Value::as_bool) == Some(true)
    })
}

/// What cut the turn off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::hub) enum Cut {
    /// The daemon restarted (an update or a crash).
    Restart,
    /// The chat moved to another machine (`transfer_out.rs`).
    Move,
    /// It moved at a tool boundary, with nothing of the turn left running: a [`Cut::Move`] whose
    /// continuation says so (`"silent": true` in its provenance), so a harness that can go on
    /// from its own transcript does, and the text is never written
    /// (`claude_stdio/resume_cut.rs`). Any other harness gets the text as after `Cut::Move`.
    MoveAtBoundary,
}

impl Cut {
    /// The `reason` of its records and provenance.
    pub(in crate::hub) fn reason(self) -> &'static str {
        match self {
            Cut::Restart => "daemon_restart",
            Cut::Move | Cut::MoveAtBoundary => "moved",
        }
    }

    /// Whether `reason` is a queued continuation's, which goes ahead of what waited behind the
    /// cut turn and is no waiting retry (`queue.rs`, `auto_resume/restore.rs`).
    pub(in crate::hub) fn queued(reason: Option<&str>) -> bool {
        matches!(reason, Some("daemon_restart" | "moved"))
    }

    /// A [`Cut::Move`] continuation's text for a move that did not happen (`transfer_out.rs`
    /// `queue_carried`): the same turn, told it is still on this machine. `None` for any other
    /// text.
    pub(in crate::hub) fn unmoved(text: &str) -> Option<String> {
        text.strip_prefix(Cut::Move.opening()).map(|rest| format!("{STAYED}{rest}"))
    }

    fn opening(self) -> &'static str {
        match self {
            Cut::Restart => {
                "acpmux restarted (an update or a crash) while your previous turn was running, \
                 and the turn was cut off."
            }
            Cut::Move | Cut::MoveAtBoundary => {
                "This chat moved to another machine while your previous turn was running, and the \
                 turn was cut off. The files and git state came with it, but processes you \
                 started (dev servers, watchers, background shells) did not: start again any \
                 that you still need."
            }
        }
    }
}

/// The text the agent gets: the cut turn's prompt, then what was steered into it.
#[cfg(test)]
fn continue_text(
    prompts: &[String],
    tools: &[UnfinishedTool],
    omitted_tools: ToolOmission,
) -> String {
    continue_text_for(Cut::Restart, prompts, tools, omitted_tools)
}

fn continue_text_for(
    cut: Cut,
    prompts: &[String],
    tools: &[UnfinishedTool],
    omitted_tools: ToolOmission,
) -> String {
    let mut text = String::from(cut.opening());
    for (i, p) in prompts.iter().enumerate() {
        let quoted: String = p.chars().take(MAX_QUOTE_CHARS).collect();
        let what = if i == 0 { "Its prompt" } else { "A message sent into it" };
        text.push_str(&format!("\n\n{what}:\n<message>\n{quoted}\n</message>"));
    }
    if !tools.is_empty() || omitted_tools == ToolOmission::Unfinished {
        text.push_str("\n\nTool calls started but not finished:");
        for tool in tools {
            text.push_str(&format!("\n- {} (id: {})", tool.name, tool.id));
            if let Some(input) = &tool.input {
                text.push_str(&format!(" input: {input}"));
            }
        }
        if omitted_tools == ToolOmission::Unfinished {
            text.push_str("\n- additional unfinished tool calls omitted");
        }
    }
    if omitted_tools == ToolOmission::Unknown {
        text.push_str(
            "\n\nAdditional tool histories were not retained in this bounded preview; \
            their completion status is unknown. Check the journal before repeating their work.",
        );
    }
    text.push_str(
        "\n\nCheck what already finished (files, commands, messages), then continue from where it \
         stopped. Do not redo work that completed.",
    );
    text
}

impl Hub {
    /// How many of the continuations behind the prompt `root` a move made (`reason: "moved"`).
    /// A move is not a failed attempt: it spends none of the waits `autoResumeDelaysMs`
    /// configures, for a restart's chain here or a transport cut's (`auto_resume.rs`).
    pub(in crate::hub) fn moves_behind(&self, session: &Arc<Session>, root: &str) -> usize {
        let mut moves = 0;
        let _ = self.scan_heads_off(&session.id, &mut |head: &RecordHead<'_>| {
            if head.kind == "auto_resume_scheduled"
                && let Some(e) = head.record()
                && e.msg.get("reason").and_then(Value::as_str) == Some(Cut::Move.reason())
                && e.msg.get("promptId").and_then(Value::as_str) == Some(root)
            {
                moves += 1;
            }
            true
        });
        moves
    }

    /// Before the cut turn `turn_id` is settled: logs the continuation that goes on with it, and
    /// returns its prompt id; `None` when it gets none (turned off, or too many attempts).
    pub(in crate::hub) fn log_restart_continuation(
        &self,
        session: &Arc<Session>,
        turn_id: &str,
    ) -> Option<String> {
        self.log_continuation(session, turn_id, Cut::Restart)
    }

    /// [`Self::log_restart_continuation`] for a turn `cut` cut off.
    pub(in crate::hub) fn log_continuation(
        &self,
        session: &Arc<Session>,
        turn_id: &str,
        cut: Cut,
    ) -> Option<String> {
        // One continuation per configured wait, as a transport cut gets: `[]` configures none,
        // which turns it off. A contended config lock reads as the default waits, never as off.
        let configured = self.config.try_read().map(|c| c.auto_resume_delays_ms.clone());
        let attempts =
            configured.map_or(DEFAULT_DELAYS_MS.len(), |d| configured_attempts(d.as_ref()));
        if attempts == 0 {
            return None;
        }
        // The cut turn's prompt id, control, trust gate, texts and images: its `turn_started`,
        // the `user_message` that started it and those steered into it.
        let (mut prompt_id, mut control, mut gate) = (None::<String>, None::<String>, None);
        let mut cloud_mobile = false;
        let mut prompts: Vec<String> = Vec::new();
        let mut images: Vec<Value> = Vec::new();
        // A Web steer made the turn a Web turn (`web_control.rs` `check_steer`).
        let mut raised_to_web = false;
        // These durable markers are normally applied to live sessions. A dead-host restart has
        // no host replay, so carry their terminal control state into this decision too: a Web
        // continuation must not cross a remote-floor cancellation or stale ended control.
        let mut started = false;
        let mut trigger = false;
        // A carried turn's input is the steers it carried (`carried_turn.rs`), logged in the
        // turns before it: the steers since the last turn that was not carried, by prompt id.
        let mut steered: std::collections::HashMap<String, (Option<String>, Vec<Value>)> =
            Default::default();
        let mut carried_ids: Vec<String> = Vec::new();
        let mut control_ended = false;
        let mut floor_cancelled = false;
        let mut stopped = false;
        let mut tool_start = None;
        let mut tool_end = None;
        // Every `auto_resume_scheduled` a move logged, by the prompt it continues: a move is no
        // failed attempt (`moves_behind`).
        let mut moved: Vec<String> = Vec::new();
        // The last prompt that was no continuation: a continuation of a continuation quotes it,
        // never the continuation before it (ten moves nested the same words ten deep).
        let mut first_ask = None::<(String, String)>;
        // The newest turn before the cut one and the newest prompt text before it, each by turn
        // id: the two records come in either order.
        let (mut ask_turn, mut ask_text) = (None::<(String, String)>, None::<(String, String)>);
        let _ = self.scan_heads_off(&session.id, &mut |head: &RecordHead<'_>| {
            // Headers are cheap to inspect. Parse payloads only after the interrupted turn starts,
            // and stop at its result so a long session does not deserialize historical tool I/O.
            let kind = head.kind.strip_suffix(".replay").unwrap_or(head.kind);
            let needs_record = matches!(
                kind,
                "turn_started"
                    | "user_message"
                    | "turn_control"
                    | "remote_control_ended"
                    | "remote_control_restored"
                    | "remote_floor_cancel"
                    | "turn_result"
                    | "turn_stop_requested"
                    | "auto_resume_scheduled"
            );
            if !needs_record {
                return true;
            }
            let Some(e) = head.record() else { return true };
            let is_turn = e.msg.get("turnId").and_then(Value::as_str) == Some(turn_id);
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
            match e.kind.as_str() {
                "auto_resume_scheduled"
                    if e.msg.get("reason").and_then(Value::as_str) == Some(Cut::Move.reason()) =>
                {
                    moved.extend(field("promptId"));
                }
                "turn_started" if is_turn => {
                    started = true;
                    trigger = e.msg.get("trigger") == Some(&Value::Bool(true));
                    tool_start = Some(e.seq);
                    prompt_id = field("promptId");
                    control = field("control");
                    gate = e.msg.get("trustGate").and_then(Value::as_bool);
                    cloud_mobile =
                        e.msg.get("cloudMobile").and_then(Value::as_bool).unwrap_or(false);
                    let ids = e.msg.pointer("/carried/promptIds").and_then(Value::as_array);
                    carried_ids = ids
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect();
                }
                "turn_started" if started && e.msg.get("carried").is_none_or(Value::is_null) => {
                    steered.clear();
                }
                "turn_control" if is_turn => {
                    raised_to_web |= field("control").as_deref() == Some("web")
                }
                "remote_control_ended" if started => control_ended = true,
                "remote_control_restored" if started => control_ended = false,
                "remote_floor_cancel" if started && is_turn => floor_cancelled = true,
                "user_message"
                    if !started && e.msg.get("steer").and_then(Value::as_bool) == Some(true) =>
                {
                    if let Some(id) = field("promptId") {
                        let named = e.msg.get("images").and_then(Value::as_array);
                        let text = field("text").filter(|t| !t.trim().is_empty());
                        steered.insert(id, (text, named.cloned().unwrap_or_default()));
                    }
                }
                "turn_stop_requested" if is_turn => stopped = true,
                "user_message" if is_turn => {
                    let named = e.msg.get("images").and_then(Value::as_array);
                    let shown = named.map_or(0, Vec::len);
                    images.extend(named.into_iter().flatten().cloned());
                    let text = field("text").filter(|t| !t.trim().is_empty());
                    prompts.extend(text.or_else(|| {
                        (shown > 0).then(|| format!("({shown} image(s), attached again below)"))
                    }));
                }
                "turn_started" | "user_message" if !started => {
                    if e.kind == "turn_started" {
                        ask_turn = field("turnId").zip(field("promptId"));
                    } else {
                        ask_text = field("turnId").zip(field("text"));
                    }
                    if let (Some((turn, id)), Some((of, text))) = (&ask_turn, &ask_text)
                        && turn == of
                        && split_attempt(id).1 == 0
                        && !text.trim().is_empty()
                    {
                        first_ask = Some((id.clone(), text.clone()));
                    }
                    if e.kind == "turn_started" && e.msg.get("carried").is_none_or(Value::is_null) {
                        steered.clear();
                    }
                }
                "turn_result" if is_turn => {
                    tool_end = Some(e.seq);
                    return false;
                }
                _ => {}
            }
            true
        });
        // The trigger dispatcher must reauthorize any retry. A generic restart
        // continuation would drop its principal and execute as the person.
        if trigger {
            return None;
        }
        // A continuation's own prompt is the continuation before it: quote what was asked.
        if let (Some((root, n)), Some((id, text)), Some(own)) =
            (prompt_id.as_deref().map(split_attempt), first_ask, prompts.first_mut())
            && n > 0
            && id == root
        {
            *own = text;
        }
        // The carried steers come first: they started the turn.
        let mut carried_prompts = Vec::new();
        let mut carried_images = Vec::new();
        for id in &carried_ids {
            if let Some((text, named)) = steered.remove(id) {
                let shown = named.len();
                carried_images.extend(named);
                carried_prompts.extend(text.or_else(|| {
                    (shown > 0).then(|| format!("({shown} image(s), attached again below)"))
                }));
            }
        }
        carried_prompts.append(&mut prompts);
        let prompts = carried_prompts;
        carried_images.append(&mut images);
        let images = carried_images;
        if stopped {
            return None;
        }
        let prompt_id = prompt_id.filter(|p| !p.is_empty())?;
        let own_session_id = session.meta().agent_session_id;
        let (unfinished, omitted_tools) = collect_unfinished(|page| {
            let _ = self.scan_heads_off(&session.id, &mut |head| {
                if tool_end.is_some_and(|end| head.seq >= end) {
                    return false;
                }
                if tool_start.is_none_or(|start| head.seq <= start)
                    || !matches!(
                        head.kind.strip_suffix(".replay").unwrap_or(head.kind),
                        "tool_call" | "tool_call_update"
                    )
                {
                    return true;
                }
                if let Some(record) = head.record()
                    && let Some(update) = tool_update(&record, own_session_id.as_deref())
                {
                    page.note(update);
                }
                true
            });
        });
        let (root, done) = split_attempt(&prompt_id);
        let attempt = done + 1;
        // A person moves a chat as often as they like: a move's continuation is never refused for
        // the count, and the moves behind a restart's are not failures it has used up.
        let moves = moved.iter().filter(|id| id.as_str() == root).count();
        if cut == Cut::Restart && attempt.saturating_sub(moves) > attempts {
            let msg = json!({"promptId": root, "attempts": done, "turnId": turn_id, "reason": cut.reason()});
            self.append(session, "mux", "auto_resume_exhausted", msg);
            return None;
        }
        let effective_web = control.as_deref() == Some("web") || raised_to_web;
        let blocked = if effective_web && floor_cancelled {
            Some("remote_floor_cancel")
        } else if effective_web && control_ended {
            Some("remote_control_ended")
        } else {
            None
        };
        if let Some(reason) = blocked {
            self.append(
                session,
                "mux",
                "auto_resume_skipped",
                json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "skipped": reason}),
            );
            return None;
        }
        let id = format!("{root}{SUFFIX}{attempt}");
        // Logged by a daemon that crashed before it settled the turn: once is enough. Its
        // `queued` record counts though it never started (`logged_prompt` leaves such a prompt
        // to recovery): the restored queue runs it.
        if self.logged_prompt(session, &id).is_some() || self.queued_logged(session, &id) {
            return Some(id);
        }
        let msg = json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "delayMs": 0, "reason": cut.reason()});
        self.append(session, "mux", "auto_resume_scheduled", msg);
        let text = continue_text_for(cut, &prompts, &unfinished, omitted_tools);
        let mut provenance = json!({"kind": "auto_resume", "reason": cut.reason(), "promptId": root, "attempt": attempt, "turnId": turn_id});
        // Nothing of the turn was cut short: the harness may go on from its own transcript.
        if cut == Cut::MoveAtBoundary
            && unfinished.is_empty()
            && omitted_tools == ToolOmission::None
            && images.is_empty()
        {
            provenance.set(SILENT, json!(true));
        }
        let control = if raised_to_web { "web" } else { control.as_deref().unwrap_or("web") };
        let mut blocks = vec![json!({"type": "text", "text": text})];
        // Each image's source goes with it as display metadata, so the continuation's record keeps
        // it (`prompt_images.rs`, `keep_sourced`).
        let mut display = Vec::new();
        for image in &images {
            let Some(block) =
                super::super::prompt_images::blocks_of(std::slice::from_ref(image)).pop()
            else {
                continue;
            };
            if let Some(source) = image.get("source") {
                display
                    .push(json!({"kind": "image", "blockIndex": blocks.len(), "source": source}));
            }
            blocks.push(block);
        }
        let mut queued = json!({
            "text": text,
            "client": "acpmux",
            "position": 0,
            "promptId": id,
            "turnId": format!("{turn_id}{SUFFIX}{attempt}"),
            "prompt": blocks,
            "control": control,
            // Checked again as the cut turn was: the folder's trust may have changed across the
            // restart. A Web turn (by its start or a Web steer) is always checked again, as is
            // one from a log from before `turn_started` recorded its gate.
            "trustGate": control == "web" || gate.unwrap_or(false),
            "cloudMobile": cloud_mobile,
        });
        if !images.is_empty() {
            queued.set("images", Value::Array(images));
        }
        if !display.is_empty() {
            queued.set("displayParts", Value::Array(display));
        }
        let queued = crate::prompt_provenance::marked(queued, Some(&provenance));
        self.append(session, "mux", "queued", queued);
        Some(id)
    }
}

impl Hub {
    /// Whether the chat's log holds a `queued` record of prompt `id`.
    fn queued_logged(&self, session: &Session, id: &str) -> bool {
        let mut found = false;
        let _ = self.store.scan_kinds(&session.id, &["queued"], &mut |e: EventRecord| {
            found = e.msg.get("promptId").and_then(Value::as_str) == Some(id);
            !found
        });
        found
    }
}

#[cfg(test)]
#[path = "restart_resume_tests.rs"]
mod tests;
