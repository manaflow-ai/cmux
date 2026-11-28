use super::*;
use serde_json::{Value, json};

fn hint(value: Value) -> Hint {
    serde_json::from_value(value).unwrap()
}

fn focus(machine: &str) -> Hint {
    hint(json!({
        "v": 1, "machine": machine, "signal": "focus",
        "enabled": true, "allowed": true, "loaded": true, "status": "paused",
    }))
}

#[test]
fn a_hint_wakes_only_a_paused_machine_and_only_when_enabled() {
    let mut hints = WakeHints::default();
    assert_eq!(hints.hint(&focus("m"), 0), HintDecision::Resume);

    let mut off = focus("a");
    off.enabled = false;
    assert_eq!(hints.hint(&off, 0), HintDecision::Skip("disabled"));

    // An awake machine is never touched, so its idle timer is never extended.
    for status in ["running", "starting", "pausing"] {
        let mut awake = focus("b");
        awake.status = Some(status.into());
        assert_eq!(hints.hint(&awake, 0), HintDecision::Skip("notPaused"), "{status}");
    }
    let mut unloaded = focus("c");
    unloaded.loaded = false;
    assert_eq!(hints.hint(&unloaded, 0), HintDecision::Skip("notLoaded"));
}

#[test]
fn every_raw_signal_counts_and_an_unknown_one_is_skipped() {
    for signal in ["focus", "terminal", "unlock"] {
        let mut hints = WakeHints::default();
        let h = hint(json!({"v": 1, "machine": "m", "signal": signal, "enabled": true,
            "allowed": true, "loaded": true, "status": "paused"}));
        assert_eq!(hints.hint(&h, 0), HintDecision::Resume, "{signal}");
    }
    let mut hints = WakeHints::default();
    let future = hint(json!({"v": 1, "machine": "m", "signal": "gaze", "enabled": true,
        "allowed": true, "loaded": true, "status": "paused"}));
    assert_eq!(hints.hint(&future, 0), HintDecision::Skip("unknownSignal"));
}

#[test]
fn old_and_new_senders_both_read() {
    let mut hints = WakeHints::default();
    // No version: an old sender's typing-prewarm shape is not a wake hint.
    let old = hint(
        json!({"machine": "m", "enabled": true, "allowed": true, "loaded": true, "status": "paused"}),
    );
    assert_eq!(hints.hint(&old, 0), HintDecision::Skip("noVersion"));
    // A newer sender adds fields; its known ones still decide.
    let newer =
        hint(json!({"v": 2, "machine": "m", "signal": "focus", "enabled": true, "allowed": true,
        "loaded": true, "status": "paused", "confidence": 0.9}));
    assert_eq!(hints.hint(&newer, 0), HintDecision::Resume);
}

#[test]
fn hints_are_debounced_and_capped_per_machine() {
    let mut hints = WakeHints::default();
    let mut t = 0;
    for _ in 0..MAX_HINT_WAKES {
        assert_eq!(hints.hint(&focus("m"), t), HintDecision::Resume);
        assert!(hints.hint(&focus("m"), t + 1).eq(&HintDecision::Skip("inFlight")));
        hints.resumed("m", true, t + 10);
        assert_eq!(hints.hint(&focus("m"), t + 20), HintDecision::Skip("debounced"));
        // Not used: re-paused at the bound.
        let due = t + 10 + IDLE_BOUND_MS;
        assert!(matches!(hints.idle("m", Some("running"), due), IdleDecision::Pause { .. }));
        t = due + DEBOUNCE_MS;
    }
    assert_eq!(hints.hint(&focus("m"), t), HintDecision::Skip("capped"));
    // Another machine has its own cap.
    assert_eq!(hints.hint(&focus("other"), t), HintDecision::Resume);
    // The window slides.
    assert_eq!(hints.hint(&focus("m"), CAP_WINDOW_MS + DEBOUNCE_MS), HintDecision::Resume);
}

#[test]
fn a_failed_resume_cools_down_like_the_typing_prewarm() {
    let mut hints = WakeHints::default();
    assert_eq!(hints.hint(&focus("m"), 0), HintDecision::Resume);
    assert_eq!(hints.resumed("m", false, 100), None);
    let soon = 100 + decide::PREWARM_RETRY_AFTER_MS - 1;
    assert_eq!(hints.hint(&focus("m"), soon), HintDecision::Skip("coolingDown"));
    assert_eq!(hints.hint(&focus("m"), soon + 1), HintDecision::Resume);
}

