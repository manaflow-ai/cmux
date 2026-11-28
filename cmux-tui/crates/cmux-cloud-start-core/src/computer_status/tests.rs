use super::*;
use serde_json::json;

/// `value`'s facts, with session `s1` when it names none.
fn facts(mut value: serde_json::Value) -> Facts {
    value.as_object_mut().unwrap().entry("session_id").or_insert(json!("s1"));
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
        "hybrid": {"cloud": "booting", "since_ms": 1_000}
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
    let status = status(&facts(json!({"hybrid": {"cloud": "moving", "since_ms": 9}})));
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
    let status = status_of_hybrid_failure("network_dropped");
    assert_eq!((status.phase, status.home), (Phase::MoveFailed, Home::ThisMac));
    assert_eq!(status.move_.unwrap().failure, Some(MoveFailure::NetworkDropped));
    assert_eq!(
        status_of_hybrid_failure("mac_slept").move_.unwrap().failure,
        Some(MoveFailure::MacSlept)
    );
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
}

#[test]
fn an_unknown_pause_word_is_paused_not_an_idle_sleep() {
    let status = status(&facts(json!({
        "home": "cloud",
        "machine": {"paused_by": "provider_stopped", "paused_since_ms": 8}
    })));
    assert_eq!((status.phase, status.phase_since_ms), (Phase::Paused, Some(8)));
    assert_eq!(status.why, None);
    // A local chat keeps running past any pause of a cloud machine.
    let local = json!({"home": "this_mac", "machine": {"paused_by": "provider_stopped"}});
    assert_eq!(phase_of(local), Phase::Running);
    // A live hybrid chat is in the cloud: its unknown pause is paused too.
    let live = json!({"hybrid": {"cloud": "live"}, "machine": {"paused_by": "who_knows"}});
    assert_eq!(phase_of(live), Phase::Paused);
}

#[test]
fn a_stray_word_in_a_failure_message_is_no_failure_kind() {
    for reason in [
        "connection reset",
        "the machine start: network unreachable",
        "no machine",
        "sleep timer fired",
        "the Mac slept",
        "",
    ] {
        assert_eq!(
            status_of_hybrid_failure(reason).move_.unwrap().failure,
            Some(MoveFailure::Other),
            "{reason:?}"
        );
    }
    assert_eq!(
        status_of_hybrid_failure("cloud.quota.exceeded at boot").phase,
        Phase::MoveFailed,
        "a code inside a sentence is no refusal code"
    );
    let failed = status(&facts(json!({"hybrid": {"cloud": "failed"}})));
    assert_eq!(failed.move_.unwrap().failure, Some(MoveFailure::Other));
}

#[test]
fn a_live_hybrid_chat_pauses_at_the_spend_cap_and_the_pool() {
    let status = status(&facts(json!({
        "hybrid": {"cloud": "live", "since_ms": 4},
        "machine": {"paused_by": "spend_cap", "paused_since_ms": 60}
    })));
    assert_eq!((status.phase, status.home), (Phase::PausedSpendCap, Home::Cloud));
    assert_eq!(status.why.map(|why| why.reason), Some(Reason::SpendCap));
    let pool = json!({"hybrid": {"cloud": "live"}, "machine": {"paused_by": "pool_spent"}});
    assert_eq!(phase_of(pool), Phase::PausedPoolSpent);
    let idle = json!({"hybrid": {"cloud": "live"}, "machine": {"paused_by": "idle"}});
    assert_eq!(phase_of(idle), Phase::Sleeping);
    // Still preparing, the chat runs here: the spend cap does not stop it.
    let booting = json!({"hybrid": {"cloud": "booting"}, "machine": {"paused_by": "spend_cap"}});
    assert_eq!(phase_of(booting), Phase::Preparing);
}

#[test]
fn a_hybrid_start_and_a_slots_full_refusal() {
    // Refused for slots before the machine came: staying here, never a failed move.
    let status = status(&facts(json!({
        "hybrid": {"cloud": "failed", "reason": "cloud.quota.exceeded", "since_ms": 12},
        "refusal": {"code": "cloud.quota.exceeded", "at_ms": 11}
    })));
    assert_eq!((status.phase, status.home), (Phase::StayingLocalSlotsFull, Home::ThisMac));
    assert_eq!(status.move_, None);
    assert_eq!(status.why, Some(Why { at_ms: 12, reason: Reason::SlotsFull, command: None }));
    // A live hybrid chat already has its computer: an older slots refusal says nothing now.
    let live = status_of(json!({
        "hybrid": {"cloud": "live"},
        "refusal": {"code": "cloud.quota.exceeded", "at_ms": 3}
    }));
    assert_eq!((live.phase, live.home), (Phase::Running, Home::Cloud));
    // A hybrid start failing for another reason with a slots refusal on file is still here.
    let other = status_of(json!({
        "hybrid": {"cloud": "failed", "reason": "no machine"},
        "refusal": {"code": "cloud.quota.exceeded", "at_ms": 3}
    }));
    assert_eq!((other.phase, other.home), (Phase::MoveFailed, Home::ThisMac));
}

