use super::*;

fn registry() -> Value {
    json!({"machines": {
        "lane-a": {"lanes": {"max_lanes": 6}},
        "lane-b": {"aliases": ["Bee.local"], "lanes": {"accept_new": false, "accept_new_why": "retiring"}},
        "lane-c": {"lanes": {"accept_new": false, "elastic": {
            "state": "drained", "since": "2026-11-24T10:00:00Z", "why": "idle 2h"}}},
        "lane-d": {"lanes": {"accept_new": true, "elastic": {"state": "adding", "since": "2026-11-24T11:00:00Z"}}},
        "lane-e": {"lanes": {"elastic": {"state": "resting", "why": "future"}}},
        "owned": {"roles": ["leo-mac"]},
    }})
}

fn of(name: &str) -> Option<Value> {
    derive(Some(&registry()), name)
}

#[test]
fn elastic_derives_steady_draining_and_the_scalers_block() {
    assert_eq!(
        of("lane-a"),
        Some(json!({"v": 1, "acceptNew": null, "state": "steady", "since": null, "why": null}))
    );
    assert_eq!(
        of("bee"),
        Some(
            json!({"v": 1, "acceptNew": false, "state": "draining", "since": null, "why": "retiring"})
        ),
        "accept_new false with no block reads draining, by alias"
    );
    assert_eq!(
        of("lane-c"),
        Some(json!({"v": 1, "acceptNew": false, "state": "drained",
            "since": "2026-11-24T10:00:00Z", "why": "idle 2h"}))
    );
    assert_eq!(
        of("lane-d"),
        Some(json!({"v": 1, "acceptNew": true, "state": "adding",
            "since": "2026-11-24T11:00:00Z", "why": null}))
    );
    assert_eq!(of("lane-e").unwrap()["state"], "resting", "an unknown state is kept as written");
}

#[test]
fn elastic_the_makers_run_time_state_wins_over_the_registry() {
    let maker = json!({"at": 1_795_525_000.0, "slots": {
        "lane-a": {"state": "ready", "elastic": {"state": "draining", "since": 1_795_524_000.0, "why": "idle 31 min"}},
        "lane-new": {"state": "made", "elastic": {"state": "adding", "since": 1_795_524_900.0}},
        "lane-d": {"state": "ready"},
    }});
    let of = |n: &str| derive_with(Some(&registry()), Some(&maker), n);
    assert_eq!(
        of("lane-a"),
        Some(json!({"v": 1, "acceptNew": false, "state": "draining",
                    "since": "2026-11-24T12:40:00Z", "why": "idle 31 min"}))
    );
    assert_eq!(of("lane-new").unwrap()["state"], "adding", "a new slot with no lanes entry yet");
    assert_eq!(of("lane-new").unwrap()["acceptNew"], Value::Null);
    assert_eq!(of("lane-d").unwrap()["state"], "adding", "no run-time state: the registry speaks");
    assert!(fresh(&maker, SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_795_525_600)));
    assert!(!fresh(&maker, SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_795_526_000)));
}

#[test]
fn elastic_is_absent_without_a_lanes_entry() {
    assert_eq!(of("owned"), None, "a machine with no lanes");
    assert_eq!(of("nobody"), None, "a machine not in the registry");
    assert_eq!(derive(None, "lane-a"), None, "no registry");
}

#[test]
fn elastic_annotates_only_the_rows_the_registry_lists() {
    let mut rows = vec![json!({"name": "lane-b"}), json!({"name": "owned"}), json!({"x": 1})];
    annotate(&mut rows, Some(&registry()));
    assert_eq!(rows[0]["elastic"]["state"], "draining");
    assert!(rows[1].get("elastic").is_none() && rows[2].get("elastic").is_none());
}

#[test]
fn elastic_list_suffix_only_when_not_steady() {
    let row = |e: Value| json!({"name": "m", "elastic": e});
    assert_eq!(suffix(&json!({"name": "m"})), "", "an old daemon's row");
    assert_eq!(suffix(&row(json!({"v": 1, "state": "steady"}))), "");
    assert_eq!(suffix(&row(json!({"v": 1, "state": "draining"}))), "  [draining]");
    assert_eq!(suffix(&row(json!({"v": 1, "state": "adding"}))), "  [adding]");
    assert_eq!(suffix(&row(json!({"v": 1, "acceptNew": false}))), "  [no new]");
    assert_eq!(suffix(&row(json!({"v": 3, "state": "resting"}))), "  [resting]");
}

/// What an old client deserialized, before these fields: it names none of them.
#[derive(Deserialize)]
struct OldPeerRow {
    name: String,
    connected: bool,
}
#[derive(Deserialize)]
#[allow(dead_code)]
struct OldStatus {
    version: String,
}

#[test]
fn elastic_old_reply_parses_in_the_new_client() {
    let old_row = json!({"name": "lane-a", "connected": true});
    assert_eq!(Elastic::from_row(&old_row), None, "no field: None, no failure");
    assert_eq!(Elastic::from_row(&json!({"elastic": null})), None);
    assert_eq!(Elastic::from_row(&json!({"elastic": "x"})), None);
    assert_eq!(ScaleUpStatus::from_status(&json!({"version": "1.0"})), None);
}

#[test]
fn elastic_new_reply_parses_in_the_old_client_and_the_new() {
    let mut row = json!({"name": "lane-b", "connected": true});
    annotate(std::slice::from_mut(&mut row), Some(&registry()));
    let old: OldPeerRow = serde_json::from_value(row.clone()).unwrap();
    assert_eq!((old.name.as_str(), old.connected), ("lane-b", true), "unknown field ignored");
    let new = Elastic::from_row(&row).unwrap();
    assert_eq!(new.v, Some(1));
    assert_eq!(new.accept_new, Some(false));
    assert_eq!(new.state.as_deref(), Some("draining"));
    assert!(new.known());
    let status = json!({"version": "1.0", "scaleUp": {"v": 1, "state": "cooling",
        "lastStartedMs": 5, "lastEndedMs": 9, "lastHost": "lane-9", "lastError": null,
        "lastProvider": "lanes"}});
    let _: OldStatus = serde_json::from_value(status.clone()).unwrap();
    let s = ScaleUpStatus::from_status(&status).unwrap();
    assert_eq!(
        (s.v, s.state.as_deref(), s.last_started_ms, s.last_ended_ms, s.last_host.as_deref()),
        (Some(1), Some("cooling"), Some(5), Some(9), Some("lane-9"))
    );
    assert_eq!(s.last_error, None);
}

#[test]
fn elastic_future_version_and_unknown_state_do_not_fail() {
    let row = json!({"elastic": {"v": 2, "state": "hibernating", "acceptNew": true,
        "since": "t", "why": "w", "newField": {"a": 1}}});
    let e = Elastic::from_row(&row).unwrap();
    assert_eq!((e.v, e.state.as_deref()), (Some(2), Some("hibernating")));
    assert!(!e.known());
    let s = ScaleUpStatus::from_status(
        &json!({"scaleUp": {"v": 2, "state": "teleporting", "lastStartedMs": 1, "extra": true}}),
    )
    .unwrap();
    assert_eq!((s.v, s.state.as_deref()), (Some(2), Some("teleporting")));
    // A wrong-typed field fails only that object's parse, never the reply around it.
    assert_eq!(ScaleUpStatus::from_status(&json!({"scaleUp": {"v": "one"}})), None);
}
