//! The golden vectors (tests/vectors/*.json), each derived from the Swift
//! rule or test it replaces, run through the C ABI the app calls. The app's
//! Swift tests feed the same files through `CCmuxDaemonConnFFI`.

use cmux_daemon_conn_core::ffi::*;
use cmux_daemon_conn_core::heartbeat::{CmuxHeartbeat, CmuxHeartbeatStep};
use cmux_daemon_conn_core::retry::{CmuxRetryPacer, CmuxRetryPolicy};
use serde_json::{Value, json};
use std::ffi::CString;
use std::path::Path;

fn vectors(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/vectors").join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).expect("read vectors"))
        .expect("vectors are JSON")
}

fn reply(code: i32, out: CmuxDaemonConnBytes) -> Value {
    assert_eq!(code, OK, "op failed with {code}");
    // SAFETY: a buffer this library gave out.
    let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    // SAFETY: handed back once.
    unsafe { cmux_daemon_conn_bytes_free(out) };
    serde_json::from_slice(&bytes).expect("reply is JSON")
}

fn call(op: &str, request: &Value) -> Value {
    let op = CString::new(op).expect("op");
    let request = serde_json::to_vec(request).expect("request");
    let mut out = CmuxDaemonConnBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let code =
        unsafe { cmux_daemon_conn_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    reply(code, out)
}

fn policy_from(value: &Value) -> CmuxRetryPolicy {
    cmux_retry_policy_new(
        value["initial_ns"].as_u64().expect("initial"),
        value["maximum_ns"].as_u64().expect("maximum"),
        value["timed_retries"].as_i64().expect("timed"),
        value["socket_retries"].as_i64().expect("socket"),
        value["keeps_trying"].as_bool().expect("keeps"),
    )
}

fn delay(ns: i64) -> Value {
    if ns < 0 { Value::Null } else { json!(ns) }
}

#[test]
fn retry_vectors() {
    let file = vectors("retry.json");
    assert_eq!(cmux_retry_busy_cap_ns(), file["busy_retry_cap_ns"].as_u64().expect("cap"));
    for (code, name) in
        ["reconnect", "first_connect", "local_reconnect", "local_first_connect", "resync"]
            .iter()
            .enumerate()
    {
        let mut policy = cmux_retry_policy_new(1, 1, 0, 0, false);
        // SAFETY: a writable policy.
        assert_eq!(
            unsafe { cmux_retry_policy_preset(u32::try_from(code).expect("code"), &mut policy) },
            OK
        );
        assert_eq!(policy, policy_from(&file["presets"][name]), "preset {name}");
    }
    for corrected in file["corrected"].as_array().expect("corrected") {
        let input = &corrected["in"];
        let policy = cmux_retry_policy_new(
            input[0].as_u64().expect("initial"),
            input[1].as_u64().expect("maximum"),
            input[2].as_i64().expect("timed"),
            input[3].as_i64().expect("socket"),
            input[4].as_bool().expect("keeps"),
        );
        assert_eq!(policy, policy_from(&corrected["policy"]));
    }
    for case in file["cases"].as_array().expect("cases") {
        let name = case["name"].as_str().expect("name");
        let random = case["random"].as_f64().expect("random");
        let mut pacer: CmuxRetryPacer = cmux_retry_pacer_new(policy_from(&case["policy"]));
        for (index, step) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let at = format!("{name}, step {index}");
            let p = &mut pacer as *mut CmuxRetryPacer;
            // SAFETY: a pacer owned by this test.
            unsafe {
                match step["op"].as_str().expect("op") {
                    "failed" => assert_eq!(
                        delay(cmux_retry_pacer_failed(p, random)),
                        step["expect"],
                        "{at}"
                    ),
                    "failed_at" => {
                        let ns = cmux_retry_pacer_failed_at(
                            p,
                            step["device"].as_u64().expect("device"),
                            step["inode"].as_u64().expect("inode"),
                            random,
                        );
                        assert_eq!(delay(ns), step["expect"], "{at}");
                    }
                    "failed_while_missing" => cmux_retry_pacer_failed_while_missing(p),
                    "refused_busy" => cmux_retry_pacer_refused_busy(p),
                    "reset" => cmux_retry_pacer_reset(p),
                    "woke" => {
                        let cause = match step["cause"].as_str().expect("cause") {
                            "event" => 0,
                            "socket" => 1,
                            "timer" => 2,
                            _ => 3,
                        };
                        cmux_retry_pacer_woke(p, cause);
                    }
                    "check" => {
                        let state = json!({
                            "exhausted": cmux_retry_pacer_is_exhausted(p),
                            "waits_for_event_only": cmux_retry_pacer_waits_for_event_only(p),
                            "wakes_on_socket": cmux_retry_pacer_wakes_on_socket(p),
                        });
                        assert_eq!(state, step["expect"], "{at}");
                    }
                    other => panic!("unknown step {other}"),
                }
            }
        }
    }
}

