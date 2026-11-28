//! Part of `Hub`; see `hub/mod.rs`. RFD 0158 §2, deterministic sidecars (turn rules; `sidecars.rs` has the in-turn ones, polling and permission stall): rules over a session's
//! own stream that act with no model tokens (Leo, 2026-11-25: "we can't be letting important
//! rfds like that take breaks"). `loop_detector.rs` (a failed call repeated, an edit undone) is
//! the first; this module adds two that judge whole turns:
//!
//! - **spin**: [`SPIN_TURNS`] completed turns in a row, each running at least [`SPIN_MIN_TOOLS`]
//!   tool calls, that changed no file and no commit. A turn changed something when a call of it
//!   edits, deletes or moves, runs a command the read-only allowlist (`shell_readonly.rs`) does
//!   not pass, or pushes, or HEAD or the branch moved over it. A call of a kind it cannot read
//!   counts as a change: a missed spin costs nothing new, a false one costs a nudge.
//! - **unpushed**: a completed turn whose reply says the work is done, while HEAD, a commit made
//!   in this session (not its starting HEAD), is the tip of no remote-tracking branch and no
//!   push call ran since HEAD last moved.
//!
//! Each fires once per condition: spin not again until a turn changes something, unpushed not
//! again for the same HEAD. A firing raises a `sidecar_notice` record on the session's log and
//! says one line, `[sidecar <rule>] ...`, at the session's next prompt (as an end turn rule
//! does, `turn_rules.rs`): nothing re-prompts the session, so a firing costs no turn.
//!
//! Off by default with `sidecars.rs` (`harness_magic::DEFAULT_OFF`); on: `agents.harnessMagic.sidecars.enabled` true,
//! `ACPMUX_HM_SIDECARS=0` kills it. Counters on the `turn_result`, under `harnessMagic.sidecars`:
//! `observed` (turns judged), `spinFired`, `unpushedFired`, `said` (lines said into this turn's
//! prompt) and `saidChars`. Fails open: an unreadable git state or a poisoned lock leaves the
//! turn as it was.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use regex::Regex;
use serde_json::{Value, json};

use super::{Hub, Session};

/// Shares `sidecars.rs`'s gate: one `agents.harnessMagic.sidecars` switch turns both on.
pub(crate) const FEATURE: &str = super::sidecars::FEATURE;
/// Turns in a row with no change before the spin rule speaks.
pub(crate) const SPIN_TURNS: u32 = 3;
/// A turn with fewer tool calls than this neither counts toward a spin nor breaks one.
pub(crate) const SPIN_MIN_TOOLS: u32 = 4;
/// Tool calls tracked per turn; past it a call is counted as a change.
const MAX_CALLS: usize = 512;
const MAX_ID: usize = 128;
const MAX_SESSIONS: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Class {
    /// Reads only: a read, search, fetch or think call, or a command the allowlist passes.
    Read,
    /// May change a file.
    Change,
    /// Pushes or opens a PR.
    Push,
    /// A command call whose command has not arrived yet.
    Pending,
}

/// A pattern that does not compile is left out (fails open): no push is seen, no done is read.
static PUSH: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\bgit\b[^;&|\n]*\spush\b|\blane-gh\s+push\b|\bgh\s+pr\s+create\b|__push\b|github__commit\b",
    )
    .ok()
});

/// A reply that says the work is finished.
static DONE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(done|finished|completed?|all set|shipped|landed|ready for review|pushed|implemented)\b",
    )
    .ok()
});

/// Words in the same sentence just before a "done" that make it a condition, a plan or a denial,
/// not a claim.
static HEDGE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:not|never|once|when|until|before|after|if|unless|will|won't|yet)\b|n't\b|'ll\b",
    )
    .ok()
});

/// Whether `draft`, a turn's last reply, says the work is done.
pub(crate) fn claims_done(draft: &str) -> bool {
    let (Some(done), Some(hedge)) = (DONE.as_ref(), HEDGE.as_ref()) else { return false };
    done.find_iter(draft).any(|m| {
        let before = draft.get(..m.start()).unwrap_or_default();
        let start = before.char_indices().rev().nth(32).map_or(0, |(i, _)| i);
        let window = before.get(start..).unwrap_or_default();
        let sentence =
            window.rfind(['.', '!', '?', '\n']).and_then(|i| window.get(i + 1..)).unwrap_or(window);
        !hedge.is_match(sentence)
    })
}

/// The command of a tool call: a string, or an argv (`[sh, -c, script]` reads as the script).
fn command(update: &Value) -> Option<String> {
    match update.pointer("/rawInput/command")? {
        Value::String(s) => Some(s.clone()),
        Value::Array(a) => {
            let words: Vec<&str> = a.iter().filter_map(Value::as_str).collect();
            match words.as_slice() {
                [_, flag, script] if matches!(*flag, "-c" | "-lc") => Some((*script).to_owned()),
                _ => Some(words.join(" ")),
            }
        }
        _ => None,
    }
}

