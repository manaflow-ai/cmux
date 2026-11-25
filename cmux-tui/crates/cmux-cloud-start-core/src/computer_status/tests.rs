use super::*;
use serde_json::json;

fn facts(value: serde_json::Value) -> Facts {
    serde_json::from_value(value).unwrap()
}

fn phase_of(value: serde_json::Value) -> Phase {
    status(&facts(value)).phase
}

#[test]
fn a_chat_that_simply_runs_shows_no_status_line_and_auto_rows() {
    let status = status(&facts(json!({"session_id": "s1"})));
    assert_eq!(
        serde_json::to_value(&status).unwrap(),
        json!({
            "session_id": "s1",
            "home": "this_mac",
            "phase": "running",
            "size": {"mode": "auto"},
            "sleep": {"mode": "auto"}
        })
    );
}

#[test]
fn a_hybrid_start_booting_is_preparing_while_the_model_answers_here() {
    let status = status(&facts(json!({
        "session_id": "s1",
        "hybrid": {"cloud": "booting", "sinceMs": 1_000}
    })));
    assert_eq!((status.phase, status.home), (Phase::Preparing, Home::ThisMac));
    assert_eq!(status.phase_since_ms, Some(1_000));
    assert_eq!(phase_of(json!({"hybrid": {"cloud": "ready"}})), Phase::Preparing);
}

#[test]
fn a_move_in_flight_is_moving_and_cancellable() {
    let status = status(&facts(json!({
        "move": {"direction": "to_cloud", "since_ms": 5, "cancellable": true}
    })));
    assert_eq!(status.phase, Phase::Moving);
    assert_eq!(status.phase_since_ms, Some(5));
    assert_eq!(
        status.move_,
        Some(Move { direction: Direction::ToCloud, cancellable: true, failure: None })
    );
}

#[test]
fn a_hybrid_start_moving_is_moving_to_cloud_and_not_cancellable() {
    let status = status(&facts(json!({"hybrid": {"cloud": "moving", "sinceMs": 9}})));
    assert_eq!(status.phase, Phase::Moving);
    assert_eq!(
        status.move_.map(|m| (m.direction, m.cancellable)),
        Some((Direction::ToCloud, false))
    );
}

#[test]
fn a_move_that_failed_stays_where_it_was() {
    let status = status(&facts(json!({
        "home": "cloud",
        "move": {"direction": "to_mac", "cancellable": true, "failure": "network_dropped"}
    })));
    assert_eq!((status.phase, status.home), (Phase::MoveFailed, Home::Cloud));
    let shown = status.move_.unwrap();
    assert_eq!(shown.failure, Some(MoveFailure::NetworkDropped));
    assert!(!shown.cancellable, "a stopped move has nothing to cancel");
    // A hybrid start whose machine failed keeps the chat here.
    let status = status_of_hybrid_failure("connection reset");
    assert_eq!((status.phase, status.home), (Phase::MoveFailed, Home::ThisMac));
    assert_eq!(status.move_.unwrap().failure, Some(MoveFailure::NetworkDropped));
    assert_eq!(
        status_of_hybrid_failure("cloud.spend_cap.reached").move_.unwrap().failure,
        Some(MoveFailure::Refused)
    );
    assert_eq!(status_of_hybrid_failure("boom").move_.unwrap().failure, Some(MoveFailure::Other));
}

fn status_of_hybrid_failure(reason: &str) -> ComputerStatus {
    status(&facts(json!({"hybrid": {"cloud": "failed", "reason": reason}})))
}

#[test]
fn an_unknown_failure_word_reads_as_other() {
    let move_: MoveFacts = serde_json::from_value(json!({"failure": "cosmic_ray"})).unwrap();
    assert_eq!(move_.failure, Some(MoveFailure::Other));
}

#[test]
fn a_dropped_link_is_reconnecting() {
    let status = status(&facts(json!({"home": "peer", "reconnecting_since_ms": 42})));
    assert_eq!(
        (status.phase, status.home, status.phase_since_ms),
        (Phase::Reconnecting, Home::Peer, Some(42))
    );
}

#[test]
fn an_idle_pause_in_cloud_is_sleeping_and_keeps_its_shape() {
    let status = status(&facts(json!({
        "home": "cloud",
        "machine": {"shape": {"vcpu": 2.0, "memory_gib": 4.0}, "paused_by": "idle", "paused_since_ms": 7}
    })));
    assert_eq!((status.phase, status.phase_since_ms), (Phase::Sleeping, Some(7)));
    assert_eq!(status.shape, Some(Shape { vcpu: 2.0, memory_gib: 4.0 }));
    // Any other server pause word is an idle pause too.
    let other = json!({"home": "cloud", "machine": {"paused_by": "user"}});
    assert_eq!(phase_of(other), Phase::Sleeping);
}

