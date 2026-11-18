//! `projfs-v1`: the rendezvous between the mount helper's `projfs.fetch` and the Mac's
//! `projfs.next` / `projfs.answer`, through the wire answer as the daemon serves it.

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;

const MOUNT: &str = "m1";
const SETTLE: Duration = Duration::from_secs(10);

fn service() -> Arc<Rendezvous> {
    Arc::new(Rendezvous::new())
}

/// One request line through [`answer_line`].
fn call(service: &Rendezvous, caller: Caller, request: &Value) -> Value {
    answer_line(Some(service), caller, &request.to_string())
}

fn want(path: &str, offset: u64, len: u64) -> Value {
    json!({ "path": path, "size": 10, "mtime_ns": 5, "ctime_ns": 6, "offset": offset, "len": len })
}

fn fetch_line(wants: Vec<Value>, wait_ms: u64) -> Value {
    json!({ "id": 1, "cmd": "projfs.fetch", "mount": MOUNT, "wants": wants, "wait_ms": wait_ms })
}

fn next_line(wait_ms: u64) -> Value {
    json!({ "id": 2, "cmd": "projfs.next", "mount": MOUNT, "wait_ms": wait_ms })
}

fn answer_line_for(batch: &Value, results: Value) -> Value {
    json!({ "id": 3, "cmd": "projfs.answer", "mount": MOUNT, "batch": batch["id"], "results": results })
}

/// `projfs.fetch` on a thread of its own; its answer comes back on the handle.
fn fetch_in_background(service: &Arc<Rendezvous>, request: Value) -> thread::JoinHandle<Value> {
    let service = service.clone();
    thread::spawn(move || call(&service, Caller::Local, &request))
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn code(answer: &Value) -> &str {
    answer["error_code"].as_str().unwrap_or("")
}

#[test]
fn a_fetch_with_no_mac_answers_away_after_its_wait() {
    let service = service();
    let started = Instant::now();
    let answer =
        call(&service, Caller::Local, &fetch_line(vec![want("a", 0, 4), want("b", 0, 4)], 150));
    assert!(started.elapsed() >= Duration::from_millis(150), "it waited");
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["data"]["results"], json!([{"status": "away"}, {"status": "away"}]));
    let status =
        call(&service, Caller::Local, &json!({"id": 9, "cmd": "projfs.status", "mount": MOUNT}));
    assert_eq!(status["data"]["mounts"][0]["queued"], 0, "the given-up wants left the queue");
    assert_eq!(status["data"]["mounts"][0]["fetching"], 0);
}

#[test]
fn next_then_fetch_rendezvous_and_the_answer_keeps_the_order() {
    let service = service();
    let poller = {
        let service = service.clone();
        thread::spawn(move || call(&service, Caller::Remote, &next_line(10_000)))
    };
    assert!(service.settle(MOUNT, SETTLE, |c| c["polling"] == 1), "the Mac is polling");
    let wants = vec![want("a.txt", 0, 3), want("dir/b", 4, 2), want("c", 0, 1), want("d", 0, 1)];
    let fetch = fetch_in_background(&service, fetch_line(wants, 10_000));
    let next = poller.join().unwrap();
    let batch = &next["data"]["batch"];
    let paths: Vec<&str> =
        batch["wants"].as_array().unwrap().iter().map(|w| w["path"].as_str().unwrap()).collect();
    assert_eq!(paths, ["a.txt", "dir/b", "c", "d"], "{next}");
    assert_eq!(batch["wants"][1], want("dir/b", 4, 2), "the want as the helper sent it");
    let results = json!([
        {"status": "bytes", "data_b64": b64(b"abc")},
        {"status": "changed", "size": 3, "mtime_ns": 7, "ctime_ns": 8, "mode": 33188},
        {"status": "gone"},
        {"status": "failed", "reason": "unreadable"},
    ]);
    let answered = call(&service, Caller::Remote, &answer_line_for(batch, results.clone()));
    assert_eq!(answered["data"]["answered"], 4, "{answered}");
    let fetched = fetch.join().unwrap();
    assert_eq!(fetched["data"]["results"], results, "{fetched}");
    let status = call(&service, Caller::Remote, &json!({"id": 9, "cmd": "projfs.status"}));
    let counts = &status["data"]["mounts"][0];
    assert_eq!(
        (counts["mount"].as_str(), counts["bytes_answered"].as_u64()),
        (Some(MOUNT), Some(3))
    );
    assert!(counts["last_answer_age_ms"].is_u64(), "{status}");
}

#[test]
fn fetch_then_next_rendezvous() {
    let service = service();
    let fetch = fetch_in_background(&service, fetch_line(vec![want("x", 0, 2)], 10_000));
    assert!(service.settle(MOUNT, SETTLE, |c| c["queued"] == 1), "the want is queued");
    let started = Instant::now();
    let next = call(&service, Caller::Remote, &next_line(10_000));
    assert!(started.elapsed() < Duration::from_secs(5), "queued wants answer the poll at once");
    let batch = &next["data"]["batch"];
    call(&service, Caller::Remote, &answer_line_for(batch, json!([{"status": "withheld"}])));
    assert_eq!(fetch.join().unwrap()["data"]["results"], json!([{"status": "withheld"}]));
}

