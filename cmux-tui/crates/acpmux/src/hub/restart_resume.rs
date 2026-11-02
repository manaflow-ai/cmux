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
//!   transport cut does (`auto_resume_exhausted`).
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

/// What cut the turn off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::hub) enum Cut {
    /// The daemon restarted (an update or a crash).
    Restart,
    /// The chat moved to another machine (`transfer_out.rs`).
    Move,
}

impl Cut {
    /// The `reason` of its records and provenance.
    pub(in crate::hub) fn reason(self) -> &'static str {
        match self {
            Cut::Restart => "daemon_restart",
            Cut::Move => "moved",
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
            Cut::Move => {
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
        let _ = self.store.scan_heads(&session.id, &mut |head: &RecordHead<'_>| {
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
            );
            if !needs_record {
                return true;
            }
            let Some(e) = head.record() else { return true };
            let is_turn = e.msg.get("turnId").and_then(Value::as_str) == Some(turn_id);
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
            match e.kind.as_str() {
                "turn_started" if is_turn => {
                    started = true;
                    trigger = e.msg.get("trigger") == Some(&Value::Bool(true));
                    tool_start = Some(e.seq);
                    prompt_id = field("promptId");
                    control = field("control");
                    gate = e.msg.get("trustGate").and_then(Value::as_bool);
                    let ids = e.msg.pointer("/carried/promptIds").and_then(Value::as_array);
                    carried_ids = ids
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect();
                }
                "turn_started" if e.msg.get("carried").is_none_or(Value::is_null) => {
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
            let _ = self.store.scan_heads(&session.id, &mut |head| {
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
        if attempt > attempts {
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
        let provenance = json!({"kind": "auto_resume", "reason": cut.reason(), "promptId": root, "attempt": attempt, "turnId": turn_id});
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
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::store::EventRecord;

    /// A hub holding one chat whose last turn a restart cut, with `delays` as
    /// `autoResumeDelaysMs` (`None`: the key is unset). `done` continuations ran for it already,
    /// as its prompt id's attempt suffix records. The caller removes `root` when it is done.
    fn cut_turn(
        delays: Option<Vec<u64>>,
        done: usize,
    ) -> (std::path::PathBuf, Arc<Hub>, Arc<Session>) {
        let root =
            std::env::temp_dir().join(format!("acpmux-restart-resume-{}", uuid::Uuid::now_v7()));
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        cfg.auto_resume_delays_ms = delays;
        let store = crate::store::open(&cfg.store, &root).unwrap();
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
            // `idle`: no child process, which is what a daemon restart leaves behind. "open" is
            // not a SessionStatus, and serde refused it before the fixture was even built.
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("c1").unwrap();
        let prompt_id = if done == 0 { "p1".to_owned() } else { format!("p1{SUFFIX}{done}") };
        hub.append(&session, "in", "turn_started", json!({"turnId": "t1", "promptId": prompt_id}));
        hub.append(&session, "in", "user_message", json!({"turnId": "t1", "text": "do the thing"}));
        (root, hub, session)
    }

    /// Why the chat logged `auto_resume_exhausted`, if it did.
    fn exhausted(hub: &Hub) -> Vec<Value> {
        hub.events("c1", 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "auto_resume_exhausted")
            .map(|e| e.msg)
            .collect()
    }

    /// What one cut turn's chain does with `delays` configured and `done` continuations behind
    /// it: the continuation's prompt id if one goes out, and what it logged as exhausted.
    async fn chain(delays: Option<Vec<u64>>, done: usize) -> (Option<String>, Vec<Value>) {
        let (root, hub, session) = cut_turn(delays, done);
        let id = hub.log_restart_continuation(&session, "t1");
        let gave_up = exhausted(&hub);
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
        (id, gave_up)
    }

    /// A daemon that crashed after it queued the continuation and before it settled the cut turn
    /// finds the turn open again: the next one queues the continuation once, not twice.
    #[tokio::test]
    async fn a_crash_before_the_cut_turn_settles_queues_its_continuation_once() {
        let (root, hub, session) = cut_turn(Some(vec![10_000]), 0);
        let first = hub.log_restart_continuation(&session, "t1");
        let again = hub.log_restart_continuation(&session, "t1");
        assert_eq!(first, Some(format!("p1{SUFFIX}1")));
        assert_eq!(again, first);
        let events = hub.events("c1", 0, 10_000).unwrap();
        let queued = events.iter().filter(|e| e.kind == "queued").count();
        assert_eq!(queued, 1, "{events:?}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }

    /// One continuation per configured wait, for a chain of restarts as for a transport cut:
    /// `autoResumeDelaysMs` is the whole loop, not only its waits.
    #[tokio::test]
    async fn the_configured_waits_set_how_many_restart_continuations_run() {
        // One wait: the first continuation goes out.
        let (id, gave_up) = chain(Some(vec![10_000]), 0).await;
        assert_eq!(id, Some(format!("p1{SUFFIX}1")));
        assert!(gave_up.is_empty(), "{gave_up:?}");

        // The second has no wait left, so the chain gives up instead of running a fixed four.
        let (id, gave_up) = chain(Some(vec![10_000]), 1).await;
        assert_eq!(id, None);
        // The fields the record is for, not the whole object: a field added to the record later
        // is not this test's business.
        assert_eq!(gave_up.len(), 1, "{gave_up:?}");
        let msg = &gave_up[0];
        assert_eq!(
            (&msg["promptId"], &msg["attempts"], &msg["turnId"], &msg["reason"]),
            (&json!("p1"), &json!(1), &json!("t1"), &json!("daemon_restart")),
            "{msg}"
        );

        // A configured six-attempt loop runs all of its attempts.
        let (id, gave_up) = chain(Some(vec![10_000; 6]), 5).await;
        assert_eq!(id, Some(format!("p1{SUFFIX}6")));
        assert!(gave_up.is_empty(), "{gave_up:?}");
    }

    /// The key unset keeps the default waits' attempts, and `[]` still turns it off.
    #[tokio::test]
    async fn an_unset_key_keeps_the_default_attempts_and_an_empty_list_turns_it_off() {
        let attempts = DEFAULT_DELAYS_MS.len();
        let (id, _) = chain(None, attempts - 1).await;
        assert_eq!(id, Some(format!("p1{SUFFIX}{attempts}")));

        let (id, gave_up) = chain(None, attempts).await;
        assert_eq!(id, None);
        assert_eq!(gave_up.len(), 1, "{gave_up:?}");

        // Off is not a chain that ran out: it logs nothing.
        let (id, gave_up) = chain(Some(vec![]), 0).await;
        assert_eq!(id, None);
        assert!(gave_up.is_empty(), "{gave_up:?}");
    }

    /// A carried turn (`carried_turn.rs`) the restart cut: its continuation quotes the steers it
    /// carried, logged in the turn before it, and attaches their images; not an older turn's.
    #[tokio::test]
    async fn a_carried_turns_continuation_quotes_the_steers_it_carried() {
        let (root, hub, session) = cut_turn(Some(vec![10_000]), 0);
        let image = json!({"mimeType": "image/png", "data": "aGk="});
        let steer = json!({"turnId": "t1", "promptId": "p-late", "text": "late ask", "steer": true, "images": [image]});
        hub.append(&session, "mux", "user_message", steer);
        let other =
            json!({"turnId": "t1", "promptId": "p-read", "text": "read in t1", "steer": true});
        hub.append(&session, "mux", "user_message", other);
        let started = json!({"turnId": "t2", "promptId": "p-late", "trustGate": true, "carried": {"fromTurnId": "t1", "promptIds": ["p-late"]}});
        hub.append(&session, "mux", "turn_started", started);
        let id = hub.log_restart_continuation(&session, "t2");
        assert_eq!(id, Some(format!("p-late{SUFFIX}1")));
        let events = hub.events("c1", 0, 10_000).unwrap();
        let queued = events.iter().rfind(|e| e.kind == "queued").expect("queued").msg.clone();
        let text = queued["text"].as_str().unwrap();
        assert!(text.contains("late ask"), "{text}");
        assert!(!text.contains("read in t1") && !text.contains("do the thing"), "{text}");
        assert_eq!(queued["images"], json!([image]), "{queued}");
        assert_eq!(queued["trustGate"], true, "{queued}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_continuation_quotes_the_cut_prompt_and_its_steers() {
        let text =
            continue_text(&["do the thing".into(), "also this".into()], &[], ToolOmission::None);
        assert!(text.contains("Its prompt:\n<message>\ndo the thing\n</message>"), "{text}");
        assert!(text.contains("A message sent into it:\n<message>\nalso this\n</message>"));
        assert!(text.ends_with("Do not redo work that completed."));
        let long = continue_text(&["x".repeat(MAX_QUOTE_CHARS + 10)], &[], ToolOmission::None);
        assert!(!long.contains(&"x".repeat(MAX_QUOTE_CHARS + 1)));
    }

    #[test]
    fn a_restart_prompt_lists_tool_calls_that_have_not_finished() {
        let update = |fields| {
            json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"update": fields}
            })
        };
        let records = vec![
            EventRecord {
                seq: 1,
                at: 1,
                dir: "in".into(),
                kind: "tool_call".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call-1",
                    "status": "in_progress"
                })),
                host_seq: None,
            },
            EventRecord {
                seq: 2,
                at: 2,
                dir: "in".into(),
                kind: "tool_call_update".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call-1",
                    "title": "Run tests",
                    "rawInput": {"command": "cargo test -p acpmux"}
                })),
                host_seq: None,
            },
            EventRecord {
                seq: 3,
                at: 3,
                dir: "in".into(),
                kind: "tool_call".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call-2",
                    "title": "Finished",
                    "status": "in_progress"
                })),
                host_seq: None,
            },
            EventRecord {
                seq: 4,
                at: 4,
                dir: "in".into(),
                kind: "tool_call_update".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call-2",
                    "status": "completed"
                })),
                host_seq: None,
            },
        ];
        let (tools, omitted) = unfinished_tools(&records);
        let text = continue_text(&[], &tools, omitted);
        assert!(text.contains("Tool calls started but not finished:"), "{text}");
        assert!(text.contains("Run tests (id: call-1)"), "{text}");
        assert!(text.contains("input: {\"command\":\"cargo test -p acpmux\"}"), "{text}");
        assert!(!text.contains("Finished (id: call-2)"), "{text}");
    }

    fn tool_record(id: usize, status: &str) -> EventRecord {
        EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call_update".into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call_update",
                "toolCallId": format!("call-{id}"), "status": status}}}),
            host_seq: None,
        }
    }

    #[test]
    fn overflow_completion_replays_preserve_exact_retained_histories() {
        let mut records = Vec::new();
        for id in 0..200 {
            records.push(tool_record(id, "in_progress"));
            records.push(tool_record(id, "in_progress"));
        }
        let (tools, omitted) = unfinished_tools(&records);
        assert_eq!(tools.len(), MAX_UNFINISHED_TOOLS);
        assert_eq!(omitted, ToolOmission::Unfinished);
        let retained = tools[0].id.clone();
        for id in 0..200 {
            if format!("call-{id}") == retained {
                continue;
            }
            records.push(tool_record(id, "completed"));
            records.push(tool_record(id, "completed"));
            records.push(tool_record(id, "in_progress"));
        }
        records.push(tool_record(999, "completed"));
        let (tools, omitted) = unfinished_tools(&records);
        assert!(tools.len() <= 1);
        assert!(tools.iter().all(|tool| tool.id == retained));
        assert_eq!(omitted, ToolOmission::Unknown);
        for id in 0..200 {
            records.push(tool_record(id, "failed"));
        }
        let (tools, omitted) = unfinished_tools(&records);
        assert!(tools.is_empty());
        assert_eq!(omitted, ToolOmission::Unknown);
        let text = continue_text(&[], &tools, omitted);
        assert!(!text.contains("Tool calls started"));
        assert!(!text.contains("unfinished tool calls omitted"));
        assert!(text.contains("completion status is unknown"));
    }

    #[test]
    fn completed_tool_histories_are_visited_once() {
        let mut records: Vec<_> = (0..10_000).map(|id| tool_record(id, "in_progress")).collect();
        records.extend((0..10_000).map(|id| tool_record(id, "completed")));
        let mut scans = 0;
        let mut visits = 0;
        let (tools, _) = collect_unfinished(|page| {
            scans += 1;
            for record in &records {
                visits += 1;
                page.note(tool_update(record, None).unwrap());
                assert!(page.calls.len() <= TOOL_PAGE_SIZE);
            }
        });
        assert!(tools.is_empty());
        eprintln!("restart-tool-fold: scans={scans} decoded_updates={visits}");
        assert_eq!((scans, visits), (1, records.len()));
    }

    #[test]
    fn discarded_later_active_tool_is_reported_as_unknown_not_unfinished() {
        let mut identities: Vec<_> = (0..200)
            .map(|id| {
                let digest: [u8; 32] = Sha256::digest(format!("call-{id}").as_bytes()).into();
                (digest, id)
            })
            .collect();
        identities.sort();
        let later = identities.last().unwrap().1;
        let mut records = Vec::new();
        for (_, id) in &identities[..TOOL_PAGE_SIZE] {
            records.push(tool_record(*id, "in_progress"));
            records.push(tool_record(*id, "completed"));
        }
        records.push(tool_record(later, "in_progress"));
        let (tools, omitted) = unfinished_tools(&records);
        assert!(tools.is_empty());
        assert_eq!(omitted, ToolOmission::Unknown);
        assert!(continue_text(&[], &tools, omitted).contains("completion status is unknown"));
    }

    #[test]
    fn retained_tool_metadata_updates_are_preserved() {
        let mut records = vec![tool_record(1, "in_progress")];
        let mut metadata = tool_record(1, "in_progress");
        metadata.msg["params"]["update"]["title"] = json!("Last live tool");
        metadata.msg["params"]["update"]["rawInput"] = json!({"command": "cargo check"});
        records.push(metadata);
        let (tools, omitted) = unfinished_tools(&records);
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].name, "Last live tool");
        assert_eq!(tools[0].input.as_deref(), Some("{\"command\":\"cargo check\"}"));
        assert_eq!(omitted, ToolOmission::None);
    }

    #[test]
    fn restart_tool_details_are_single_line_and_mask_secrets_before_truncation() {
        let credential = ["abcd", "1234"].repeat(8).join("");
        let record = EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call",
                "toolCallId": "call\n\t\u{1b}1", "title": "Run\r\n\t\u{0} tests",
                "status": "in_progress", "rawInput": {"command": format!("curl -H 'Authorization: Bearer {credential}'")}}}}),
            host_seq: None,
        };
        let (tools, omitted) = unfinished_tools(&[record]);
        let text = continue_text(&[], &tools, omitted);
        assert!(text.contains("Run tests (id: call 1)"), "{text}");
        assert!(!text.contains(&credential), "credentials must not enter the continuation");
        assert!(text.contains("[secret]"));
        assert!(!text.contains('\u{1b}') && !text.contains('\u{0}'));
        for prefix in [" ".repeat(270), "x".repeat(240)] {
            let masked = input_prefix(
                &json!({"rawInput": format!("{prefix} Authorization: Bearer {credential}")}),
            )
            .unwrap();
            assert!(!masked.contains(&credential[..24]), "secret straddles display cut");
        }
        let masked = input_prefix(&json!({"rawInput": {"password": credential}})).unwrap();
        assert!(!masked.contains(&credential));
        assert!(masked.contains("[secret]"));
        // A token longer than the scan budget is dropped whole, never exposed as a prefix.
        let huge = credential.repeat(MAX_TOOL_SCAN_BYTES);
        let masked =
            input_prefix(&json!({"rawInput": format!("Authorization: Bearer {huge}")})).unwrap();
        assert!(!masked.contains(&credential[..24]));
        assert!(
            !bounded_text(&format!("Authorization: Bearer {credential}")).contains(&credential)
        );
    }

    #[test]
    fn restart_inputs_mask_decoded_quoted_assignments_before_json_escaping() {
        let password = ["open", "sesame", "42"].join("_");
        let command = format!("PASSWORD=\"{password}\" ./deploy");
        for raw in [json!(command), json!({"command": command}), json!([{"nested": command}])] {
            let masked = input_prefix(&json!({"rawInput": raw})).unwrap();
            assert!(!masked.contains(&password), "quoted assignment leaked into restart input");
            assert!(masked.contains("[secret]"), "{masked}");
            assert!(!masked.contains("./deploy"), "suffix must be redacted: {masked}");
        }
    }

    #[test]
    fn restart_inputs_mask_whole_quoted_assignment_values() {
        for command in [
            r#"PASSWORD="correct horse battery staple" ./deploy"#,
            r#"PASSWORD="open sesame" ./deploy"#,
            r#"PASSWORD='open sesame' ./deploy"#,
            r#"PASSWORD="open \"sesame\" again" ./deploy"#,
            r#"PASSWORD="open\\ sesame" ./deploy"#,
            r#"PASSWORD='open '\''sesame' ./deploy"#,
            r#"PASSWORD="open sesame"' extra words' ./deploy"#,
            r#"PASSWORD="open sesame"suffix ./deploy"#,
            r#"PASSWORD="x" API_KEY='y z' ./deploy"#,
        ] {
            let expected = r#""PASSWORD=[secret]""#;
            assert_eq!(input_prefix(&json!({"rawInput": command})).unwrap(), expected);
            let nested = input_prefix(&json!({"rawInput": {"command": command}})).unwrap();
            assert_eq!(nested, format!("{{\"command\":{expected}}}"));
            let array = input_prefix(&json!({"rawInput": [command]})).unwrap();
            assert_eq!(array, format!("[{expected}]"));
        }
        // A harmless quoted argument remains useful context.
        let plain = r#"echo "correct horse battery staple""#;
        assert_eq!(mask_input_assignments(plain), plain);
    }

    #[test]
    fn restart_inputs_mask_concatenated_and_escaped_shell_assignments() {
        for command in [
            r#"PASSWORD=x"open sesame" ./deploy"#,
            r#"PASSWORD=$'open sesame' ./deploy"#,
            r#"PASSWORD=$"open sesame" ./deploy"#,
            r#"PASSWORD=prefix'open '"sesame"suffix ./deploy"#,
            r#"PASSWORD=x$'open '\"sesame\" ./deploy"#,
            r#"PASSWORD=open\ sesame ./deploy"#,
            r#"PASSWORD=open\ sesame' extra words' ./deploy"#,
            r#"PASSWORD=$'open\' sesame' ./deploy"#,
            r#"PASSWORD='open '\''sesame' ./deploy"#,
            r#"PASSWORD="open "sesame\ again ./deploy"#,
            r#"PASSWORD=x"open sesame" API_KEY=$'another secret' ./deploy"#,
            r#"PASSWORD=abc,correcthorse ./deploy"#,
            r#"PASSWORD=abc}correcthorse ./deploy"#,
            r#"PASSWORD=abc]correcthorse ./deploy"#,
            r#"PASSWORD=abc{correcthorse,more}[tail] ./deploy"#,
        ] {
            let expected = "PASSWORD=[secret]";
            assert_eq!(mask_input_assignments(command), expected, "{command}");
            for (value, masked) in [
                (json!(command), json!(expected)),
                (json!({"command": command}), json!({"command": expected})),
                (json!([command]), json!([expected])),
            ] {
                assert_eq!(
                    input_prefix(&json!({"rawInput": value})).unwrap(),
                    masked.to_string(),
                    "{command}"
                );
            }
        }
    }

    #[test]
    fn restart_inputs_hide_ambiguous_shell_substitution_boundaries() {
        for command in [
            r#"PASSWORD=$(printf 'open sesame') ./deploy"#,
            r#"PASSWORD=prefix`printf 'open sesame'` ./deploy"#,
            r#"PASSWORD=${unset:-open sesame} ./deploy"#,
            r#"PASSWORD="${unset:-open sesame}" ./deploy"#,
            r#"PASSWORD=<(printf 'open sesame') ./deploy"#,
            r#"PASSWORD=>(printf 'open sesame') ./deploy"#,
        ] {
            let expected = "PASSWORD=[secret]";
            assert_eq!(mask_input_assignments(command), expected, "{command}");
            for (raw, masked) in [
                (json!(command), json!(expected)),
                (json!({"command": command}), json!({"command": expected})),
                (json!([command]), json!([expected])),
            ] {
                assert_eq!(input_prefix(&json!({"rawInput": raw})).unwrap(), masked.to_string());
            }
        }
    }

    #[test]
    fn quoted_assignments_redact_literal_and_ansi_c_backslashes() {
        for command in [
            r#"PASSWORD='prefix\'"it's open sesame" ./deploy"#,
            r#"PASSWORD='prefix\'"open sesame" ./deploy"#,
            r#"PASSWORD=\$'prefix\'"it's open sesame" ./deploy"#,
            r#"PASSWORD=$'prefix\' open sesame' ./deploy"#,
            r#"PASSWORD=$'prefix\\'"it's open sesame" ./deploy"#,
        ] {
            for (raw, expected) in [
                (json!(command), r#""PASSWORD=[secret]""#),
                (json!({"command": command}), r#"{"command":"PASSWORD=[secret]"}"#),
                (json!([command]), r#"["PASSWORD=[secret]"]"#),
            ] {
                assert_eq!(input_prefix(&json!({"rawInput": raw})).unwrap(), expected, "{command}");
            }
        }
    }

    #[test]
    fn colon_delimited_quoted_values_redact_ambiguous_data_escapes() {
        let code = r#"config = {'password': 'prefix\' open sesame'}"#;
        let safe = "config = {'password': [secret]";
        for (raw, expected) in [
            (json!(code), json!(safe)),
            (json!({"code": code}), json!({"code": safe})),
            (json!([code]), json!([safe])),
        ] {
            let prefix = input_prefix(&json!({"rawInput": raw})).unwrap();
            assert_eq!(prefix, expected.to_string());
            assert!(!prefix.contains("open sesame"));
        }
    }

    #[test]
    fn restart_inputs_mask_unclosed_and_scan_boundary_quoted_assignments() {
        for command in [
            "PASSWORD=\"open sesame".to_owned(),
            format!("PASSWORD=\"{}\" ./deploy", "open sesame ".repeat(MAX_TOOL_SCAN_BYTES)),
            format!("PASSWORD=\"{}\" ./deploy", "世 界 ".repeat(MAX_TOOL_SCAN_BYTES)),
        ] {
            let prefix = input_prefix(&json!({"rawInput": command})).unwrap();
            for secret_fragment in ["open", "sesame", "世", "界"] {
                assert!(!prefix.contains(secret_fragment), "quoted secret leaked: {prefix}");
            }
        }
    }

    #[test]
    fn restart_inputs_keep_password_field_context_when_masking_structured_input() {
        let password = "open_sesame42";
        let masked = input_prefix(&json!({
            "rawInput": {"password": format!("\"{password}\"")}
        }))
        .unwrap();
        assert!(!masked.contains(password), "structured password leaked: {masked}");
        assert!(masked.contains("[secret]"), "{masked}");
        let masked = input_prefix(&json!({
            "rawInput": {"password": [password]}
        }))
        .unwrap();
        assert!(!masked.contains(password), "nested structured password leaked: {masked}");
        let masked = input_prefix(&json!({
            "rawInput": {"password": "let me in"}
        }))
        .unwrap();
        assert!(!masked.contains("let me in"), "plain structured password leaked: {masked}");
        assert!(masked.contains("[secret]"), "{masked}");
    }

    #[test]
    fn restart_inputs_mask_sensitive_numeric_and_boolean_fields() {
        let masked = input_prefix(&json!({
            "rawInput": {"password": 12345678, "token": true, "secret": null}
        }))
        .unwrap();
        assert!(!masked.contains("12345678"), "numeric password leaked: {masked}");
        assert!(!masked.contains("true"), "boolean token leaked: {masked}");
        assert!(masked.matches("[secret]").count() >= 3, "{masked}");
        let masked = input_prefix(&json!({
            "rawInput": {"apiKey": 12345678, "credentials": "let me in", "authorization": false}
        }))
        .unwrap();
        assert!(!masked.contains("12345678") && !masked.contains("let me in"), "{masked}");
        let long_key = format!("{}password", "x".repeat(MAX_TOOL_FIELD_CHARS));
        let masked = input_prefix(&json!({"rawInput": {long_key: "open_sesame42"}})).unwrap();
        assert!(!masked.contains("open_sesame42"), "long sensitive key leaked: {masked}");
    }

    #[test]
    fn structured_secret_keys_follow_the_assignment_scanner() {
        for key in [
            "apiKey",
            "api_key",
            "api-key",
            "SECRET",
            "accessToken",
            "passwd",
            "password",
            "credentials",
            "private_key",
            "privateKey",
            "access_key",
        ] {
            let assignment = format!("{key}=open_sesame42");
            assert_ne!(crate::secret_scan::mask(&assignment), assignment, "{key}");
            for value in [json!("x"), json!(7), json!(false), json!([{"inside": "x"}])] {
                let input = json!({"rawInput": {key: value}});
                let prefix = input_prefix(&input).unwrap();
                assert!(prefix.contains("[secret]"), "{key}: {prefix}");
            }
        }
        for key in ["authorization", "AUTH", "cookie", "key"] {
            assert!(sensitive_key(key), "{key}");
        }
        // Entire key inspection must not be needed to decide that an oversized key
        // is opaque, including when no sensitive word appears in its prefix.
        assert!(sensitive_key(&"x".repeat(MAX_TOOL_FIELD_CHARS + 1)));
    }

    #[test]
    fn child_tool_updates_are_ignored_and_metadata_is_bounded() {
        let child = EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"_meta": {"acpmux": {"subagent": {"id": "child"}}}, "update": {"sessionUpdate": "tool_call", "toolCallId": "child-call", "status": "in_progress"}}}),
            host_seq: None,
        };
        assert!(tool_update(&child, None).is_none());

        let mut page = ToolPage::default();
        let huge = "x".repeat(MAX_TOOL_FIELD_CHARS + 100);
        page.note(&json!({"toolCallId": huge, "title": huge, "status": "in_progress",
            "rawInput": {"body": "x".repeat(10_000)}}));
        let open = page.calls.values().flatten().next().unwrap();
        assert_eq!(open.id.chars().count(), MAX_TOOL_FIELD_CHARS);
        assert_eq!(open.name.chars().count(), MAX_TOOL_FIELD_CHARS);
        assert!(open.input.as_ref().unwrap().len() <= MAX_TOOL_INPUT_CHARS);
        page.note(&json!({"toolCallId": format!("{huge}2"), "status": "in_progress"}));
        assert_eq!(page.calls.values().flatten().count(), 2);
        page.note(&json!({"toolCallId": huge, "status": "completed"}));
        assert_eq!(page.calls.values().flatten().count(), 1);
        page.note(&json!({"toolCallId": format!("{huge}2"), "status": "failed"}));
        assert_eq!(page.calls.values().flatten().count(), 0);
    }

    #[test]
    fn root_tool_updates_with_subagent_metadata_are_retained() {
        let record = EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"sessionId": "root", "_meta": {"acpmux": {"subagent": "child-1"}},
                "update": {"sessionUpdate": "tool_call", "toolCallId": "root-call", "title": "Own build", "status": "in_progress"}}}),
            host_seq: None,
        };
        assert!(tool_update(&record, Some("root")).is_some());
        assert!(tool_update(&record, Some("other")).is_none());
        let mut child = record;
        child.msg["params"]["_meta"] = Value::Null;
        assert!(tool_update(&child, Some("other")).is_none());
    }

    #[test]
    fn input_serialization_stops_at_the_prefix_budget() {
        use serde::Serialize;
        struct Unvisited;
        impl Serialize for Unvisited {
            fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
                panic!("serialization must stop before the next value");
            }
        }
        let mut bytes = Vec::with_capacity(MAX_TOOL_INPUT_CHARS);
        let mut writer = BoundedJsonWriter { bytes: &mut bytes, limit: MAX_TOOL_INPUT_CHARS };
        assert!(serde_json::to_writer(&mut writer, &("x".repeat(10_000), Unvisited)).is_err());
        assert_eq!(bytes.len(), MAX_TOOL_INPUT_CHARS);
        let prefix = input_prefix(&json!({"rawInput": "世".repeat(10_000)})).unwrap();
        assert!(prefix.len() <= MAX_TOOL_INPUT_CHARS);
        assert!(!prefix.contains('\u{fffd}'));
    }

    #[test]
    fn multibyte_text_is_cut_on_char_boundaries() {
        // "世" is 3 bytes: a 4-byte budget keeps one, never half of the second.
        assert_eq!(char_prefix("世世", 4), "世");
        assert_eq!(char_prefix("世世", 6), "世世");
        assert_eq!(char_prefix("世", 2), "");
        // 7-byte units: the scan cut (4096 = 7 * 585 + 1) lands inside a 3-byte char, and the
        // word crossing it is dropped back to the last space.
        let long = "世世 ".repeat(MAX_TOOL_SCAN_BYTES);
        assert_eq!(masked_scan(&long), "世世 ".repeat(585).trim_end());
        // The truncated tail is cut at a multibyte space (U+3000), not a byte inside it.
        assert_eq!(safe_tool_text("世\u{3000}世世", true, 100), "世");
        // Multibyte text before a sensitive assignment keeps its prefix whole.
        assert_eq!(mask_input_assignments("世 PASSWORD=世世"), "世 PASSWORD=[secret]");
    }

    #[tokio::test]
    async fn restart_journal_ignores_children_and_honors_replayed_completion() {
        use crate::config::{Config, StoreMode};
        let root =
            std::env::temp_dir().join(format!("acpmux-restart-tools-{}", uuid::Uuid::now_v7()));
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        let store = crate::store::open(&cfg.store, &root).unwrap();
        store.save(&serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
        })).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("chat").unwrap();
        let tool = |id: &str, state: &str| {
            json!({"params": {"update": {
                "sessionUpdate": "tool_call", "toolCallId": id, "title": id, "status": state
            }}})
        };
        // Historical inputs must not enter the interrupted turn's summary.
        for _ in 0..100 {
            hub.append(&session, "in", "tool_call", tool("historical", "in_progress"));
        }
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"turnId": "cut", "promptId": "p", "control": "local", "trustGate": false}),
        );
        // More child calls than the display cap, including replayed calls and an ID
        // shared with the parent, cannot consume or remove the parent's entries.
        for n in 0..=MAX_UNFINISHED_TOOLS {
            let mut child = tool(&format!("child-{n}"), "in_progress");
            child["params"]["_meta"] = json!({"acpmux": {"subagent": {"id": "child"}}});
            hub.append(&session, "in", "tool_call.replay", child);
        }
        hub.append(&session, "in", "tool_call", tool("finished", "in_progress"));
        let mut completion = tool("finished", "completed");
        completion["params"]["update"]["sessionUpdate"] = json!("tool_call_update");
        hub.append(&session, "in", "tool_call_update.replay", completion);
        hub.append(&session, "in", "tool_call.replay", tool("own", "in_progress"));
        let mut child = tool("own", "completed");
        child["params"]["_meta"] = json!({"acpmux": {"subagent": {"id": "child"}}});
        hub.append(&session, "in", "tool_call_update", child);
        assert!(hub.log_restart_continuation(&session, "cut").is_some());
        let records = hub.events("chat", 0, usize::MAX).unwrap();
        let text =
            records.iter().find(|e| e.kind == "queued").unwrap().msg["text"].as_str().unwrap();
        assert!(text.contains("own (id: own)"), "{text}");
        for absent in ["child-", "historical", "finished (id:", "omitted"] {
            assert!(!text.contains(absent), "{text}");
        }
        hub.shutdown_all().await;
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn replayed_terminal_tool_update_closes_the_call() {
        let update = |kind: &str, status: &str| EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: kind.into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": status}}}),
            host_seq: None,
        };
        let records = vec![
            EventRecord {
                kind: "tool_call".into(),
                msg: json!({"params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "call-1", "status": "in_progress"}}}),
                ..update("tool_call", "in_progress")
            },
            update("tool_call_update.replay", "completed"),
        ];
        let (tools, omitted) = unfinished_tools(&records);
        assert!(tools.is_empty());
        assert_eq!(omitted, ToolOmission::None);
    }
}
