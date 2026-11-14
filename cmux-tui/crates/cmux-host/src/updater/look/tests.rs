use super::*;
use serde_json::json;

const T: u64 = 1_794_600_000_000;
const A: &str = "0123456789abcdef0123456789abcdef01234567";

// The lead (2026-11-13): "machine id and updater outcome (seen, held with
// reason, busy with reason, swapped) in sawBuild, so the slow mode gets
// read instead of inferred."
#[test]
fn a_run_keeps_when_it_saw_the_build_and_its_last_wait_past_the_swap() {
    let l = Look::next(None, Seen::Current, T);
    assert_eq!(l.to_json(), json!({"outcome": "current", "at": T}));
    let l = Look::next(Some(l), Seen::Busy("turn".into()), T + 15_000);
    let l = Look::next(Some(l), Seen::Failed, T + 30_000);
    let l = Look::next(Some(l), Seen::Held("connect-hold".into()), T + 45_000);
    assert_eq!(
        l.to_json(),
        json!({"outcome": "held", "reason": "connect-hold", "at": T + 45_000,
                   "seen_at": T + 15_000, "waited": "held:connect-hold"})
    );
    let l = Look::next(Some(l), Seen::Swapped(A.into()), T + 60_000);
    let l = Look::next(Some(l), Seen::Current, T + 90_000);
    assert_eq!(
        l.to_json(),
        json!({"outcome": "current", "at": T + 90_000, "seen_at": T + 15_000,
                   "waited": "held:connect-hold",
                   "swapped": {"commit": "0123456789ab", "at": T + 60_000}})
    );
    // The next build's run starts anew: its own seen_at, no wait yet.
    let l = Look::next(Some(l), Seen::Swapped("ba9876543210ff".into()), T + 120_000);
    assert_eq!(l.seen_at, Some(T + 120_000));
    assert_eq!(l.waited, None);
    assert_eq!(l.swapped, Some(Swap { commit: "ba9876543210".into(), at: T + 120_000 }));
}

#[test]
fn a_busy_check_reports_what_held_it_never_the_session_names() {
    let s = |items: &[&str]| busy_seen(&items.iter().map(|i| i.to_string()).collect::<Vec<_>>());
    assert_eq!(s(&["connect hold, 90 s left"]), Seen::Held("connect-hold".into()));
    assert_eq!(s(&["alice's secret chat"]), Seen::Busy("turn".into()));
    assert_eq!(
        s(&["fix the build", "1 carrier session(s) attached, held at most 600 s more"]),
        Seen::Busy("carrier+turn".into())
    );
    assert_eq!(
        s(&["carrier sessions unknown (no answer within 2 s inside the gate)"]),
        Seen::Busy("carrier".into())
    );
    assert_eq!(s(&["acpmux ls is unreadable"]), Seen::Busy("unread".into()));
    assert_eq!(
        s(&["no acpmux daemon answered, its unit is Some(\"activating\")"]),
        Seen::Busy("unread".into())
    );
    let l = Look::next(None, s(&["alice's secret chat"]), T);
    assert!(!l.to_json().to_string().contains("alice"));
}

#[test]
fn a_pending_update_names_the_swap_its_check_did_not_save() {
    let busy = Look::next(None, Seen::Busy("turn".into()), T);
    let l = Look::with_pending(Some(busy), A, T + 20_000);
    assert_eq!(l.outcome, "swapped");
    assert_eq!(l.seen_at, Some(T));
    assert_eq!(l.waited.as_deref(), Some("busy:turn"));
    assert_eq!(l.swapped, Some(Swap { commit: "0123456789ab".into(), at: T + 20_000 }));
    // A look that saved the swap is kept as it is.
    let later = Look::next(Some(l), Seen::Failed, T + 40_000);
    assert_eq!(Look::with_pending(Some(later.clone()), A, T + 20_000), later);
    // A machine whose updater never checked before the flip.
    assert_eq!(Look::with_pending(None, A, T).seen_at, Some(T));
}

#[test]
fn report_reads_the_state_and_the_pending_file() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    assert_eq!(report(&paths), None);
    let state = super::super::State {
        look: Some(Look::next(None, Seen::Busy("turn".into()), T)),
        ..Default::default()
    };
    super::super::save_state(&paths, &state).unwrap();
    assert_eq!(
        report(&paths),
        Some(
            json!({"outcome": "busy", "reason": "turn", "at": T, "seen_at": T, "waited": "busy:turn"})
        )
    );
    let pending = super::super::Pending {
        from: 1,
        to: 2,
        commit: A.into(),
        committed_at: 0,
        cmux_tui: String::new(),
        cmux_tui_hook: String::new(),
        old_cmux_tui: String::new(),
        started_at: T / 1000 + 20,
    };
    super::super::save_pending(&paths, &pending).unwrap();
    let block = report(&paths).unwrap();
    assert_eq!(block["outcome"], "swapped");
    assert_eq!(block["swapped"], json!({"commit": "0123456789ab", "at": T + 20_000}));
    // The key leaves the time out: the same outcome later makes no report.
    let mut moved = block.clone();
    moved["at"] = json!(T + 99_000);
    assert_eq!(report_key(&Some(block)), report_key(&Some(moved)));
}