#[test]
fn a_poll_with_nothing_queued_answers_null_after_its_wait() {
    let service = service();
    let next = call(&service, Caller::Remote, &next_line(50));
    assert_eq!(next["data"], json!({"batch": null}), "{next}");
}

#[test]
fn a_batch_whose_lease_ends_goes_to_the_next_poll() {
    let limits = Limits { max_wait: MAX_WAIT, lease: Duration::from_millis(100) };
    let service = Arc::new(Rendezvous::with_limits(limits));
    let fetch =
        fetch_in_background(&service, fetch_line(vec![want("a", 0, 1), want("b", 0, 1)], 10_000));
    let first = call(&service, Caller::Remote, &next_line(10_000));
    let first = &first["data"]["batch"];
    assert_eq!(first["wants"].as_array().map(Vec::len), Some(2), "{first}");
    // That Mac went away; the next poll waits for the lease to end and gets the same wants.
    let second = call(&service, Caller::Remote, &next_line(10_000));
    let second = &second["data"]["batch"];
    assert_ne!(first["id"], second["id"]);
    assert_eq!(first["wants"], second["wants"]);
    let late = call(
        &service,
        Caller::Remote,
        &answer_line_for(first, json!([{"status": "gone"}, {"status": "gone"}])),
    );
    assert_eq!(code(&late), "projfs.unknown_batch", "{late}");
    let results = json!([{"status": "bytes", "data_b64": b64(b"1")}, {"status": "away"}]);
    call(&service, Caller::Remote, &answer_line_for(second, results.clone()));
    assert_eq!(fetch.join().unwrap()["data"]["results"], results);
}

#[test]
fn a_fetch_past_its_wait_still_takes_the_answer_of_a_batch_a_mac_holds() {
    let service = service();
    let fetch = fetch_in_background(&service, fetch_line(vec![want("a", 0, 1)], 100));
    let next = call(&service, Caller::Remote, &next_line(10_000));
    let batch = next["data"]["batch"].clone();
    // The fetch's own wait ends while the Mac holds its want: it waits for that answer.
    assert!(!service.settle(MOUNT, Duration::from_millis(300), |c| c["fetching"] == 0));
    call(&service, Caller::Remote, &answer_line_for(&batch, json!([{"status": "gone"}])));
    assert_eq!(fetch.join().unwrap()["data"]["results"], json!([{"status": "gone"}]));
}

#[test]
fn the_wants_are_bounded() {
    let service = service();
    let fetch = |wants: Vec<Value>| call(&service, Caller::Local, &fetch_line(wants, 0));
    let many: Vec<Value> = (0..=MAX_WANTS).map(|i| want(&format!("f{i}"), 0, 1)).collect();
    assert_eq!(code(&fetch(many)), "projfs.limit");
    let heavy: Vec<Value> = (0..3).map(|i| want(&format!("f{i}"), 0, MAX_WANT_LEN)).collect();
    assert_eq!(code(&fetch(heavy)), "projfs.limit", "12 MiB in one fetch");
    for bad in [
        want("a", 0, 0),
        want("a", 0, MAX_WANT_LEN + 1),
        want(&"p".repeat(MAX_PATH_BYTES + 1), 0, 1),
        want("", 0, 1),
        json!({"path": "a", "size": 1, "mtime_ns": 0, "ctime_ns": 0, "offset": 0}),
        json!({"path": "a", "size": 1, "mtime_ns": 0, "ctime_ns": 0, "offset": 0, "len": 1, "x": 1}),
        json!("a"),
    ] {
        assert_eq!(code(&fetch(vec![bad.clone()])), "projfs.bad_request", "{bad}");
    }
    for mount in ["", "a b", "../x", &"m".repeat(MAX_MOUNT_ID + 1)] {
        let line = json!({"id": 1, "cmd": "projfs.next", "mount": mount, "wait_ms": 0});
        assert_eq!(code(&call(&service, Caller::Remote, &line)), "projfs.bad_request", "{mount:?}");
    }
    let line = json!({"id": 1, "cmd": "projfs.next", "mount": "m", "wait_ms": -1});
    assert_eq!(code(&call(&service, Caller::Remote, &line)), "projfs.bad_request");
}

#[test]
fn the_queue_of_a_mount_is_bounded() {
    let service = service();
    let full: Vec<thread::JoinHandle<Value>> = (0..MAX_QUEUED_WANTS / MAX_WANTS)
        .map(|_| {
            let wants = (0..MAX_WANTS).map(|i| want(&format!("f{i}"), 0, 1)).collect();
            fetch_in_background(&service, fetch_line(wants, 2_000))
        })
        .collect();
    let count = full.len();
    assert!(service.settle(MOUNT, SETTLE, |c| c["fetching"] == count), "every fetch is waiting");
    let over = call(&service, Caller::Local, &fetch_line(vec![want("one more", 0, 1)], 0));
    assert_eq!(code(&over), "projfs.limit", "{over}");
    for fetch in full {
        assert_eq!(fetch.join().unwrap()["data"]["results"][0], json!({"status": "away"}));
    }
}

