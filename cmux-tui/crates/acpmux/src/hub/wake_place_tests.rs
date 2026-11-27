//! The wake's placement decision (`wake_place.rs`, RFD 0181 B6).

use super::*;

fn verdict() -> Value {
    json!({"pick": "roomy", "hosts": [
        {"name": "here", "local": true, "room": 0.0},
        {"name": "full", "room": 0.5},
        {"name": "held-peer", "room": 9.0},
        {"name": "roomy", "room": 4.0},
        {"name": "some", "room": 2.0},
    ]})
}

fn registry() -> Value {
    json!({"machines": {
        "here": {"lanes": {"max_lanes": 6}},
        "held-peer": {"lanes": {"max_lanes": 12}, "hold": {"reason": "drain", "owner": "ops"}},
        "roomy": {"lanes": {"max_lanes": 12}},
        "some": {"lanes": {"max_lanes": 12}},
    }})
}

fn facts(live: usize) -> Facts {
    Facts { live, max: Some(6), ..Facts::default() }
}

#[test]
fn a_wake_under_its_cap_starts_here_and_reads_no_peer() {
    let d = decide(&facts(5), &Value::Null, Some(&registry()), "here");
    assert_eq!(d, Decision { past_cap: false, held: false, to: None, stays: None });
    assert!(!d.misplaced());
    let uncapped = Facts { live: 99, max: None, ..Facts::default() };
    assert!(!decide(&uncapped, &Value::Null, None, "here").past_cap, "no cap: never past it");
}

#[test]
fn a_wake_past_its_cap_starts_on_picks_host_with_room() {
    // 6 live besides the waking chat against a cap of 6: the wake would be the 7th.
    let d = decide(&facts(6), &verdict(), Some(&registry()), "here");
    assert!(d.past_cap);
    assert_eq!(d.to.as_deref(), Some("roomy"), "most room, not held, not here, not full");
    assert_eq!(d.stays, None);
    assert!(!d.misplaced());
}

#[test]
fn a_wake_on_a_held_host_moves_under_its_cap_too() {
    let f = Facts { held: Some("held: drain".into()), ..facts(1) };
    let d = decide(&f, &verdict(), Some(&registry()), "here");
    assert!(d.held && !d.past_cap);
    assert_eq!(d.to.as_deref(), Some("roomy"));
}

#[test]
fn pinned_person_and_family_wakes_stay_and_say_why() {
    let cases = [
        (Facts { pinned: true, ..facts(9) }, "pinned to this machine"),
        (Facts { person: true, ..facts(9) }, "a person's wake"),
        (Facts { family: true, ..facts(9) }, "in a family: families move together"),
    ];
    for (f, why) in cases {
        let d = decide(&f, &verdict(), Some(&registry()), "here");
        assert_eq!((d.to.as_deref(), d.stays), (None, Some(why)));
        assert!(d.misplaced(), "{why}: counted, as it lands past the cap");
    }
}

#[test]
fn with_no_host_with_room_it_stays_and_counts() {
    let none =
        json!({"hosts": [{"name": "full", "room": 0.5}, {"name": "held-peer", "room": 9.0}]});
    let d = decide(&facts(7), &none, Some(&registry()), "here");
    assert_eq!((d.to, d.stays), (None, Some("no other host has room")));
}

/// The RFD's measurement, on a fleet shaped like 2026-11-24's (25 of 32 lane hosts past their
/// cap): 32 hosts, one wake each, 25 past their cap and 1 more held. Before B6 every wake started
/// where it slept; with the decision, every wake past a cap or on a held host that may move has
/// a host with room to start on.
#[test]
fn wakes_onto_past_cap_or_held_hosts_fall_to_zero_where_a_peer_has_room() {
    let mut before = 0;
    let mut after = 0;
    for i in 0..32 {
        let f = Facts {
            live: if i < 25 { 6 + i % 4 } else { 3 },
            held: (i == 30).then(|| "held".into()),
            ..facts(0)
        };
        let d = decide(&f, &verdict(), Some(&registry()), "here");
        before += usize::from(d.past_cap || d.held);
        after += usize::from(d.misplaced());
    }
    assert_eq!((before, after), (26, 0));
}

#[test]
fn the_line_names_what_was_read_and_decided() {
    let d = decide(&facts(6), &verdict(), Some(&registry()), "here");
    let l = line("s1", Some("agent-msg"), &facts(6), &d);
    assert_eq!(l["session"], "s1");
    assert_eq!(l["cause"], "agent-msg");
    assert_eq!((l["live"].as_u64(), l["max"].as_u64()), (Some(6), Some(6)));
    assert_eq!((l["pastCap"].as_bool(), l["held"].as_bool()), (Some(true), Some(false)));
    assert_eq!(l["to"], "roomy");
    assert!(l["stays"].is_null());
}
