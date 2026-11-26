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
//! only if all of these still hold, checked before each of the two keys:
//! - the wall clock is still well short of the cache's expiry (10 s before `/compact`, 5 s
//!   before Return), so a late dispatch, a clock jump or a sleep never compacts a cold cache;
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
//! later turn's end replaces it, and a turn or session start or end, or the terminal's removal,
//! drops it with the terminal's compacted record. The thread never sleeps between the two keys:
//! a typed `/compact` re-arms for its Return [`SUBMIT_GAP`] later, so a burst of due terminals
//! does not queue behind one another. When the Return's gates fail but the box still holds only
//! its own `/compact`, it erases that. Stop condition: an entry fires once at its deadline (and
//! once more for its Return) and goes; the thread ends with the mux (its channel closes).

use super::Mux;
use crate::resource::TerminalPublicId;
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
    /// A terminal agent's turn or session started or ended, or the terminal was removed:
    /// forget the terminal.
    Forget(TerminalPublicId),
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
                // The tier the latest request reported writing; one that wrote neither keeps
                // the one before (a resumed session can drop from the hour to 5 minutes).
                let wrote = |tier: &str| {
                    usage
                        .pointer(&format!("/cache_creation/ephemeral_{tier}_input_tokens"))
                        .and_then(Value::as_u64)
                        .is_some_and(|n| n > 0)
                };
                if wrote("1h") {
                    one_hour = true;
                } else if wrote("5m") {
                    one_hour = false;
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
    cmux_conversation::parse_rfc3339_millis(at)
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
    let rules: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| is_rule(line))
        .map(|(index, _)| index)
        .collect();
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

/// What the daemon types to compact.
const COMMAND: &[u8] = b"/compact";
/// The least time left on the cache when `/compact` is typed: the Return comes [`SUBMIT_GAP`]
/// later and Claude Code then sends the compaction, which must reach the cache before it lapses.
const TYPE_MARGIN_MS: u64 = 10_000;
/// The least time left on the cache when the Return is sent.
const SUBMIT_MARGIN_MS: u64 = 5_000;

/// Which keys an armed entry sends next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    /// `/compact`, at the cache's deadline less [`lead_ms`].
    Type,
    /// Return, [`SUBMIT_GAP`] after `/compact` was typed.
    Submit,
}

/// One terminal's armed compaction.
#[derive(Clone, Debug)]
struct Armed {
    due: Instant,
    stage: Stage,
    /// When the armed request's cache lapses (Unix ms): checked against the wall clock right
    /// before each key, so a late dispatch (a burst of due entries, a clock jump, a sleep the
    /// monotonic `due` did not count) never compacts a cold cache.
    expires_ms: u64,
    session: Option<String>,
    transcript: PathBuf,
    request: String,
    /// The terminal's `last_input` when it was armed.
    input: Option<u64>,
}

impl Armed {
    fn warm(&self, now_ms: u64, margin_ms: u64) -> bool {
        now_ms.saturating_add(margin_ms) <= self.expires_ms
    }
}

/// What firing sees of one terminal: the mux ([`MuxTarget`]), or a test's fake.
trait Target {
    /// The wall clock (Unix ms).
    fn now_ms(&self) -> u64;
    /// The token bar now, or None when warm compaction is off.
    fn min_tokens(&self) -> Option<u64>;
    /// Whether the terminal's agent is still the armed session's idle Claude Code.
    fn idle(&self) -> bool;
    fn last_input(&self) -> Option<u64>;
    /// The terminal's screen text.
    fn screen(&self) -> Option<String>;
    /// The transcript's last request now.
    fn last_request(&self) -> Option<LastRequest>;
    fn write(&self, bytes: &[u8]) -> bool;
}

/// What one due entry did.
#[derive(Debug, PartialEq, Eq)]
enum Fired {
    /// Typed `/compact`: the Return is armed next.
    Typed,
    /// Sent the Return: the compaction runs.
    Submitted,
    /// Took back its own `/compact` (the cache got too close to lapsing, or the agent left
    /// idle): the box is as it found it.
    Withdrawn,
    /// A gate failed: nothing more is sent.
    Skipped,
}