#[test]
fn answers_are_checked_against_their_batch() {
    let service = service();
    let fetch = fetch_in_background(&service, fetch_line(vec![want("a", 0, 2)], 10_000));
    let next = call(&service, Caller::Remote, &next_line(10_000));
    let batch = next["data"]["batch"].clone();
    for bad in [
        json!([]),
        json!([{"status": "bytes", "data_b64": b64(b"too long")}]),
        json!([{"status": "bytes", "data_b64": "not base64!"}]),
        json!([{"status": "changed", "size": 1}]),
        json!([{"status": "maybe"}]),
        json!([{"status": "gone", "extra": 1}]),
        json!([{"status": "failed", "reason": "r".repeat(MAX_REASON_BYTES + 1)}]),
    ] {
        let answer = call(&service, Caller::Remote, &answer_line_for(&batch, bad.clone()));
        assert_eq!(code(&answer), "projfs.bad_request", "{bad}");
    }
    let unknown =
        json!({"id": 3, "cmd": "projfs.answer", "mount": MOUNT, "batch": "b999", "results": []});
    assert_eq!(code(&call(&service, Caller::Remote, &unknown)), "projfs.unknown_batch");
    // A refused answer leaves the batch out: the right one still completes the fetch.
    let good = json!([{"status": "bytes", "data_b64": b64(b"ok")}]);
    assert_eq!(call(&service, Caller::Remote, &answer_line_for(&batch, good.clone()))["ok"], true);
    assert_eq!(fetch.join().unwrap()["data"]["results"], good);
}

#[test]
fn idle_mounts_past_the_bound_are_forgotten() {
    let service = service();
    for i in 0..=MAX_MOUNTS {
        let line = json!({"id": 1, "cmd": "projfs.next", "mount": format!("m{i}"), "wait_ms": 0});
        assert_eq!(call(&service, Caller::Remote, &line)["ok"], true);
    }
    let status = call(&service, Caller::Local, &json!({"id": 1, "cmd": "projfs.status"}));
    assert_eq!(status["data"]["mounts"].as_array().map(Vec::len), Some(MAX_MOUNTS));
}

#[test]
fn only_the_helper_fetches_and_only_the_mac_takes_and_answers() {
    let service = service();
    let fetch = fetch_line(vec![want("a", 0, 1)], 0);
    assert_eq!(call(&service, Caller::Local, &fetch)["ok"], true, "a local connection may fetch");
    for caller in [Caller::Remote, Caller::Denied] {
        assert_eq!(code(&call(&service, caller, &fetch)), "projfs.permission_denied", "{caller:?}");
    }
    let answer =
        json!({"id": 3, "cmd": "projfs.answer", "mount": MOUNT, "batch": "b0", "results": []});
    for line in [next_line(0), answer] {
        for caller in [Caller::Local, Caller::Denied] {
            assert_eq!(code(&call(&service, caller, &line)), "projfs.permission_denied", "{line}");
        }
    }
    let status = json!({"id": 1, "cmd": "projfs.status"});
    assert_eq!(call(&service, Caller::Local, &status)["ok"], true);
    assert_eq!(code(&call(&service, Caller::Denied, &status)), "projfs.permission_denied");
    let unserved = answer_line(None, Caller::Local, &fetch.to_string());
    assert_eq!(code(&unserved), "projfs.unavailable");
    assert_eq!(unserved["id"], 1);
}

#[test]
fn the_commands_are_exact_and_the_remote_set_has_no_fetch() {
    for cmd in PROJFS_COMMANDS {
        assert_eq!(frame_command(&json!({"id": 1, "cmd": cmd}).to_string()), Some(cmd));
    }
    assert_eq!(remote_frame_command(r#"{"id":1,"cmd":"projfs.fetch"}"#), None);
    for cmd in PROJFS_REMOTE_COMMANDS {
        assert_eq!(remote_frame_command(&json!({"id": 1, "cmd": cmd}).to_string()), Some(cmd));
    }
    for frame in [
        r#"{"id":1,"cmd":"projfs.next","protocol":"cmux.protocol/2"}"#,
        r#"{"id":1,"cmd":"PROJFS.NEXT"}"#,
        r#"{"id":1,"cmd":"projfs.nextx"}"#,
        r#"{"id":1,"op":"projfs.next"}"#,
        "projfs.next",
    ] {
        assert_eq!(frame_command(frame), None, "{frame}");
    }
}

#[test]
fn base64_lengths() {
    assert_eq!(base64_len(""), Some(0));
    assert_eq!(base64_len(&b64(b"a")), Some(1));
    assert_eq!(base64_len(&b64(b"ab")), Some(2));
    assert_eq!(base64_len(&b64(b"abc")), Some(3));
    assert_eq!(base64_len("abc"), None);
    assert_eq!(base64_len("a==="), None);
    assert_eq!(base64_len("a-b="), None);
}
