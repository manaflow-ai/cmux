//! `ChiefBrainWatchShutdownTests` and the watch's lock rules, driven through `chief_brain.watch_step`.

use cmux_home_rules::call;
use serde_json::{Value, json};

struct Watch {
    state: Value,
    restarts: usize,
    reported: Vec<Option<i64>>,
}

impl Watch {
    fn new() -> Self {
        Watch { state: json!({}), restarts: 0, reported: Vec::new() }
    }

    fn step(&mut self, event: Value) -> Vec<Value> {
        let out = call("chief_brain.watch_step", &json!({ "state": self.state, "event": event }))
            .expect("watch_step");
        self.state = out["state"].clone();
        let effects = out["effects"].as_array().cloned().unwrap_or_default();
        for e in &effects {
            match e["kind"].as_str() {
                Some("restart") => self.restarts += 1,
                Some("report") => self.reported.push(e["pid"].as_i64()),
                _ => {}
            }
        }
        effects
    }

    fn watching(&self) -> bool {
        self.state["sourcePid"].is_i64() || self.state["restarting"] == json!(true)
    }

    fn given_up(&self) -> bool {
        self.state["hasGivenUp"] == json!(true)
    }
}

fn kinds(effects: &[Value]) -> Vec<&str> {
    effects.iter().filter_map(|e| e["kind"].as_str()).collect()
}

#[test]
fn a_locked_host_is_watched_and_its_lock_sources_close() {
    let mut w = Watch::new();
    let fx = w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    assert_eq!(kinds(&fx), ["cancelLockSources", "report", "armExitSource"]);
    assert!(w.watching());
    assert_eq!(w.reported, [Some(42)]);
}

#[test]
fn a_host_stopped_by_shutdown_is_not_restarted() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    let fx = w.step(
        json!({"kind": "exited", "pid": 42, "locked": null, "shutdownMarker": true, "nowMs": 0.0}),
    );
    assert_eq!(w.restarts, 0);
    assert!(!kinds(&fx).contains(&"restart"));
    assert!(!w.watching());
}

#[test]
fn a_host_that_dies_is_restarted_once() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    w.step(
        json!({"kind": "exited", "pid": 42, "locked": null, "shutdownMarker": false, "nowMs": 0.0}),
    );
    assert_eq!(w.restarts, 1);
    assert!(w.watching(), "restarting counts as watching");
    w.step(json!({"kind": "restarted", "next": 43, "shutdownMarker": false, "nextIsHost": true, "locked": 43}));
    assert_eq!(w.state["sourcePid"], json!(43));
    assert_eq!(w.state["restarting"], json!(false));
}

#[test]
fn a_host_that_keeps_dying_gives_up_and_a_live_host_clears_it() {
    let mut w = Watch::new();
    let mut pid = 100;
    w.step(json!({"kind": "watch", "pid": pid, "locked": pid}));
    for i in 0..3 {
        w.step(json!({"kind": "exited", "pid": pid, "locked": null, "shutdownMarker": false, "nowMs": f64::from(i) * 1000.0}));
        if w.given_up() {
            break;
        }
        pid += 1;
        w.step(json!({"kind": "restarted", "next": pid, "shutdownMarker": false, "nextIsHost": true, "locked": pid}));
    }
    assert!(w.given_up());
    assert_eq!(w.restarts, 2, "the third death within a minute gives up");
    w.step(json!({"kind": "watch", "pid": 900, "locked": 900}));
    assert!(!w.given_up());
}

#[test]
fn deaths_outside_the_window_do_not_count() {
    let mut w = Watch::new();
    let mut pid = 100;
    w.step(json!({"kind": "watch", "pid": pid, "locked": pid}));
    for i in 0..5 {
        w.step(json!({"kind": "exited", "pid": pid, "locked": null, "shutdownMarker": false, "nowMs": f64::from(i) * 61_000.0}));
        pid += 1;
        w.step(json!({"kind": "restarted", "next": pid, "shutdownMarker": false, "nextIsHost": true, "locked": pid}));
    }
    assert!(!w.given_up());
    assert_eq!(w.restarts, 5);
}

