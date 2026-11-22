use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

type Cache = SignalsCache<u64, &'static str>;

fn pushed_source() -> Source {
    sources()["agent.list"].clone()
}

fn polled_source() -> Source {
    Source {
        name: "test.polled".into(),
        op: "test.read".into(),
        push: vec![],
        floor: Duration::from_secs(5),
        stale_after: Duration::from_secs(60),
    }
}

#[test]
fn the_table_serves_op_sources_with_their_floor_and_stale_after() {
    let agent = &sources()["agent.list"];
    assert_eq!(agent.op, "agent.list");
    assert_eq!(agent.push, vec!["agent.changed".to_string()]);
    assert_eq!(agent.floor, Duration::from_secs(5));
    assert_eq!(agent.stale_after, Duration::from_secs(60));
    // Reader sources stay in the runtime.
    assert!(!sources().contains_key("github.pulls"));
    assert!(!sources().contains_key("http.json"));
}

#[test]
fn params_in_any_key_order_share_one_entry() {
    assert_eq!(
        entry_key("x", &json!({"b": 1, "a": {"d": 2, "c": 3}})),
        entry_key("x", &json!({"a": {"c": 3, "d": 2}, "b": 1}))
    );
    assert_eq!(entry_key("x", &json!(null)), entry_key("x", &json!({})));
}

#[test]
fn many_watchers_of_one_source_cost_one_read_and_all_hear_it() {
    let mut c = Cache::default();
    let now = Instant::now();
    let source = pushed_source();
    let fx = c.watch(1, "a", &source, json!({}), Some("m1"), None, now);
    assert_eq!(fx.reads.len(), 1);
    // Other apps and mounts join the same entry with no read.
    for w in 2..=5 {
        let fx = c.watch(w, "b", &source, json!({}), Some("m2"), None, now);
        assert!(fx.reads.is_empty());
    }
    assert_eq!(c.reads, 1);
    let fx = c.landed(&entry_key("agent.list", &json!({})), Ok(json!([1])), now, 7);
    assert_eq!(fx.tell.len(), 5);
    assert!(fx.tell.iter().all(|(_, s)| s["status"] == "fresh" && s["value"] == json!([1])));
    // A pushed source that answered arms no poll.
    assert!(fx.arm.is_empty());
    // A late watcher hears the kept value at once, with no read.
    let fx = c.watch(9, "c", &source, json!({}), None, None, now);
    assert!(fx.reads.is_empty());
    assert_eq!(fx.tell[0].1["updatedAt"], 7);
}

#[test]
fn pushes_coalesce_to_one_read_in_flight_and_one_queued() {
    let mut c = Cache::default();
    let now = Instant::now();
    let key = entry_key("agent.list", &json!({}));
    c.watch(1, "a", &pushed_source(), json!({}), None, None, now);
    c.landed(&key, Ok(json!([])), now, 1);
    let first = c.pushed("agent.changed");
    assert_eq!(first.reads.len(), 1);
    // The value stays on screen while it re-reads.
    assert_eq!(first.tell[0].1["status"], "stale");
    assert!(c.pushed("agent.changed").reads.is_empty());
    assert!(c.pushed("agent.changed").reads.is_empty());
    let fx = c.landed(&key, Ok(json!([1])), now, 2);
    assert_eq!(fx.reads.len(), 1, "one queued read follows");
    let fx = c.landed(&key, Ok(json!([1])), now, 3);
    assert!(fx.reads.is_empty());
    assert_eq!(c.reads, 3);
    // Another stream does nothing.
    assert!(c.pushed("chat.changed").reads.is_empty());
}

#[test]
fn an_unpushed_source_polls_at_stale_after_and_never_under_the_floor() {
    let mut c = Cache::default();
    let now = Instant::now();
    let source = polled_source();
    let key = entry_key(&source.name, &json!({}));
    c.watch(1, "a", &source, json!({}), None, None, now);
    let fx = c.landed(&key, Ok(json!(1)), now, 1);
    assert_eq!(fx.arm.len(), 1);
    assert_eq!(fx.arm[0].2, Duration::from_secs(60));
    // A reader asking for 1 s is held to the 5 s floor.
    let fx = c.watch(2, "a", &source, json!({}), None, Some(Duration::from_secs(1)), now);
    assert_eq!(fx.arm.last().unwrap().2, Duration::from_secs(5));
    let (k, epoch, _) = fx.arm.last().unwrap().clone();
    // An older timer does nothing; the current one reads.
    assert!(c.due(&k, epoch - 1).reads.is_empty());
    assert_eq!(c.due(&k, epoch).reads.len(), 1);
}

