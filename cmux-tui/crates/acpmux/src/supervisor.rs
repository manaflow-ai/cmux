//! The session supervisor's decision: what to do about a session that ended, from its exit
//! record (RFD 0177 §4, build 6, in cmuxterm-hq `docs/rfd/0177-kernel-proc-lifecycle.md`).
//!
//! Leo, 2026-11-24: "also try to fix up whateve occured that closed the lanes when they weren't
//! finished? we need to be more persistent somehow when agents die but they have important work".
//!
//! OTP's supervisor taken wholesale, adapted where an agent differs from a process:
//!
//! - **Restart type from owned work** ([`restart_type`]). A session whose exit owns an open PR,
//!   a goal or a role is `permanent`; one that crashed, was killed or dropped is `transient`
//!   (restarted only after an abnormal exit, so a drop is left down); one whose closer said
//!   `done` is `temporary` (never restarted).
//! - **Intensity in restarts and tokens** ([`Intensity`]). At most `max_restarts` restarts and
//!   `max_tokens` tokens in `window_ms`; past either, the failure escalates to the parent
//!   instead of looping (today's `auto_resume_exhausted` escalates to nobody).
//! - **Restart means resume**: the decision names the transcript to resume from; a caller that
//!   finds the transcript itself is the poison falls back to a fresh session handed a summary.
//!
//! The policy: at most 3 restarts in a 6 h window; a session that owns open work is restarted
//! first; past the limit its owner is handed it. Pure: no hub, no clock.
//! `hub/exit_notify.rs` logs the decision next to the exit record when `ACPMUX_SUPERVISOR=1`
//! (default off); nothing acts on it yet.

use crate::exit_record::{ExitClass, ExitRecord};
use serde::Serialize;

/// The event kind the decision is logged as, in the ended session's chat.
pub const KIND: &str = "supervisor_decision";

/// Whether decisions are logged (`ACPMUX_SUPERVISOR=1` turns it on; off by default).
pub fn enabled() -> bool {
    std::env::var("ACPMUX_SUPERVISOR").is_ok_and(|v| v.trim() == "1")
}

/// OTP's child restart types.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RestartType {
    /// Always restarted: it owns work someone waits on.
    Permanent,
    /// Restarted only after an abnormal exit (crashed or killed).
    Transient,
    /// Never restarted: its work is done.
    Temporary,
}

/// The restart type of the session `rec` records (module docs).
pub fn restart_type(rec: &ExitRecord) -> RestartType {
    match rec.class {
        ExitClass::Done => RestartType::Temporary,
        _ if rec.owned.any() => RestartType::Permanent,
        ExitClass::Crashed | ExitClass::Killed | ExitClass::Dropped => RestartType::Transient,
    }
}

/// Whether the exit was abnormal: the session's work was cut, not finished or let go.
fn abnormal(class: ExitClass) -> bool {
    matches!(class, ExitClass::Crashed | ExitClass::Killed)
}

/// The intensity limit: OTP's `MaxR` restarts in `MaxT`, plus a token budget in the same window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Intensity {
    pub max_restarts: u32,
    pub window_ms: u64,
    pub max_tokens: u64,
}

impl Default for Intensity {
    /// 3 restarts in 6 h, and a token budget a crash loop would pass.
    fn default() -> Self {
        Self { max_restarts: 3, window_ms: 6 * 3600 * 1000, max_tokens: 2_000_000 }
    }
}

/// One earlier restart of the same session: when, and the tokens its run used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Restart {
    pub at_ms: u64,
    pub tokens: u64,
}

/// What the supervisor does about one exit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Decision {
    /// Resume the session from its transcript.
    Restart { transcript: Option<String> },
    /// Leave it down: nothing waits on it.
    Leave { why: &'static str },
    /// Past the intensity limit: hand the failure to the parent (none named: to nobody, said).
    Escalate { to: Option<String>, why: String },
}