#[test]
fn an_exit_with_another_host_on_the_lock_watches_that_one() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    w.step(
        json!({"kind": "exited", "pid": 42, "locked": 77, "shutdownMarker": false, "nowMs": 0.0}),
    );
    assert_eq!(w.restarts, 0);
    assert_eq!(w.state["sourcePid"], json!(77));
}

#[test]
fn a_restart_after_stop_or_shutdown_kills_the_new_host() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    w.step(
        json!({"kind": "exited", "pid": 42, "locked": null, "shutdownMarker": false, "nowMs": 0.0}),
    );
    let fx = w.step(json!({"kind": "restarted", "next": 43, "shutdownMarker": true, "nextIsHost": true, "locked": 43}));
    assert_eq!(fx, [json!({"kind": "terminate", "pid": 43})]);
    assert!(!w.watching());
}

#[test]
fn a_launch_pid_the_lock_does_not_name_yet_rereads_then_waits_on_the_lock() {
    let mut w = Watch::new();
    let fx = w.step(json!({"kind": "watch", "pid": 50, "locked": null}));
    assert_eq!(kinds(&fx), ["ensureLockSources", "readLock"]);
    let fx = w.step(json!({"kind": "lockRead", "locked": null}));
    assert_eq!(kinds(&fx), ["report", "armExitSource"]);
    assert_eq!(w.state["pendingLockPid"], json!(50));
    // The lock now names it: the reader hears again, the lock sources close.
    let fx = w.step(json!({"kind": "lockChanged", "folder": false}));
    assert_eq!(kinds(&fx), ["readLock"]);
    let fx = w.step(json!({"kind": "lockRead", "locked": 50}));
    assert_eq!(fx, [json!({"kind": "cancelLockSources"}), json!({"kind": "report", "pid": 50})]);
    assert_eq!(w.state["pendingLockPid"], Value::Null);
}

#[test]
fn the_files_host_launcher_hands_over_to_the_host_it_runs() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 60, "locked": 61, "launcher": true}));
    assert_eq!(w.state["sourcePid"], json!(61));
    assert_eq!(w.reported, [Some(61)]);
}

#[test]
fn no_host_arms_on_the_lock_and_watches_the_host_it_names() {
    let mut w = Watch::new();
    let fx = w.step(json!({"kind": "watch", "pid": null, "locked": null}));
    assert_eq!(kinds(&fx), ["log", "ensureLockSources", "readLock"]);
    w.step(json!({"kind": "lockRead", "locked": null}));
    assert!(!w.watching());
    w.step(json!({"kind": "lockChanged", "folder": true}));
    w.step(json!({"kind": "lockRead", "locked": 88}));
    assert_eq!(w.state["sourcePid"], json!(88));
}

#[test]
fn stop_ends_everything_and_later_events_do_nothing() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    let fx = w.step(json!({"kind": "stop"}));
    assert_eq!(kinds(&fx), ["cancelExitSource", "cancelLockSources", "report"]);
    assert_eq!(w.state["stopped"], json!(true));
    assert!(w.step(json!({"kind": "watch", "pid": 43, "locked": 43})).is_empty());
    assert!(w.step(json!({"kind": "exited", "pid": 42, "locked": null, "shutdownMarker": false, "nowMs": 0.0})).is_empty());
}

#[test]
fn an_exit_of_a_pid_not_watched_is_dropped() {
    let mut w = Watch::new();
    w.step(json!({"kind": "watch", "pid": 42, "locked": 42}));
    assert!(w.step(json!({"kind": "exited", "pid": 41, "locked": null, "shutdownMarker": false, "nowMs": 0.0})).is_empty());
    assert_eq!(w.restarts, 0);
}