#[test]
fn hidden_mounts_stop_the_poll_and_showing_one_catches_up() {
    let mut c = Cache::default();
    let now = Instant::now();
    let source = polled_source();
    let key = entry_key(&source.name, &json!({}));
    c.watch(1, "a", &source, json!({}), Some("m1"), None, now);
    c.watch(2, "b", &source, json!({}), Some("m2"), None, now);
    let fx = c.landed(&key, Ok(json!(1)), now, 1);
    let (_, epoch, _) = fx.arm[0].clone();
    // One of two mounts hidden: still awake, still polling.
    let fx = c.mount_visible(&"m1", false, now);
    assert_eq!(fx.arm.len(), 1);
    // Both hidden: no timer, and an old timer finds nothing to do.
    let fx = c.mount_visible(&"m2", false, now);
    assert!(fx.arm.is_empty());
    assert!(c.due(&key, epoch).reads.is_empty());
    // Shown again before stale: the poll is armed for what is left of it.
    let later = now + Duration::from_secs(20);
    let fx = c.mount_visible(&"m1", true, later);
    assert!(fx.reads.is_empty());
    assert_eq!(fx.arm[0].2, Duration::from_secs(40));
    // Hidden past stale, then shown: it reads at once.
    c.mount_visible(&"m1", false, later);
    let fx = c.mount_visible(&"m1", true, now + Duration::from_secs(61));
    assert_eq!(fx.reads.len(), 1);
}

#[test]
fn a_push_while_hidden_reads_when_a_mount_is_shown() {
    let mut c = Cache::default();
    let now = Instant::now();
    let key = entry_key("agent.list", &json!({}));
    c.watch(1, "a", &pushed_source(), json!({}), Some("m1"), None, now);
    c.landed(&key, Ok(json!([])), now, 1);
    c.mount_visible(&"m1", false, now);
    assert!(c.pushed("agent.changed").reads.is_empty());
    let fx = c.mount_visible(&"m1", true, now);
    assert_eq!(fx.reads.len(), 1);
    // Shown with nothing missed: no read.
    c.landed(&key, Ok(json!([])), now, 2);
    c.mount_visible(&"m1", false, now);
    assert!(c.mount_visible(&"m1", true, now).reads.is_empty());
}

#[test]
fn errors_back_off_from_the_floor_and_final_errors_stop() {
    let mut c = Cache::default();
    let now = Instant::now();
    let source = polled_source();
    let key = entry_key(&source.name, &json!({}));
    c.watch(1, "a", &source, json!({}), None, None, now);
    let err = json!({"code": "operation.failed", "message": "x", "retryable": true});
    let fx = c.landed(&key, Err(err.clone()), now, 1);
    assert_eq!(fx.tell[0].1["status"], "error");
    assert_eq!(fx.arm[0].2, Duration::from_secs(5));
    c.refresh(&1);
    let fx = c.landed(&key, Err(err.clone()), now, 1);
    assert_eq!(fx.arm[0].2, Duration::from_secs(10));
    // A good answer, then a failed re-read: the value stays, stale.
    c.refresh(&1);
    c.landed(&key, Ok(json!(1)), now, 2);
    c.refresh(&1);
    let fx = c.landed(&key, Err(err), now, 3);
    assert_eq!(fx.tell[0].1["status"], "stale");
    assert_eq!(fx.tell[0].1["value"], 1);
    // scope.missing is not retried.
    c.refresh(&1);
    let fx = c.landed(&key, Err(json!({"code": "scope.missing", "message": "no"})), now, 4);
    assert!(fx.arm.is_empty());
}

#[test]
fn unwatched_entries_disarm_and_are_pruned_past_the_idle_cap() {
    let mut c = Cache::default();
    let now = Instant::now();
    let source = polled_source();
    for i in 0..(MAX_IDLE_ENTRIES as u64 + 10) {
        c.watch(i, "a", &source, json!({ "i": i }), None, None, now);
        c.landed(&entry_key(&source.name, &json!({ "i": i })), Ok(json!(i)), now, 1);
        let fx = c.unwatch(&i, now);
        assert!(fx.arm.is_empty());
    }
    assert_eq!(c.entries(), MAX_IDLE_ENTRIES);
    // A host that exits drops its watchers.
    c.watch(1000, "a", &source, json!({}), None, None, now);
    c.unwatch_where(|w| *w == 1000, now);
    assert!(c.refresh(&1000).reads.is_empty());
}
