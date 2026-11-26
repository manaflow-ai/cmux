//! Part of `Hub`; see `hub/mod.rs`. Deterministic sidecars (RFD 0158 §2): rules over the tool
//! stream that cost no tokens and steer the agent once when it is plainly wasting turns. The
//! first rule is polling: the same status-shaped command (`gh pr checks`, `git fetch`,
//! `curl …/status`, `sleep N`) run again and again in one turn with nothing edited between,
//! where one background wait that notifies on exit would do.
//!
//! Leo, 2026-11-26: "Ok well we can't be letting important rfds like that take breaks unless I
//! put in fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! Off unless `agents.harnessMagic.sidecars.enabled` is `true` (an opinionated nudge, like
//! surgery and dedupe; Leo 2026-11-26: "only do it for our personal fleet situation"), and
//! `ACPMUX_HM_SIDECARS=0` kills it. It fires at most once per rule per turn, steers only into a
//! steerable turn (otherwise drops: a stale nudge on the next prompt helps no one), and fails
//! open: a missing command, an unknown tool shape or a lost lock does nothing. The turn's
//! `turn_result` carries `harnessMagic.sidecars.{polling,steered}`.

use super::*;
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex as StdMutex};

pub(super) const FEATURE: &str = "sidecars";
/// Runs of one wait-shaped command, or of any `sleep N`, before the rule fires.
const REPEATS: u32 = 3;
const MAX_KEY: usize = 300;
/// Call ids remembered per turn (first sight only); past it the turn stops counting.
const MAX_SEEN: usize = 512;

static WAIT_SHAPED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\bsleep\s+#|\bwatch\b|\bgh\s+(pr|run|api|workflow)\b|\bgit\s+(fetch|status|log|ls-remote)\b|\bcurl\b|\bstatus\b|\bchecks?\b|\bwait\b|\bpoll",
    )
    .expect("wait regex")
});
static SLEEP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\bsleep\s+#").expect("sleep regex"));
static DIGITS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\d+").expect("digits regex"));

/// The command a repeat is counted by: spaces squashed, digit runs `#` (a PR number, a sleep
/// length, a timestamp), cut to [`MAX_KEY`] bytes.
pub(super) fn normalize(command: &str) -> String {
    let squashed = command.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut key = DIGITS.replace_all(&squashed, "#").into_owned();
    if key.len() > MAX_KEY {
        let mut cut = MAX_KEY;
        while !key.is_char_boundary(cut) {
            cut -= 1;
        }
        key.truncate(cut);
    }
    key
}

/// One session's rule state for its current turn.
#[derive(Default)]
pub(super) struct Rules {
    turn: String,
    seen: HashSet<String>,
    runs: HashMap<String, u32>,
    sleeps: u32,
    fired: bool,
    /// This turn's counters, taken by the `turn_result`.
    polling: u64,
    steered: u64,
}

impl Rules {
    fn on_turn(&mut self, turn: &str) {
        if self.turn != turn {
            *self = Rules { turn: turn.to_owned(), ..Rules::default() };
        }
    }

    /// Feeds one tool update of `turn`; `Some(text)` when the polling rule fires.
    pub(super) fn observe(&mut self, turn: &str, update: &Value) -> Option<String> {
        self.on_turn(turn);
        let (paths, edited) = crate::touched_files::paths_of(update);
        if edited == Some(true) && !paths.is_empty() {
            self.runs.clear();
            self.sleeps = 0;
            return None;
        }
        let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or_default();
        if self.fired || id.is_empty() || self.seen.contains(id) || self.seen.len() >= MAX_SEEN {
            return None;
        }
        let command = super::claim_check::command(update)?;
        self.seen.insert(id.to_owned());
        let key = normalize(&command);
        if !WAIT_SHAPED.is_match(&key) {
            return None;
        }
        let n = self.runs.entry(key.clone()).or_default();
        *n += 1;
        let n = *n;
        if SLEEP.is_match(&key) {
            self.sleeps += 1;
        }
        if n < REPEATS && self.sleeps < REPEATS {
            return None;
        }
        self.fired = true;
        let shown: String = command.split_whitespace().collect::<Vec<_>>().join(" ");
        let shown: String = shown.chars().take(120).collect();
        let what = if n >= REPEATS {
            format!("`{shown}` ran {n} times this turn with nothing edited between")
        } else {
            format!("{} `sleep` waits ran this turn with nothing edited between", self.sleeps)
        };
        Some(format!(
            "[sidecar] polling: {what}. Start the wait once in the background (a task that \
             notifies you when it exits, or the harness's wait tool), then end the turn; you are \
             woken when it finishes."
        ))
    }

    pub(super) fn take(&mut self) -> (u64, u64) {
        (std::mem::take(&mut self.polling), std::mem::take(&mut self.steered))
    }
}

static STATES: LazyLock<StdMutex<HashMap<String, Rules>>> = LazyLock::new(Default::default);

fn with<R>(session: &str, f: impl FnOnce(&mut Rules) -> R) -> R {
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    if map.len() > 1000 && !map.contains_key(session) {
        map.retain(|_, r| r.polling > 0 || r.steered > 0);
    }
    f(map.entry(session.to_owned()).or_default())
}

/// Puts this turn's counters on its `turn_result` (none when the rule never fired).
pub(super) fn stamp(session: &str, msg: &mut Value) {
    let (polling, steered) = {
        let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
        map.get_mut(session).map(Rules::take).unwrap_or_default()
    };
    if polling > 0 {
        super::harness_magic::add_counter(msg, FEATURE, "polling", polling);
        super::harness_magic::add_counter(msg, FEATURE, "steered", steered);
    }
}

#[cfg(test)]
pub(super) fn forget(session: &str) {
    STATES.lock().unwrap_or_else(|e| e.into_inner()).remove(session);
}

impl Hub {
    /// One tool update through the sidecar rules; steers the turn when a rule fires.
    pub(super) fn note_sidecars(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        if !matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        ) || tokio::runtime::Handle::try_current().is_err()
        {
            return;
        }
        let Some(turn) = session.turn() else { return };
        let Some(text) = with(&session.id, |r| r.observe(&turn.turn_id, update)) else { return };
        // The settings file is read only when a rule would fire, never per tool call.
        if !super::harness_magic::enabled(FEATURE) {
            return;
        }
        with(&session.id, |r| r.polling += 1);
        if !session.steering.load(Ordering::SeqCst) {
            return;
        }
        let notice =
            json!({"sender": "acpmux sidecar", "severity": "info", "title": "polling in the turn"});
        let rendered = crate::prompt_provenance::notice_text(&notice, &text);
        let mut provenance = crate::prompt_provenance::notice(&notice, &session.id);
        if let Some(o) = provenance.as_object_mut() {
            o.insert("kind".into(), json!(super::touched::NOTICE_KIND));
            o.insert("sidecar".into(), json!("polling"));
        }
        let opts = PromptOptions {
            prompt_id: Some(format!("sidecar-{}-{}", turn.turn_id, uuid::Uuid::now_v7())),
            resend: true,
            steer_only: true,
            interrupt_turn: Some(turn.turn_id.clone()),
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": rendered})];
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_named("sidecar-notice", async move {
            if hub.prompt_with(&session, blocks, "acpmux", true, opts).await.is_ok() {
                with(&session.id, |r| r.steered += 1);
            }
        });
    }
}

#[cfg(test)]
#[path = "sidecars_tests.rs"]
mod tests;