/// Types `/compact` when every gate holds and the cache has [`TYPE_MARGIN_MS`] left.
fn type_compact(target: &impl Target, entry: &Armed) -> Fired {
    if !entry.warm(target.now_ms(), TYPE_MARGIN_MS) {
        return Fired::Skipped;
    }
    let Some(min_tokens) = target.min_tokens() else { return Fired::Skipped };
    if !target.idle() || target.last_input() != entry.input {
        return Fired::Skipped;
    }
    let Some(request) = target.last_request() else { return Fired::Skipped };
    if request.key != entry.request || request.context < min_tokens {
        return Fired::Skipped;
    }
    if target.screen().as_deref().and_then(input_box_text).as_deref() != Some("") {
        return Fired::Skipped;
    }
    // Again right before the keys: the transcript and screen reads take time too.
    if !entry.warm(target.now_ms(), TYPE_MARGIN_MS) || !target.write(COMMAND) {
        return Fired::Skipped;
    }
    Fired::Typed
}

/// Sends the Return only if the box still holds just `/compact` from the same idle session,
/// nobody typed in the gap and the cache has [`SUBMIT_MARGIN_MS`] left, so it never sends a
/// person's draft or a cold compaction. Otherwise it erases its own `/compact` when the box
/// still holds only that.
fn submit_compact(target: &impl Target, entry: &Armed) -> Fired {
    let boxed = target.screen().as_deref().and_then(input_box_text);
    let untouched =
        target.last_input() == entry.input && boxed.as_deref().map(str::as_bytes) == Some(COMMAND);
    if !untouched {
        return Fired::Skipped;
    }
    if target.idle() && entry.warm(target.now_ms(), SUBMIT_MARGIN_MS) {
        return if target.write(b"\r") { Fired::Submitted } else { Fired::Skipped };
    }
    let _ = target.write(&[0x7f; COMMAND.len()]);
    Fired::Withdrawn
}

/// The timer's state: at most one entry per terminal, and the request each terminal last
/// compacted after. Both are keyed by live terminals only: a later turn's end, a disarm (turn
/// or session start or end) and the terminal's removal drop the terminal from both.
#[derive(Default)]
struct Timer {
    armed: HashMap<TerminalPublicId, Armed>,
    /// Never twice for one request.
    compacted: HashMap<TerminalPublicId, String>,
}

impl Timer {
    fn next_due(&self) -> Option<Instant> {
        self.armed.values().map(|entry| entry.due).min()
    }

    fn already_compacted(&self, terminal: &TerminalPublicId, request: &str) -> bool {
        self.compacted.get(terminal).is_some_and(|done| done == request)
    }

    /// A turn ended: replace the terminal's entry. A request other than the compacted one
    /// supersedes that record.
    fn turn_ended(&mut self, terminal: &TerminalPublicId, entry: Option<Armed>) {
        self.armed.remove(terminal);
        if let Some(entry) = entry {
            if !self.already_compacted(terminal, &entry.request) {
                self.compacted.remove(terminal);
            }
            self.armed.insert(terminal.clone(), entry);
        }
    }

    /// A turn or session started or ended, or the terminal went: forget the terminal.
    fn forget(&mut self, terminal: &TerminalPublicId) {
        self.armed.remove(terminal);
        self.compacted.remove(terminal);
    }

    /// Runs every entry due at `now`, without blocking: a typed `/compact` re-arms for its
    /// Return [`SUBMIT_GAP`] later, so a burst of due terminals all type within one pass and
    /// none waits on another's gap. `target` gives the terminal's view, or None when it has no
    /// idle surface.
    fn fire_due<T: Target>(
        &mut self,
        now: Instant,
        mut target: impl FnMut(&TerminalPublicId, &Armed) -> Option<T>,
    ) {
        let due: Vec<TerminalPublicId> = self
            .armed
            .iter()
            .filter(|(_, entry)| entry.due <= now)
            .map(|(terminal, _)| terminal.clone())
            .collect();
        for terminal in due {
            let Some(entry) = self.armed.remove(&terminal) else { continue };
            let Some(view) = target(&terminal, &entry) else { continue };
            match entry.stage {
                Stage::Type => {
                    if type_compact(&view, &entry) == Fired::Typed {
                        let due = Instant::now().max(now) + SUBMIT_GAP;
                        self.armed.insert(terminal, Armed { due, stage: Stage::Submit, ..entry });
                    }
                }
                Stage::Submit => {
                    if submit_compact(&view, &entry) == Fired::Submitted {
                        self.compacted.insert(terminal, entry.request);
                    }
                }
            }
        }
    }
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