#[test]
fn op_vectors() {
    for case in vectors("ops.json")["cases"].as_array().expect("cases") {
        let op = case["op"].as_str().expect("op");
        assert_eq!(call(op, &case["request"]), case["expect"], "{}", case["source"]);
    }
}

#[test]
fn derived_uuid_vectors() {
    for case in vectors("scope_uuids.json")["uuids"].as_array().expect("uuids") {
        let got = call(
            "derived_uuid",
            &json!({"key": case["key"], "kind": case["kind"], "ordinal": case["ordinal"]}),
        );
        assert_eq!(got["uuid"], case["uuid"]);
    }
}

#[test]
fn scope_vectors() {
    for case in vectors("scope.json")["cases"].as_array().expect("cases") {
        let key = case["key"].as_str().unwrap_or_default();
        // SAFETY: the key's bytes.
        let scope = unsafe { cmux_daemon_scope_new(key.as_ptr(), key.len()) };
        assert!(!scope.is_null());
        for (index, step) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let op = CString::new(step["op"].as_str().expect("op")).expect("op");
            let request = serde_json::to_vec(&step["request"]).expect("request");
            let mut out = CmuxDaemonConnBytes { ptr: std::ptr::null_mut(), len: 0 };
            // SAFETY: a live handle and valid pointers.
            let code = unsafe {
                cmux_daemon_scope_call(
                    scope,
                    op.as_ptr(),
                    request.as_ptr(),
                    request.len(),
                    &mut out,
                )
            };
            assert_eq!(reply(code, out), step["expect"], "{}, step {index}", case["name"]);
        }
        // SAFETY: handed back once.
        unsafe { cmux_daemon_scope_free(scope) };
    }
}

#[test]
fn latency_vectors() {
    let file = vectors("latency.json");
    let bounds = call("latency_bounds", &json!({}));
    assert_eq!(bounds["bucket_count"], file["bucket_count"]);
    assert_eq!(
        cmux_daemon_latency_bucket_count() as u64,
        file["bucket_count"].as_u64().expect("count")
    );
    let all: Vec<u64> = serde_json::from_value(bounds["bounds_us"].clone()).expect("bounds");
    let first: Vec<u64> = serde_json::from_value(file["first_bounds_us"].clone()).expect("first");
    assert_eq!(all.get(..first.len()).expect("enough bounds"), first.as_slice());
    assert!(all.windows(2).all(|w| w[0] < w[1]));
    assert!(*all.last().expect("a bound") > 60_000_000, "the last bound is past a minute");

    let probe = cmux_daemon_latency_new();
    for record in file["records"].as_array().expect("records") {
        for _ in 0..record["times"].as_u64().expect("times") {
            // SAFETY: a live probe.
            unsafe {
                cmux_daemon_latency_record(
                    probe,
                    record["ns"].as_u64().expect("ns"),
                    u32::try_from(record["outcome"].as_u64().expect("outcome")).expect("outcome"),
                );
            }
        }
    }
    let mut counts = vec![0u64; cmux_daemon_latency_bucket_count()];
    let mut totals = CmuxDaemonLatencyTotals::default();
    // SAFETY: a live probe and buffers of the given sizes.
    let written = unsafe {
        cmux_daemon_latency_snapshot(probe, counts.as_mut_ptr(), counts.len(), &mut totals)
    };
    // SAFETY: handed back once.
    unsafe { cmux_daemon_latency_free(probe) };
    assert_eq!(written, counts.len());
    let expect = &file["expect"];
    assert_eq!(counts.iter().sum::<u64>(), expect["count"].as_u64().expect("count"));
    assert_eq!(totals.errors, expect["errors"].as_u64().expect("errors"));
    assert_eq!(totals.timeouts, expect["timeouts"].as_u64().expect("timeouts"));
    assert_eq!(totals.max_us, expect["max_us"].as_u64().expect("max"));
    let one_ms = call("latency_bucket", &json!({"us": 1000}))["bucket"].as_u64().expect("bucket");
    assert_eq!(
        counts[usize::try_from(one_ms).expect("index")],
        expect["bucket_of_1ms_count"].as_u64().expect("98")
    );
    for pair in expect["percentiles"].as_array().expect("percentiles") {
        let got = call(
            "latency_percentile",
            &json!({"counts": counts, "max_us": totals.max_us, "percent": pair[0]}),
        );
        assert_eq!(got["us"], pair[1], "p{}", pair[0]);
    }
}