fn status_of(value: serde_json::Value) -> ComputerStatus {
    status(&facts(value))
}

#[test]
fn a_hybrid_start_whose_move_failed_keeps_its_home() {
    // The Show reads live but the app's move stopped: the chat is still on this Mac.
    let status = status_of(json!({
        "home": "this_mac",
        "hybrid": {"cloud": "live"},
        "move": {"direction": "to_cloud", "cancellable": true, "failure": "network_dropped"}
    }));
    assert_eq!((status.phase, status.home), (Phase::MoveFailed, Home::ThisMac));
    // A Bring Back Local that stopped keeps a cloud chat in the cloud.
    let back = status_of(json!({
        "home": "cloud",
        "hybrid": {"cloud": "live"},
        "move": {"direction": "to_mac", "failure": "mac_slept"}
    }));
    assert_eq!((back.phase, back.home), (Phase::MoveFailed, Home::Cloud));
    // The hybrid start's own failed move keeps the chat here.
    let own = status_of(json!({"hybrid": {"cloud": "failed", "reason": "no machine"}}));
    assert_eq!((own.phase, own.home), (Phase::MoveFailed, Home::ThisMac));
    // A move in flight does not hold the home back once the Show is live.
    let moving = status_of(json!({
        "hybrid": {"cloud": "live"},
        "move": {"direction": "to_mac", "cancellable": true}
    }));
    assert_eq!((moving.phase, moving.home), (Phase::Moving, Home::Cloud));
}

#[test]
fn a_session_id_is_required_and_not_empty() {
    let read = |value| serde_json::from_value::<Facts>(value);
    assert!(read(json!({})).is_err());
    assert!(read(json!({"session_id": ""})).is_err());
    assert!(read(json!({"session_id": null})).is_err());
    assert_eq!(read(json!({"session_id": "s9"})).unwrap().session_id, "s9");
}

#[test]
fn hybrid_keys_are_snake_case_and_take_the_show_s_since_ms_too() {
    let snake = status_of(json!({"hybrid": {"cloud": "booting", "since_ms": 30}}));
    let camel = status_of(json!({"hybrid": {"cloud": "booting", "sinceMs": 30}}));
    assert_eq!((snake.phase_since_ms, camel.phase_since_ms), (Some(30), Some(30)));
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
        (Phase::Paused, "paused"),
        (Phase::PausedSpendCap, "paused_spend_cap"),
        (Phase::PausedPoolSpent, "paused_pool_spent"),
        (Phase::StayingLocalSlotsFull, "staying_local_slots_full"),
    ];
    for (phase, word) in phases {
        assert_eq!(serde_json::to_value(phase).unwrap(), json!(word));
    }
}

/// The header's live facts (`place`'s `at`, `move`, `start`, the machine as listed), as the app
/// sends them, through `live::facts`.
fn live_status(value: serde_json::Value) -> ComputerStatus {
    let mut value = value;
    value.as_object_mut().unwrap().entry("session").or_insert(json!("s1"));
    let live: live::Live = serde_json::from_value(value).unwrap();
    status(&live::facts(&live))
}

#[test]
fn a_live_move_view_shows_moving_and_says_why_auto_moved() {
    let moving = json!({
        "at": "local",
        "move": {"direction": "toCloud", "trigger": {"auto": "memory"}, "state": "moving",
                 "startedMs": 100, "elapsedMs": 40, "canCancel": true}
    });
    let status = live_status(moving);
    assert_eq!((status.phase, status.home), (Phase::Moving, Home::ThisMac));
    assert_eq!(status.phase_since_ms, Some(100));
    assert_eq!(
        status.move_,
        Some(Move { direction: Direction::ToCloud, cancellable: true, failure: None })
    );
    assert_eq!(
        status.why,
        Some(Why { at_ms: 100, reason: Reason::MacMemoryPressure, command: None })
    );
}