#[test]
fn a_hint_wake_with_no_input_pauses_again_and_counts_false() {
    let mut hints = WakeHints::default();
    hints.hint(&focus("m"), 0);
    assert_eq!(hints.resumed("m", true, 3_000), Some(IDLE_BOUND_MS));
    // Still restoring: the bound counts from running, not from the answer.
    assert_eq!(
        hints.idle("m", Some("starting"), 10_000),
        IdleDecision::Wait { check_after_ms: IDLE_BOUND_MS }
    );
    assert_eq!(
        hints.idle("m", Some("running"), 13_000),
        IdleDecision::Wait { check_after_ms: 20_000 }
    );
    assert_eq!(
        hints.idle("m", Some("running"), 33_000),
        IdleDecision::Pause { outcome: Outcome::False { signal: Signal::Focus, awake_ms: 30_000 } }
    );
    // Once.
    assert_eq!(hints.idle("m", Some("running"), 40_000), IdleDecision::Done);
}

#[test]
fn input_after_a_hint_wake_counts_used_and_ends_the_idle_check() {
    let mut hints = WakeHints::default();
    hints.hint(&focus("m"), 0);
    hints.resumed("m", true, 3_000);
    assert_eq!(
        hints.input("m", 5_500),
        Some(Outcome::Used { signal: Signal::Focus, lead_ms: 2_500 })
    );
    assert_eq!(hints.input("m", 6_000), None);
    assert_eq!(hints.idle("m", Some("running"), 60_000), IdleDecision::Done);
}

#[test]
fn a_machine_paused_by_someone_else_ends_the_check_without_a_pause() {
    let mut hints = WakeHints::default();
    hints.hint(&focus("m"), 0);
    hints.resumed("m", true, 1_000);
    assert_eq!(hints.idle("m", Some("paused"), 40_000), IdleDecision::Done);
    // A machine no hint woke is never paused by this rule.
    assert_eq!(hints.idle("never", Some("running"), 40_000), IdleDecision::Done);
}

#[test]
fn answers_serialize_as_the_app_reads_them() {
    let pause = IdleDecision::Pause {
        outcome: Outcome::False { signal: Signal::Terminal, awake_ms: 30_000 },
    };
    assert_eq!(
        serde_json::to_value(pause).unwrap(),
        json!({"do": "pause", "outcome": {"tag": "false", "signal": "terminal", "awakeMs": 30_000}})
    );
    let used = Outcome::Used { signal: Signal::Unlock, lead_ms: 1 };
    assert_eq!(
        serde_json::to_value(used).unwrap(),
        json!({"tag": "used", "signal": "unlock", "leadMs": 1})
    );
    assert_eq!(
        serde_json::to_value(IdleDecision::Wait { check_after_ms: 5 }).unwrap(),
        json!({"do": "wait", "checkAfterMs": 5})
    );
}

/// RFD 0144: "Opening a chat, scrolling it, browsing its files and checking on it from the phone
/// leave the list." With the chat served from the daemon's copy, opening it wakes nothing; a
/// terminal and the composer's first key still do.
#[test]
fn a_chat_read_without_the_machine_is_no_wake() {
    let opens = |reads: bool| {
        let mut hints = WakeHints::default();
        let mut wakes = 0;
        // Ten opens of ten paused chats, a minute apart (no debounce, no cap in play).
        for i in 0..10u64 {
            let mut h = focus(&format!("m{i}"));
            h.reads_without_wake = reads;
            if hints.hint(&h, i * 60_000) == HintDecision::Resume {
                wakes += 1;
            }
        }
        wakes
    };
    assert_eq!(opens(false), 10, "today: every open of a paused chat wakes its machine");
    assert_eq!(opens(true), 0, "read from the copy: no open wakes one");

    let mut hints = WakeHints::default();
    for (signal, want) in [
        ("focus", HintDecision::Skip("readsWithoutWake")),
        ("unlock", HintDecision::Skip("readsWithoutWake")),
        ("terminal", HintDecision::Resume),
    ] {
        let h = hint(json!({"v": 1, "machine": signal, "signal": signal, "enabled": true,
            "allowed": true, "loaded": true, "status": "paused", "readsWithoutWake": true}));
        assert_eq!(hints.hint(&h, 0), want, "{signal}");
    }
    // An older shell sends no such fact: its focus wakes as before.
    let old = hint(json!({"v": 1, "machine": "old", "signal": "focus", "enabled": true,
        "allowed": true, "loaded": true, "status": "paused"}));
    assert_eq!(hints.hint(&old, 0), HintDecision::Resume);
}
