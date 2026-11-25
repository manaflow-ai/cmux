//! Warm compaction for agents in a terminal (ask c-9d3ce5a165, Leo 2026-11-25: "Why can't warm
//! compaction apply to clis too").
//!
//! acpmux compacts an idle chat's context just before its prompt cache expires
//! (`acpmux/src/hub/cache_compact.rs`): the compaction reads the still-warm cache (about 12K
//! read, 23K written) instead of the next prompt rewriting the whole context cold (60K-200K
//! written). acpmux only sees the chats it runs. A `claude` started in a cmux terminal (by hand,
//! `sr2 claude`, a workspace command) has nothing between its turns: every prompt after an idle
//! longer than its cache's TTL pays the full rewrite. The daemon is the one place every terminal
//! harness passes through: their hooks land in its journal (`agent_hooks.rs`), and it owns the
//! terminal's screen and input.
//!
//! So on each finished turn of a terminal Claude Code (its `Stop` hook, `agent.turn.completed`,
//! with the transcript path the hook names), this reads the transcript's last request: when it
//! started, its context (input + cache read + cache write tokens) and its cache tier (1 hour when
//! it wrote any `ephemeral_1h` tokens, else 5 minutes). When the context is at least the chat
//! setting's bar (`agents.cacheCompact.minContextTokens`, 60K by default; the same
//! `agents.cacheCompact.enabled`, on by default, and the same `ACPMUX_CACHE_COMPACT*` overrides),
//! one timer per terminal is armed for [`lead_ms`] before that cache's expiry: 30 s for the
//! 5-minute tier, 3 min for the hour, as acpmux does. The terminal's window size is not in the
//! transcript, so only the token bar applies here, not `minContextPercent`.
//!
//! When it fires, the daemon types `/compact` and Return into the terminal, as a person would,
//! only if all of these still hold:
//! - the terminal's agent is the same Claude Code session and idle (its roster record);
//! - nobody wrote input to the terminal since the turn ended (`terminal_last_input`);
//! - the transcript's last request is still the one it armed for, and no compaction came after;
//! - the input box on screen is empty (`❯` alone between Claude Code's two rules), so it never
//!   adds to, or sends, a half-typed prompt;
//! - it has not already compacted after that request.
//!
//! Other harnesses (Codex, OpenCode, ...) arm nothing: their transcripts name no cache expiry.
//!
//! The timer: one thread, started with the daemon ([`Mux::start_terminal_warm_compact`]), holding
//! only a weak reference to the mux; a command channel carries finished turns to it, and the
//! transcript is read there, never on the hook's path. Each terminal holds at most one entry; a
//! later turn's end replaces it and the end of its session drops it. Stop condition: an entry
//! fires once at its deadline and goes; the thread ends with the mux (its channel closes).

use super::Mux;
use crate::TerminalPublicId;
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

/// How long before a 5-minute cache's expiry the compaction runs (acpmux `LEAD_MS`).
const LEAD_MS: u64 = 30_000;
/// How long before a 1-hour cache's expiry it runs (acpmux `LONG_LEAD_MS`).
const LONG_LEAD_MS: u64 = 180_000;
const FIVE_MINUTES_MS: u64 = 5 * 60_000;
const ONE_HOUR_MS: u64 = 60 * 60_000;
/// The gap between the typed command and its Return (`cmd_terminal_io::TYPED_SUBMIT_GAP`): Claude
/// Code's slash menu takes the Return as choosing the command it typed.
const SUBMIT_GAP: Duration = Duration::from_millis(250);
/// The most of a transcript's end read to find its last request; one assistant line is far less.
const TAIL_BYTES: u64 = 4 << 20;

pub(super) const SETTING_ENABLED: &str = "agents.cacheCompact.enabled";
pub(super) const SETTING_MIN_TOKENS: &str = "agents.cacheCompact.minContextTokens";
pub(super) const ENV_ENABLED: &str = "ACPMUX_CACHE_COMPACT";
pub(super) const ENV_MIN_TOKENS: &str = "ACPMUX_CACHE_COMPACT_MIN_CONTEXT_TOKENS";
const DEFAULT_MIN_TOKENS: u64 = 60_000;
const MIN_TOKENS_RANGE: (u64, u64) = (10_000, 500_000);

/// How long before the expiry of a cache of `ttl_ms` the compaction runs.
pub(super) fn lead_ms(ttl_ms: u64) -> u64 {
    if ttl_ms > 10 * 60_000 { LONG_LEAD_MS } else { LEAD_MS }
}

