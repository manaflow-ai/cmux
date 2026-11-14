//! What one page frame's check costs through the C ABI (the app's call per
//! page frame, off the main thread): the whole call (parse, rules, the reply
//! JSON) and, apart, the reply's JSON encode, for a small prompt, a 64 KiB
//! one and a 1 MiB one (an attached file). It prints the distributions
//! (p50, p95, p99, max) and fails only on a gross regression: a test build
//! is unoptimized, so the bounds are far above the measured values. The timed
//! test runs on its own (`--ignored --exact --test-threads=1 --nocapture`, see
//! its doc); the default run checks every frame size answers.

use cmux_agent_pane_policy::ffi::CheckInput;
use cmux_agent_pane_policy::ffi::{
    CmuxAgentPaneBytes, CmuxAgentPanePolicy, OK, Pane, cmux_agent_pane_policy_bytes_free,
    cmux_agent_pane_policy_call, cmux_agent_pane_policy_check, cmux_agent_pane_policy_free,
    cmux_agent_pane_policy_new,
};
use serde_json::json;
use std::time::{Duration, Instant};

fn prompt(bytes: usize) -> String {
    let text = "x".repeat(bytes);
    json!({"jsonrpc": "2.0", "id": 12, "method": "session/prompt", "params": {
        "sessionId": "s1", "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": "p-1"}}}})
    .to_string()
}

struct Stats {
    p50: Duration,
    p95: Duration,
    p99: Duration,
    max: Duration,
}

fn stats(mut samples: Vec<Duration>) -> Stats {
    samples.sort();
    let at = |q: f64| samples[((samples.len() as f64 - 1.0) * q).round() as usize];
    Stats { p50: at(0.50), p95: at(0.95), p99: at(0.99), max: *samples.last().unwrap() }
}

fn print(label: &str, s: &Stats) {
    println!("{label}: p50 {:?} p95 {:?} p99 {:?} max {:?}", s.p50, s.p95, s.p99, s.max);
}

/// One pane with session `s1` added, through the C ABI.
fn pane_with_session() -> *mut CmuxAgentPanePolicy {
    let pane = cmux_agent_pane_policy_new();
    let op = c"add";
    let add = br#"{"session":"s1"}"#;
    let mut out = CmuxAgentPaneBytes { ptr: std::ptr::null_mut(), len: 0 };
    assert_eq!(
        unsafe {
            cmux_agent_pane_policy_call(pane, op.as_ptr(), add.as_ptr(), add.len(), &mut out)
        },
        OK
    );
    unsafe { cmux_agent_pane_policy_bytes_free(out) };
    pane
}

/// One check of `text` through the C ABI, which must answer OK with a reply holding the frame;
/// its wall-clock time.
fn check_once(pane: *mut CmuxAgentPanePolicy, text: &str, bytes: usize) -> Duration {
    let mut out = CmuxAgentPaneBytes { ptr: std::ptr::null_mut(), len: 0 };
    let start = Instant::now();
    let code = unsafe {
        cmux_agent_pane_policy_check(
            pane,
            text.as_ptr(),
            text.len(),
            false,
            false,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            &mut out,
        )
    };
    let took = start.elapsed();
    assert_eq!(code, OK);
    assert!(out.len > bytes, "the reply holds the checked frame");
    unsafe { cmux_agent_pane_policy_bytes_free(out) };
    took
}

/// Each frame size, a small prompt to a 1 MiB one, checked through the C ABI answers OK with
/// a reply that holds the frame, check after check. The default run's check; the time each
/// takes is `c_abi_one_check_per_page_frame_stays_cheap`, in its own run.
#[test]
fn c_abi_check_answers_every_frame_size() {
    let pane = pane_with_session();
    for bytes in [256, 64 << 10, 1 << 20] {
        let text = prompt(bytes);
        for _ in 0..3 {
            check_once(pane, &text, bytes);
        }
    }
    unsafe { cmux_agent_pane_policy_free(pane) };
}

/// The timing, with a p95 bound per frame size: a percentile of wall-clock times, which a
/// loaded host beside it (the parallel test run) pushes past any bound, so it is a check for
/// its own run, one test at a time:
/// `cargo test -p cmux-agent-pane-policy --test ffi_bench c_abi_one_check_per_page_frame_stays_cheap -- --ignored --exact --test-threads=1 --nocapture`.
/// The default run keeps `c_abi_check_answers_every_frame_size`.
#[test]
#[ignore = "own run, one test at a time: a wall-clock p95 bound"]
fn c_abi_one_check_per_page_frame_stays_cheap() {
    let pane = pane_with_session();
    // (frame bytes, runs, a gross p95 bound for an unoptimized build)
    let sizes = [
        (256, 2000, Duration::from_millis(5)),
        (64 << 10, 300, Duration::from_millis(50)),
        (1 << 20, 30, Duration::from_millis(500)),
    ];
    for (bytes, runs, bound) in sizes {
        let text = prompt(bytes);
        let whole: Vec<Duration> = (0..runs).map(|_| check_once(pane, &text, bytes)).collect();
        // The reply's encode alone (what a typed reply would save).
        let core = Pane::new();
        core.sessions().add("s1");
        let reply = core.check(&text, &CheckInput::default());
        let mut encode = Vec::with_capacity(runs);
        for _ in 0..runs {
            let start = Instant::now();
            let bytes = serde_json::to_vec(&reply).unwrap();
            encode.push(start.elapsed());
            assert!(!bytes.is_empty());
        }
        let whole = stats(whole);
        print(&format!("check {} B frame ({runs} runs)", text.len()), &whole);
        print(&format!("  reply encode alone, {} B", text.len()), &stats(encode));
        assert!(whole.p95 < bound, "check of a {bytes} B frame: p95 {:?} >= {bound:?}", whole.p95);
    }
    unsafe { cmux_agent_pane_policy_free(pane) };
}