#[test]
fn the_spend_cap_pauses_a_cloud_chat_and_says_why() {
    let status = status(&facts(json!({
        "home": "cloud",
        "machine": {"paused_by": "spend_cap", "paused_since_ms": 100},
        "move": {"direction": "to_mac", "cancellable": true}
    })));
    assert_eq!(status.phase, Phase::PausedSpendCap);
    assert_eq!(status.why, Some(Why { at_ms: 100, reason: Reason::SpendCap, command: None }));
    assert_eq!(status.move_, None);
    let pool = json!({"home": "cloud", "machine": {"paused_by": "pool_spent"}});
    assert_eq!(phase_of(pool), Phase::PausedPoolSpent);
}

#[test]
fn a_local_chat_keeps_running_past_the_spend_cap() {
    let local = json!({"home": "this_mac", "machine": {"paused_by": "spend_cap"}});
    assert_eq!(phase_of(local), Phase::Running);
}

#[test]
fn slots_full_keeps_the_chat_on_this_mac() {
    let status = status(&facts(json!({
        "refusal": {"code": "cloud.quota.exceeded", "at_ms": 3}
    })));
    assert_eq!((status.phase, status.home), (Phase::StayingLocalSlotsFull, Home::ThisMac));
    assert_eq!(status.why.map(|why| why.reason), Some(Reason::SlotsFull));
    let hybrid = json!({"hybrid": {"cloud": "failed", "reason": "cloud.quota.exceeded"}});
    assert_eq!(phase_of(hybrid), Phase::StayingLocalSlotsFull);
    // Another refusal is no slots-full line.
    assert_eq!(phase_of(json!({"refusal": {"code": "cloud.plan.required"}})), Phase::Running);
}

#[test]
fn a_committed_hybrid_start_lives_in_cloud() {
    let status = status(&facts(json!({"hybrid": {"cloud": "live"}})));
    assert_eq!((status.phase, status.home), (Phase::Running, Home::Cloud));
}

#[test]
fn pins_and_the_last_reason_pass_through() {
    let status = status(&facts(json!({
        "home": "cloud",
        "machine": {"shape": {"vcpu": 8.0, "memory_gib": 16.0}},
        "size": {"mode": "pinned", "vcpu": 8.0, "memory_gib": 16.0},
        "sleep": {"mode": "keep_awake", "until_ms": 3_600_000},
        "why": {"at_ms": 50, "reason": "grew_for_memory", "command": "cargo build"}
    })));
    let value = serde_json::to_value(&status).unwrap();
    assert_eq!(value["size"], json!({"mode": "pinned", "vcpu": 8.0, "memory_gib": 16.0}));
    assert_eq!(value["sleep"], json!({"mode": "keep_awake", "until_ms": 3_600_000}));
    assert_eq!(
        value["why"],
        json!({"at_ms": 50, "reason": "grew_for_memory", "command": "cargo build"})
    );
    let forever = status_sleep(json!({"mode": "keep_awake"}));
    assert_eq!(serde_json::to_value(forever).unwrap(), json!({"mode": "keep_awake"}));
}

fn status_sleep(sleep: serde_json::Value) -> Sleep {
    status(&facts(json!({"sleep": sleep}))).sleep
}

#[test]
fn a_phase_reason_beats_an_older_placement_reason_but_not_a_newer_one() {
    let older = json!({
        "home": "cloud",
        "machine": {"paused_by": "spend_cap", "paused_since_ms": 100},
        "why": {"at_ms": 10, "reason": "mac_memory_pressure"}
    });
    assert_eq!(status(&facts(older)).why.map(|why| why.reason), Some(Reason::SpendCap));
    let newer = json!({
        "home": "cloud",
        "machine": {"paused_by": "spend_cap", "paused_since_ms": 100},
        "why": {"at_ms": 200, "reason": "person_moved"}
    });
    assert_eq!(status(&facts(newer)).why.map(|why| why.reason), Some(Reason::PersonMoved));
}

#[test]
fn no_cloud_computer_means_no_shape() {
    assert_eq!(status(&facts(json!({"home": "cloud"}))).shape, None);
}

#[test]
fn every_reason_spells_as_the_brief_names_it() {
    let reasons = [
        (Reason::MacMemoryPressure, "mac_memory_pressure"),
        (Reason::MacBusy, "mac_busy"),
        (Reason::LidClosed, "lid_closed"),
        (Reason::GrewForMemory, "grew_for_memory"),
        (Reason::PersonMoved, "person_moved"),
        (Reason::SlotsFull, "slots_full"),
        (Reason::SpendCap, "spend_cap"),
    ];
    for (reason, word) in reasons {
        assert_eq!(serde_json::to_value(reason).unwrap(), json!(word));
    }
    let phases = [
        (Phase::Running, "running"),
        (Phase::Preparing, "preparing"),
        (Phase::Moving, "moving"),
        (Phase::MoveFailed, "move_failed"),
        (Phase::Reconnecting, "reconnecting"),
        (Phase::Sleeping, "sleeping"),
        (Phase::PausedSpendCap, "paused_spend_cap"),
        (Phase::PausedPoolSpent, "paused_pool_spent"),
        (Phase::StayingLocalSlotsFull, "staying_local_slots_full"),
    ];
    for (phase, word) in phases {
        assert_eq!(serde_json::to_value(phase).unwrap(), json!(word));
    }
}