#[test]
fn every_bound_and_its_neighbours_land_by_a_linear_search() {
    let bounds: Vec<u64> =
        serde_json::from_value(call("latency_bounds", &json!({}))["bounds_us"].clone())
            .expect("bounds");
    for (index, bound) in bounds.iter().enumerate() {
        assert_eq!(call("latency_bucket", &json!({"us": bound}))["bucket"], json!(index));
        assert_eq!(call("latency_bucket", &json!({"us": bound + 1}))["bucket"], json!(index + 1));
        if index > 0 {
            assert_eq!(call("latency_bucket", &json!({"us": bound - 1}))["bucket"], json!(index));
        }
    }
}

#[test]
fn heartbeat_through_the_c_abi() {
    let mut beat: CmuxHeartbeat = cmux_heartbeat_new();
    let mut tell = true;
    // SAFETY: a heartbeat owned by this test.
    let run = unsafe { cmux_heartbeat_start(&mut beat, &mut tell) };
    assert!(!tell, "a fresh heartbeat already answers");
    // SAFETY: as above.
    let steps: Vec<CmuxHeartbeatStep> = [false, false, true]
        .into_iter()
        .map(|answered| unsafe { cmux_heartbeat_tick(&mut beat, run, answered, 2, true) })
        .collect();
    assert_eq!(
        steps,
        vec![
            CmuxHeartbeatStep { action: 2, tell: false, answering: true },
            CmuxHeartbeatStep { action: 2, tell: true, answering: false },
            CmuxHeartbeatStep { action: 2, tell: true, answering: true },
        ]
    );
    // A bridged connection (its process unseen) closes after its misses.
    // SAFETY: as above.
    unsafe {
        assert_eq!(cmux_heartbeat_tick(&mut beat, run, false, 1, false).action, 1);
        assert!(!cmux_heartbeat_stop(&mut beat));
        assert_eq!(cmux_heartbeat_tick(&mut beat, run, false, 1, true).action, 0, "a stopped run");
    }
}

#[test]
fn error_classes_cover_every_kind_and_bad_input_is_refused() {
    let classes = call("error_classes", &json!({}));
    assert_eq!(classes["kinds"].as_array().expect("kinds").len(), 17);
    assert_eq!(classes["classes"]["late_start"], json!(["terminalStartTimedOut", "timedOut"]));
    let op = CString::new("no_such_op").expect("op");
    let mut out = CmuxDaemonConnBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers.
    assert_eq!(
        unsafe { cmux_daemon_conn_call(op.as_ptr(), std::ptr::null(), 0, &mut out) },
        ERR_UNKNOWN_OP
    );
    let op = CString::new("handshake_verdict").expect("op");
    let bad = b"not json";
    // SAFETY: valid pointers.
    assert_eq!(
        unsafe { cmux_daemon_conn_call(op.as_ptr(), bad.as_ptr(), bad.len(), &mut out) },
        ERR_INVALID
    );
    // SAFETY: a null `out`.
    assert_eq!(
        unsafe { cmux_daemon_conn_call(op.as_ptr(), std::ptr::null(), 0, std::ptr::null_mut()) },
        ERR_NULL
    );
    assert_eq!(cmux_daemon_conn_abi_version(), ABI_VERSION);
}