/// How a tool call update reads, as far as it shows.
fn classify(update: &Value) -> Class {
    let kind = update.get("kind").and_then(Value::as_str).unwrap_or("");
    let title = update.get("title").and_then(Value::as_str).unwrap_or("");
    let cmd = command(update);
    let text = format!("{title} {}", cmd.as_deref().unwrap_or(""));
    if PUSH.as_ref().is_some_and(|re| re.is_match(&text)) {
        return Class::Push;
    }
    match (kind, cmd) {
        ("edit" | "delete" | "move", _) => Class::Change,
        ("read" | "search" | "fetch" | "think" | "switch_mode", None) => Class::Read,
        (_, Some(cmd)) => {
            if crate::shell_readonly::is_read_only(&cmd) {
                Class::Read
            } else {
                Class::Change
            }
        }
        ("execute", None) => Class::Pending,
        _ => Class::Change,
    }
}

/// What one rule found, to be said at the next prompt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Fired {
    pub rule: &'static str,
    pub text: String,
}

#[derive(Default)]
struct State {
    /// This turn's tool calls by id.
    calls: HashMap<String, Class>,
    /// HEAD and branch at the last turn end seen.
    last: Option<(Option<String>, Option<String>)>,
    streak: u32,
    streak_tools: u32,
    spin_fired: bool,
    /// HEAD at the end of the last turn that ran a push.
    pushed_head: Option<String>,
    /// The HEAD the unpushed rule last spoke for.
    unpushed_said: Option<String>,
    pending: Vec<Fired>,
    said: u64,
    said_chars: u64,
}

static STATES: LazyLock<Mutex<HashMap<String, State>>> = LazyLock::new(Default::default);

fn with_state<T>(key: &str, f: impl FnOnce(&mut State) -> T) -> T {
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    if map.len() >= MAX_SESSIONS && !map.contains_key(key) {
        map.clear();
    }
    f(map.entry(key.to_owned()).or_default())
}

/// A `session/update` of the running turn of `key`.
pub(crate) fn note_tool(key: &str, update: &Value) {
    if !matches!(
        update.get("sessionUpdate").and_then(Value::as_str),
        Some("tool_call" | "tool_call_update")
    ) {
        return;
    }
    let Some(id) = update.get("toolCallId").and_then(Value::as_str).filter(|id| id.len() <= MAX_ID)
    else {
        return;
    };
    with_state(key, |st| match st.calls.get(id).copied() {
        None if st.calls.len() < MAX_CALLS => {
            st.calls.insert(id.to_owned(), classify(update));
        }
        None => {}
        Some(Class::Pending) if command(update).is_some() => {
            st.calls.insert(id.to_owned(), classify(update));
        }
        // A file-change call shows its hunk on a later update.
        Some(Class::Read)
            if update.get("content").and_then(Value::as_array).is_some_and(|blocks| {
                blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("diff"))
            }) =>
        {
            st.calls.insert(id.to_owned(), Class::Change);
        }
        Some(_) => {}
    });
}

/// A settled turn, as the rules read it.
#[derive(Default)]
pub(crate) struct End<'a> {
    pub completed: bool,
    pub head: Option<&'a str>,
    pub branch: Option<&'a str>,
    /// The session's starting HEAD (`SessionMeta::git_head`).
    pub initial_head: Option<&'a str>,
    /// Whether HEAD is a remote-tracking tip (`turn_git.rs` `gitHeadPushed`); `None`: not read.
    pub head_pushed: Option<bool>,
    /// The turn's last reply.
    pub draft: &'a str,
}

fn short(head: &str) -> &str {
    head.get(..12).unwrap_or(head)
}