/// The mux's handle on the timer thread.
#[derive(Default)]
pub(super) struct TerminalWarmCompact {
    sender: Mutex<Option<mpsc::Sender<Command>>>,
}

#[derive(Debug)]
enum Command {
    /// A terminal agent's turn ended: arm for its last request.
    TurnEnded { terminal: TerminalPublicId, session: Option<String>, transcript: PathBuf },
    /// A terminal agent's turn started or its session ended: disarm.
    Disarm(TerminalPublicId),
}

/// A transcript's last request, as far as warm compaction needs it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct LastRequest {
    /// The request's assistant message (`message.id`, else the line's `uuid`).
    pub key: String,
    /// When the request was sent (Unix ms): the line before its first assistant line.
    pub started_ms: u64,
    /// Its context: input + cache read + cache write tokens.
    pub context: u64,
    /// Its cache TTL (ms).
    pub ttl_ms: u64,
}

/// What a transcript's end says: its last request, unless a compaction came after it.
pub(super) fn last_request(text: &str) -> Option<LastRequest> {
    let mut last: Option<LastRequest> = None;
    let mut previous_ms: Option<u64> = None;
    let mut one_hour = false;
    for line in text.lines() {
        let Ok(entry) = serde_json::from_str::<Value>(line) else { continue };
        let at = entry.get("timestamp").and_then(Value::as_str).and_then(parse_ms);
        if entry.get("type").and_then(Value::as_str) == Some("system")
            && entry.get("subtype").and_then(Value::as_str) == Some("compact_boundary")
        {
            last = None;
        }
        let sidechain = entry.get("isSidechain").and_then(Value::as_bool).unwrap_or(false);
        let usage = entry.pointer("/message/usage");
        if entry.get("type").and_then(Value::as_str) == Some("assistant")
            && !sidechain
            && let Some(usage) = usage
        {
            let tokens = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
            let context = tokens("input_tokens")
                + tokens("cache_read_input_tokens")
                + tokens("cache_creation_input_tokens");
            if context > 0 {
                if usage
                    .pointer("/cache_creation/ephemeral_1h_input_tokens")
                    .and_then(Value::as_u64)
                    .is_some_and(|n| n > 0)
                {
                    one_hour = true;
                }
                let key = entry
                    .pointer("/message/id")
                    .or_else(|| entry.get("uuid"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                match last.as_mut() {
                    // A later line of the same response: its usage, the same start.
                    Some(request) if request.key == key && !key.is_empty() => {
                        request.context = context;
                    }
                    _ => {
                        if let Some(started_ms) = previous_ms.or(at) {
                            last = Some(LastRequest { key, started_ms, context, ttl_ms: 0 });
                        }
                    }
                }
            }
        }
        if let Some(at) = at
            && !sidechain
        {
            previous_ms = Some(at);
        }
    }
    last.map(|request| LastRequest {
        ttl_ms: if one_hour { ONE_HOUR_MS } else { FIVE_MINUTES_MS },
        ..request
    })
}

/// When to compact for `request` (Unix ms): `lead_ms` before its cache's expiry.
pub(super) fn fire_at_ms(request: &LastRequest) -> u64 {
    (request.started_ms + request.ttl_ms).saturating_sub(lead_ms(request.ttl_ms))
}

fn parse_ms(at: &str) -> Option<u64> {
    let at =
        time::OffsetDateTime::parse(at, &time::format_description::well_known::Rfc3339).ok()?;
    u64::try_from(at.unix_timestamp_nanos() / 1_000_000).ok()
}

/// The end of a transcript, from a line start, at most [`TAIL_BYTES`].
fn read_tail(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::with_capacity((len - start) as usize);
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    if start == 0 {
        return Some(text);
    }
    // The first line may be cut: drop it.
    Some(text.split_once('\n').map(|(_, rest)| rest.to_owned()).unwrap_or_default())
}

/// The token bar a terminal agent's context must reach, from the chat settings and their
/// environment overrides (`env` wins), or None when warm compaction is off.
pub(super) fn min_tokens(root: &Value, env: impl Fn(&str) -> Option<String>) -> Option<u64> {
    let get = |key: &str| {
        root.get(key)
            .cloned()
            .or_else(|| root.pointer(&format!("/{}", key.replace('.', "/"))).cloned())
    };
    let enabled = env_flag(env(ENV_ENABLED).as_deref())
        .or_else(|| get(SETTING_ENABLED).and_then(|value| value.as_bool()));
    if enabled == Some(false) {
        return None;
    }
    Some(
        env(ENV_MIN_TOKENS)
            .and_then(|value| value.trim().parse::<f64>().ok())
            .or_else(|| get(SETTING_MIN_TOKENS).and_then(|value| value.as_f64()))
            .filter(|n| n.is_finite())
            .map_or(DEFAULT_MIN_TOKENS, |n| {
                n.clamp(MIN_TOKENS_RANGE.0 as f64, MIN_TOKENS_RANGE.1 as f64) as u64
            }),
    )
}

/// `1|true|on|yes` or `0|false|off|no` (acpmux `cold_wake::env_flag`).
fn env_flag(value: Option<&str>) -> Option<bool> {
    match value?.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

/// Claude Code's input box text on `screen`: the lines between the last two rules, the first
/// starting with a prompt mark, without it (`cli/terminal_talk/reply.rs::input_box_text`).
/// None when the screen shows no such box.
pub(super) fn input_box_text(screen: &str) -> Option<String> {
    let is_rule = |line: &str| {
        let trimmed = line.trim();
        let rule = trimmed.chars().filter(|c| matches!(c, '─' | '━' | '═')).count();
        trimmed.starts_with(['─', '━', '═']) && rule >= 10
    };
    let lines: Vec<&str> = screen.lines().collect();
    let rules: Vec<usize> = (0..lines.len()).filter(|index| is_rule(lines[*index])).collect();
    let (top, bottom) = rules.windows(2).rev().find_map(|pair| match pair {
        [top, bottom] if *bottom > top + 1 => Some((*top, *bottom)),
        _ => None,
    })?;
    let inside = lines.get(top + 1..bottom)?;
    let (first, rest) = inside.split_first()?;
    let first = first.trim_start_matches(|c: char| c.is_whitespace() || c == '│');
    let first = first.strip_prefix(['❯', '>'])?;
    let mut text = first.trim().to_owned();
    for line in rest {
        let line = line.trim_matches(|c: char| c.is_whitespace() || c == '│');
        if !line.is_empty() {
            text.push(' ');
            text.push_str(line);
        }
    }
    Some(text)
}

/// One terminal's armed compaction.
#[derive(Clone, Debug)]
struct Armed {
    due: Instant,
    session: Option<String>,
    transcript: PathBuf,
    request: String,
    /// The terminal's `last_input` when it was armed.
    input: Option<u64>,
}

impl Mux {
    /// Starts the terminal warm-compaction timer (the daemon calls it once).
    pub fn start_terminal_warm_compact(self: &Arc<Self>) {
        let (sender, receiver) = mpsc::channel();
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("mux-terminal-warm-compact".into())
            .spawn(move || run(&mux, receiver));
        match spawned {
            Ok(_) => {
                *self.terminal_warm_compact.sender.lock().unwrap_or_else(PoisonError::into_inner) =
                    Some(sender);
            }
            Err(_) => self.report_internal_diagnostic("terminal warm compaction not started"),
        }
    }

    /// Tells the timer about a committed agent hook of `terminal`. Cheap: the transcript is read
    /// on the timer's thread.
    pub(super) fn note_terminal_warm_compact(
        &self,
        ingress: &crate::JournalIngress,
        terminal: &TerminalPublicId,
    ) {
        let command = match ingress.kind.as_str() {
            "agent.turn.completed" => {
                let payload = &ingress.payload;
                if payload.pointer("/adapter/id").and_then(Value::as_str) != Some("claude") {
                    return;
                }
                let normalized = payload.get("normalized");
                let Some(transcript) = normalized
                    .and_then(|n| n.get("transcript_path"))
                    .and_then(Value::as_str)
                    .filter(|path| !path.is_empty())
                else {
                    return;
                };
                Command::TurnEnded {
                    terminal: terminal.clone(),
                    session: normalized
                        .and_then(|n| n.get("agent_session_id"))
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    transcript: PathBuf::from(transcript),
                }
            }
            "agent.turn.started" | "agent.session.started" | "agent.session.ended" => {
                Command::Disarm(terminal.clone())
            }
            _ => return,
        };
        let sender =
            self.terminal_warm_compact.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = sender.as_ref() {
            let _ = sender.send(command);
        }
    }

    /// The token bar now, or None when off.
    fn terminal_warm_compact_min_tokens(self: &Arc<Self>) -> Option<u64> {
        min_tokens(&self.settings_effective_root(), |var| std::env::var(var).ok())
    }

    /// The terminal's `last_input` and its agent record's surface, when its agent is `session`'s
    /// idle Claude Code.
    fn terminal_warm_compact_idle(
        self: &Arc<Self>,
        terminal: &TerminalPublicId,
        session: Option<&str>,
    ) -> Option<Arc<crate::Surface>> {
        let record = self
            .list_agents(None, None)
            .into_iter()
            .find(|record| &record.terminal_id == terminal)?;
        if record.state != super::AgentState::Idle
            || record.agent.as_deref() != Some("claude")
            || (session.is_some() && record.agent_session_id.as_deref() != session)
        {
            return None;
        }
        self.surface(record.surface)
    }
}

fn run(mux: &Weak<Mux>, receiver: mpsc::Receiver<Command>) {
    let mut armed: HashMap<TerminalPublicId, Armed> = HashMap::new();
    // The request each terminal last compacted after: never twice for one.
    let mut compacted: HashMap<TerminalPublicId, String> = HashMap::new();
    loop {
        let next = armed.values().map(|entry| entry.due).min();
        let command = match next {
            Some(due) => receiver.recv_timeout(due.saturating_duration_since(Instant::now())),
            None => receiver.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
        };
        match command {
            Ok(Command::TurnEnded { terminal, session, transcript }) => {
                armed.remove(&terminal);
                let Some(mux) = mux.upgrade() else { return };
                if let Some(entry) = arm(&mux, &terminal, session, transcript, &compacted) {
                    armed.insert(terminal, entry);
                }
            }
            Ok(Command::Disarm(terminal)) => {
                armed.remove(&terminal);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
        let now = Instant::now();
        let due: Vec<TerminalPublicId> =
            armed.iter().filter(|(_, entry)| entry.due <= now).map(|(t, _)| t.clone()).collect();
        for terminal in due {
            let Some(entry) = armed.remove(&terminal) else { continue };
            let Some(mux) = mux.upgrade() else { return };
            if fire(&mux, &terminal, &entry) {
                compacted.insert(terminal, entry.request);
            }
        }
    }
}

fn arm(
    mux: &Arc<Mux>,
    terminal: &TerminalPublicId,
    session: Option<String>,
    transcript: PathBuf,
    compacted: &HashMap<TerminalPublicId, String>,
) -> Option<Armed> {
    let min_tokens = mux.terminal_warm_compact_min_tokens()?;
    let request = last_request(&read_tail(&transcript)?)?;
    if request.context < min_tokens || compacted.get(terminal) == Some(&request.key) {
        return None;
    }
    let now_ms = crate::startup_timings::unix_now_ms();
    let wait = fire_at_ms(&request).checked_sub(now_ms).filter(|wait| *wait > 0)?;
    let surface = mux.terminal_warm_compact_idle(terminal, session.as_deref());
    let input = surface.as_ref().and_then(|surface| surface.terminal_last_input());
    Some(Armed {
        due: Instant::now() + Duration::from_millis(wait),
        session,
        transcript,
        request: request.key,
        input,
    })
}

/// Types `/compact` into the terminal when every gate still holds; true when it did.
fn fire(mux: &Arc<Mux>, terminal: &TerminalPublicId, entry: &Armed) -> bool {
    let Some(min_tokens) = mux.terminal_warm_compact_min_tokens() else { return false };
    let Some(surface) = mux.terminal_warm_compact_idle(terminal, entry.session.as_deref()) else {
        return false;
    };
    if surface.terminal_last_input() != entry.input {
        return false;
    }
    let Some(request) = read_tail(&entry.transcript).as_deref().and_then(last_request) else {
        return false;
    };
    if request.key != entry.request || request.context < min_tokens {
        return false;
    }
    let Ok(Ok(screen)) = surface.try_with_terminal(|t| t.active_text()) else { return false };
    if input_box_text(&screen).as_deref() != Some("") {
        return false;
    }
    if surface.write_bytes(b"/compact").is_err() {
        return false;
    }
    std::thread::sleep(SUBMIT_GAP);
    surface.write_bytes(b"\r").is_ok()
}

#[cfg(test)]
#[path = "terminal_warm_compact_tests.rs"]
mod tests;