/// The decision for `rec`, ended at `now_ms` with its last run having used `tokens`, given its
/// earlier `restarts` and the `parent` it escalates to.
pub fn decide(
    rec: &ExitRecord,
    now_ms: u64,
    tokens: u64,
    restarts: &[Restart],
    limit: Intensity,
    parent: Option<&str>,
) -> Decision {
    let kind = restart_type(rec);
    match kind {
        RestartType::Temporary => return Decision::Leave { why: "done" },
        RestartType::Transient if !abnormal(rec.class) => {
            return Decision::Leave { why: "normal exit" };
        }
        _ => {}
    }
    let since = now_ms.saturating_sub(limit.window_ms);
    let recent = restarts.iter().filter(|r| r.at_ms >= since);
    let (count, spent) =
        recent.fold((0u32, tokens), |(n, t), r| (n + 1, t.saturating_add(r.tokens)));
    let window_min = limit.window_ms / 60_000;
    let why = if count >= limit.max_restarts {
        Some(format!("{count} restarts in {window_min} min (max {})", limit.max_restarts))
    } else if spent > limit.max_tokens {
        Some(format!("{spent} tokens in {window_min} min (max {})", limit.max_tokens))
    } else {
        None
    };
    match why {
        Some(why) => Decision::Escalate { to: parent.map(str::to_owned), why },
        None => Decision::Restart { transcript: rec.transcript.clone() },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::close_why::{CloseActor, CloseRecord};
    use crate::exit_record::Owned;

    fn rec(class: ExitClass, prs: &[&str]) -> ExitRecord {
        ExitRecord {
            session: "s1".into(),
            name: "lane-a".into(),
            class,
            close: CloseRecord {
                closed_at: 10,
                actor: CloseActor { kind: "ttl".into(), ..Default::default() },
                reason: "idle".into(),
                outcome: class.as_str().into(),
            },
            owned: Owned {
                prs: prs.iter().map(|s| (*s).to_owned()).collect(),
                folder: "/w/lane-a".into(),
                ..Default::default()
            },
            transcript: Some("t-1".into()),
            harness: "claude".into(),
        }
    }

    const H: u64 = 3600 * 1000;

    #[test]
    fn the_restart_type_follows_owned_work() {
        assert_eq!(restart_type(&rec(ExitClass::Killed, &["cmux#1"])), RestartType::Permanent);
        assert_eq!(restart_type(&rec(ExitClass::Dropped, &["cmux#1"])), RestartType::Permanent);
        assert_eq!(restart_type(&rec(ExitClass::Crashed, &[])), RestartType::Transient);
        assert_eq!(restart_type(&rec(ExitClass::Dropped, &[])), RestartType::Transient);
        assert_eq!(restart_type(&rec(ExitClass::Done, &["cmux#1"])), RestartType::Temporary);
        let mut goal = rec(ExitClass::Killed, &[]);
        goal.owned.goal = Some("land it".into());
        assert_eq!(restart_type(&goal), RestartType::Permanent);
    }

    #[test]
    fn a_crash_resumes_its_transcript_and_a_normal_exit_stays_down() {
        let d = |r: &ExitRecord| decide(r, 10 * H, 0, &[], Intensity::default(), Some("coord"));
        let resume = Decision::Restart { transcript: Some("t-1".into()) };
        assert_eq!(d(&rec(ExitClass::Crashed, &[])), resume);
        assert_eq!(d(&rec(ExitClass::Killed, &["cmux#1"])), resume);
        assert_eq!(d(&rec(ExitClass::Dropped, &["cmux#1"])), resume);
        assert_eq!(d(&rec(ExitClass::Dropped, &[])), Decision::Leave { why: "normal exit" });
        assert_eq!(d(&rec(ExitClass::Done, &["cmux#1"])), Decision::Leave { why: "done" });
    }

    #[test]
    fn past_max_restarts_in_the_window_it_escalates_to_the_parent() {
        let r = rec(ExitClass::Crashed, &["cmux#1"]);
        let lim = Intensity::default();
        let two = [Restart { at_ms: 9 * H, tokens: 0 }, Restart { at_ms: 9 * H + 1, tokens: 0 }];
        assert!(matches!(
            decide(&r, 10 * H, 0, &two, lim, Some("coord")),
            Decision::Restart { .. }
        ));
        let three = [two[0], two[1], Restart { at_ms: 9 * H + 2, tokens: 0 }];
        let Decision::Escalate { to, why } = decide(&r, 10 * H, 0, &three, lim, Some("coord"))
        else {
            panic!("expected escalate")
        };
        assert_eq!(to.as_deref(), Some("coord"));
        assert!(why.starts_with("3 restarts in 360 min"), "{why}");
        // Restarts older than the window no longer count.
        let old = [Restart { at_ms: H, tokens: 0 }; 3];
        assert!(matches!(decide(&r, 10 * H, 0, &old, lim, None), Decision::Restart { .. }));
    }

    #[test]
    fn tokens_burned_in_the_window_escalate_like_a_crash_loop() {
        let r = rec(ExitClass::Killed, &[]);
        let lim = Intensity { max_tokens: 1000, ..Intensity::default() };
        let one = [Restart { at_ms: 9 * H, tokens: 600 }];
        assert!(matches!(decide(&r, 10 * H, 300, &one, lim, None), Decision::Restart { .. }));
        let d = decide(&r, 10 * H, 500, &one, lim, None);
        let Decision::Escalate { to: None, why } = d else { panic!("expected escalate: {d:?}") };
        assert!(why.starts_with("1100 tokens"), "{why}");
    }

    #[test]
    fn the_decision_serializes_with_its_action() {
        let v = serde_json::to_value(Decision::Escalate { to: Some("c".into()), why: "x".into() })
            .unwrap();
        assert_eq!(v, serde_json::json!({"action": "escalate", "to": "c", "why": "x"}));
    }
}