#[test]
fn a_failed_move_view_stays_where_it_was_and_a_live_one_shows_nothing() {
    let failed = json!({
        "at": "local",
        "move": {"direction": "toCloud", "trigger": "person", "state": "failed",
                 "startedMs": 100, "elapsedMs": 900, "reason": "network_dropped"}
    });
    let status = live_status(failed);
    assert_eq!(status.phase, Phase::MoveFailed);
    assert_eq!(status.phase_since_ms, Some(1000));
    assert_eq!(status.move_.and_then(|moved| moved.failure), Some(MoveFailure::NetworkDropped));
    assert_eq!(status.why.map(|why| why.reason), Some(Reason::PersonMoved));
    let landed = json!({
        "at": "cloud",
        "move": {"direction": "toCloud", "trigger": {"auto": "sleep"}, "state": "live",
                 "startedMs": 100, "elapsedMs": 900}
    });
    let status = live_status(landed);
    assert_eq!((status.phase, status.home), (Phase::Running, Home::Cloud));
    assert_eq!(status.why.map(|why| why.reason), Some(Reason::LidClosed));
    // Auto bringing it back says no Why of its own.
    let back = json!({
        "at": "local",
        "move": {"direction": "toLocal", "trigger": {"auto": "back"}, "state": "moving",
                 "startedMs": 5}
    });
    let status = live_status(back);
    assert_eq!(status.move_.map(|moved| moved.direction), Some(Direction::ToMac));
    assert_eq!(status.why, None);
}

#[test]
fn the_listed_machine_gives_the_shape_and_each_pause() {
    let machine = |extra: serde_json::Value| {
        let mut base = json!({"status": "paused", "size": {"cpu": 4, "memory_mb": 8192}});
        base.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        live_status(json!({"at": "cloud", "machine": base}))
    };
    let idle = machine(json!({"pause_reason": "idle"}));
    assert_eq!(idle.phase, Phase::Sleeping);
    assert_eq!(idle.shape, Some(Shape { vcpu: 4.0, memory_gib: 8.0 }));
    let capped = machine(json!({"paused_by": "spend_cap", "spend_cap_pause_at": 77}));
    assert_eq!((capped.phase, capped.phase_since_ms), (Phase::PausedSpendCap, Some(77)));
    assert_eq!(machine(json!({"pause_reason": "provider_stopped"})).phase, Phase::Paused);
    assert_eq!(machine(json!({"status": "running"})).phase, Phase::Running);
}

#[test]
fn a_live_start_and_a_slots_refusal_read_as_their_phases() {
    let preparing =
        live_status(json!({"start": {"cloud": "booting", "sinceMs": 3, "readiness": 40}}));
    assert_eq!((preparing.phase, preparing.phase_since_ms), (Phase::Preparing, Some(3)));
    let refused = live_status(json!({
        "machine": {"status": "failed", "error": {"code": "cloud.quota.exceeded", "at": 12}}
    }));
    assert_eq!(refused.phase, Phase::StayingLocalSlotsFull);
    assert_eq!(refused.why.map(|why| why.reason), Some(Reason::SlotsFull));
}

#[test]
fn a_move_s_monotonic_stamps_read_on_the_page_s_clock() {
    // The app's uptime clock reads 10_000 when Unix ms reads 1_700_000_000_500: a move that started
    // 4.2 s ago on uptime started at Unix 1_699_999_996_300, said in whole seconds.
    let clock = json!({"monoMs": 10_000, "wallMs": 1_700_000_000_500u64});
    let moving = live_status(json!({
        "at": "local", "clock": clock,
        "move": {"direction": "toCloud", "trigger": {"auto": "memory"}, "state": "moving",
                 "startedMs": 5_800, "elapsedMs": 4_200, "canCancel": true}
    }));
    assert_eq!(moving.phase_since_ms, Some(1_699_999_996_000));
    assert_eq!(moving.why.as_ref().map(|why| why.at_ms), Some(1_699_999_996_000));
    // The same move read a few ms later (both clocks moved) writes the same status.
    let later = live_status(json!({
        "at": "local", "clock": {"monoMs": 10_003, "wallMs": 1_700_000_000_503u64},
        "move": {"direction": "toCloud", "trigger": {"auto": "memory"}, "state": "moving",
                 "startedMs": 5_800, "elapsedMs": 4_203, "canCancel": true}
    }));
    assert_eq!(later, moving);
    // A failed move is since it stopped.
    let failed = live_status(json!({
        "at": "local", "clock": clock,
        "move": {"direction": "toCloud", "trigger": "person", "state": "failed",
                 "startedMs": 1_000, "elapsedMs": 2_000, "reason": "network_dropped"}
    }));
    assert_eq!(failed.phase_since_ms, Some(1_699_999_993_000));
    // A stamp ahead of the clock reading is now.
    assert_eq!(live::Clock { mono_ms: 5, wall_ms: 9_999 }.wall(50), 9_000);
}

#[test]
fn live_facts_need_a_session() {
    assert!(serde_json::from_value::<live::Live>(json!({"session": ""})).is_err());
    assert!(serde_json::from_value::<live::Live>(json!({"at": "local"})).is_err());
}