    fn send_terminal_warm_compact(&self, command: Command) {
        let sender =
            self.terminal_warm_compact.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = sender.as_ref() {
            let _ = sender.send(command);
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
                Command::Forget(terminal.clone())
            }
            _ => return,
        };
        self.send_terminal_warm_compact(command);
    }

    /// The terminal was removed: the timer forgets it (`purge_terminal_side_tables`).
    pub(super) fn forget_terminal_warm_compact(&self, terminal: &TerminalPublicId) {
        self.send_terminal_warm_compact(Command::Forget(terminal.clone()));
    }

    /// The token bar now, or None when off.
    fn terminal_warm_compact_min_tokens(self: &Arc<Self>) -> Option<u64> {
        min_tokens(&self.settings_effective_root(), |var| std::env::var(var).ok())
    }

    /// The terminal's surface, when its agent is `session`'s idle Claude Code.
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

/// A terminal as the daemon sees it.
struct MuxTarget {
    mux: Arc<Mux>,
    terminal: TerminalPublicId,
    session: Option<String>,
    transcript: PathBuf,
    surface: Arc<crate::Surface>,
}

impl Target for MuxTarget {
    fn now_ms(&self) -> u64 {
        crate::startup_timings::unix_now_ms()
    }
    fn min_tokens(&self) -> Option<u64> {
        self.mux.terminal_warm_compact_min_tokens()
    }
    fn idle(&self) -> bool {
        self.mux.terminal_warm_compact_idle(&self.terminal, self.session.as_deref()).is_some()
    }
    fn last_input(&self) -> Option<u64> {
        self.surface.terminal_last_input()
    }
    fn screen(&self) -> Option<String> {
        self.surface.try_with_terminal(|t| t.active_text()).ok()?.ok()
    }
    fn last_request(&self) -> Option<LastRequest> {
        read_tail(&self.transcript).as_deref().and_then(last_request)
    }
    fn write(&self, bytes: &[u8]) -> bool {
        self.surface.write_bytes(bytes).is_ok()
    }
}

fn run(mux: &Weak<Mux>, receiver: mpsc::Receiver<Command>) {
    let mut timer = Timer::default();
    loop {
        let command = match timer.next_due() {
            Some(due) => receiver.recv_timeout(due.saturating_duration_since(Instant::now())),
            None => receiver.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
        };
        match command {
            Ok(Command::TurnEnded { terminal, session, transcript }) => {
                let Some(mux) = mux.upgrade() else { return };
                let entry = arm(&mux, &terminal, session, transcript, &timer);
                timer.turn_ended(&terminal, entry);
            }
            Ok(Command::Forget(terminal)) => timer.forget(&terminal),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
        let Some(mux) = mux.upgrade() else { return };
        timer.fire_due(Instant::now(), |terminal, entry| {
            let surface = mux.terminal_warm_compact_idle(terminal, entry.session.as_deref())?;
            Some(MuxTarget {
                mux: mux.clone(),
                terminal: terminal.clone(),
                session: entry.session.clone(),
                transcript: entry.transcript.clone(),
                surface,
            })
        });
    }
}

fn arm(
    mux: &Arc<Mux>,
    terminal: &TerminalPublicId,
    session: Option<String>,
    transcript: PathBuf,
    timer: &Timer,
) -> Option<Armed> {
    let min_tokens = mux.terminal_warm_compact_min_tokens()?;
    let request = last_request(&read_tail(&transcript)?)?;
    if request.context < min_tokens || timer.already_compacted(terminal, &request.key) {
        return None;
    }
    let now_ms = crate::startup_timings::unix_now_ms();
    let wait = fire_at_ms(&request).checked_sub(now_ms).filter(|wait| *wait > 0)?;
    let surface = mux.terminal_warm_compact_idle(terminal, session.as_deref());
    let input = surface.as_ref().and_then(|surface| surface.terminal_last_input());
    Some(Armed {
        due: Instant::now() + Duration::from_millis(wait),
        stage: Stage::Type,
        expires_ms: request.started_ms + request.ttl_ms,
        session,
        transcript,
        request: request.key,
        input,
    })
}

#[cfg(test)]
#[path = "terminal_warm_compact_tests.rs"]
mod tests;