/// Judges the turn of `key` that ended as `end`: what fires, if anything; puts the turn's
/// counters on `msg`.
pub(crate) fn end_with(key: &str, end: &End, msg: &mut Value) -> Vec<Fired> {
    let fired = with_state(key, |st| {
        let calls = std::mem::take(&mut st.calls);
        let tools = calls.len() as u32;
        let changes = calls.values().filter(|c| !matches!(c, Class::Read)).count();
        let pushed = calls.values().any(|c| *c == Class::Push);
        let now = (end.head.map(str::to_owned), end.branch.map(str::to_owned));
        let moved = match st.last.replace(now.clone()) {
            Some(last) => last != now,
            None => end.initial_head.is_some() && end.head != end.initial_head,
        };
        if pushed {
            st.pushed_head = now.0.clone();
        }
        let mut fired = Vec::new();
        if moved || changes > 0 {
            st.streak = 0;
            st.streak_tools = 0;
            st.spin_fired = false;
        } else if end.completed && tools >= SPIN_MIN_TOOLS {
            st.streak += 1;
            st.streak_tools = st.streak_tools.saturating_add(tools);
            if st.streak >= SPIN_TURNS && !st.spin_fired {
                st.spin_fired = true;
                fired.push(Fired {
                    rule: "spin",
                    text: format!(
                        "Your last {} turns ran {} tool calls and changed no file and no commit. \
                         If the task needs a change, make the smallest one now or say what blocks \
                         you; if this work is read-only on purpose, carry on.",
                        st.streak, st.streak_tools
                    ),
                });
            }
        }
        if let (true, Some(head), Some(initial), Some(false)) =
            (end.completed, end.head, end.initial_head, end.head_pushed)
            && head != initial
            && st.pushed_head.as_deref() != Some(head)
            && st.unpushed_said.as_deref() != Some(head)
            && claims_done(end.draft)
        {
            st.unpushed_said = Some(head.to_owned());
            fired.push(Fired {
                rule: "unpushed",
                text: format!(
                    "Your last reply said the work is done, but commit {} (made in this session) \
                     is on no remote branch and no push ran since it. Push it and open or update \
                     its PR, or say why it stays local.",
                    short(head)
                ),
            });
        }
        st.pending.extend(fired.iter().cloned());
        let said = (std::mem::take(&mut st.said), std::mem::take(&mut st.said_chars));
        (fired, said)
    });
    let (fired, (said, said_chars)) = fired;
    let add = |msg: &mut Value, c: &str, n: u64| {
        if n > 0 {
            super::harness_magic::add_counter(msg, FEATURE, c, n);
        }
    };
    add(msg, "observed", 1);
    for f in &fired {
        add(msg, &format!("{}Fired", f.rule), 1);
    }
    add(msg, "said", said);
    add(msg, "saidChars", said_chars);
    fired
}

fn line(f: &Fired) -> String {
    format!("[sidecar {}] {}", f.rule, f.text)
}

/// What the next prompt of `key` says: the lines the last turn's firings left, once.
pub(crate) fn start_with(key: &str) -> Option<String> {
    with_state(key, |st| {
        let pending = std::mem::take(&mut st.pending);
        if pending.is_empty() {
            return None;
        }
        let text = pending.iter().map(line).collect::<Vec<_>>().join("\n");
        st.said = st.said.saturating_add(pending.len() as u64);
        st.said_chars = st.said_chars.saturating_add(text.chars().count() as u64);
        Some(text)
    })
}

/// Whether the end of `session`'s running turn should read if HEAD is pushed (`turn_git.rs`):
/// only when the feature is on and the reply says done, so the walk of its remote refs runs
/// for those turns alone.
pub(super) fn wants_push_check(session: &Session) -> bool {
    let done = {
        let stream = session.stream.lock().unwrap_or_else(|e| e.into_inner());
        claims_done(&stream.trailing_text)
    };
    done && super::harness_magic::enabled(FEATURE)
}

impl Hub {
    /// A tool call update of the running turn (`stalled_turn.rs`).
    pub(super) fn sidecars_tool(&self, session: &Session, update: &Value) {
        note_tool(&session.id, update);
    }

    /// The line to add to `session`'s outgoing prompt, if a rule fired at the last turn's end.
    pub(super) fn sidecars_start(&self, session: &Session) -> Option<String> {
        if !super::harness_magic::enabled(FEATURE) {
            // Off: what an earlier firing left is dropped, not said later.
            with_state(&session.id, |st| st.pending.clear());
            return None;
        }
        start_with(&session.id)
    }

    /// Judges a settled turn (`turn_git.rs` `write_turn_result`), raising a `sidecar_notice`
    /// for each rule that fires.
    pub(super) fn sidecars_end(&self, session: &Session, msg: &mut Value) {
        if !super::harness_magic::enabled(FEATURE) {
            STATES.lock().unwrap_or_else(|e| e.into_inner()).remove(&session.id);
            return;
        }
        let completed = msg.get("status").and_then(Value::as_str) == Some("completed");
        let draft = if completed {
            session.stream.lock().unwrap_or_else(|e| e.into_inner()).trailing_text.clone()
        } else {
            String::new()
        };
        let initial = session.read_meta(|m| m.git_head.clone());
        let fired = {
            let head = msg.get("gitHead").and_then(Value::as_str).map(str::to_owned);
            let branch = msg.get("gitBranch").and_then(Value::as_str).map(str::to_owned);
            let end = End {
                completed,
                head: head.as_deref(),
                branch: branch.as_deref(),
                initial_head: initial.as_deref(),
                head_pushed: msg.get("gitHeadPushed").and_then(Value::as_bool),
                draft: &draft,
            };
            end_with(&session.id, &end, msg)
        };
        let turn = msg.get("turnId").cloned().unwrap_or(Value::Null);
        for f in fired {
            tracing::info!(target: "acpmux::sidecars", rule = f.rule, session = %session.id, "sidecar fired");
            self.append(
                session,
                "mux",
                "sidecar_notice",
                json!({"rule": f.rule, "text": f.text, "turnId": turn}),
            );
        }
    }
}

#[cfg(test)]
#[path = "sidecars_turn_tests.rs"]
mod tests;
