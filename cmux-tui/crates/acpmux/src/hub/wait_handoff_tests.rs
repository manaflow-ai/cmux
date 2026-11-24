//! The waits a hibernating harness hands to the daemon (`wait_handoff.rs`).

use super::*;

#[test]
fn a_sleep_is_run_again_with_what_is_left_of_it() {
    assert_eq!(plan("sleep 600", 0).as_deref(), Some("sleep 600s"));
    assert_eq!(plan("sleep 600", 240_000).as_deref(), Some("sleep 360s"));
    assert_eq!(plan("sleep 10m; echo done", 60_500).as_deref(), Some("sleep 540s ; echo done"));
    assert_eq!(
        plan("sleep 1.5h && echo 'ci done'", 0).as_deref(),
        Some("sleep 5400s && echo 'ci done'")
    );
    // One about to end ends on its own: the harness stays up the second or so it has left.
    assert_eq!(plan("sleep 30", 29_500), None);
    assert_eq!(plan("sleep 30", 40_000), None);
}

#[test]
fn the_waits_agents_run_are_handed_over() {
    // What Claude Code runs in the background to wait on a process.
    assert_eq!(
        plan("timeout 3700 tail --pid=1465811 -f /dev/null >/dev/null 2>&1; echo done", 700_000)
            .as_deref(),
        Some("timeout 3000s tail --pid=1465811 -f /dev/null ; echo done")
    );
    assert!(plan("glaeda-gh wait pr manaflow-ai/cmux#54153 --sha abc123", 5_000).is_some());
    assert!(plan("/home/u/bin/glaeda-gh wait pr o/r#1 2>&1 | tail -20", 5_000).is_some());
    assert!(plan("acpmux pr-wait o/r#1", 0).is_some());
    assert!(plan("gh run watch 123 --exit-status", 0).is_some());
    assert!(plan("gh pr checks 12 --watch", 0).is_some());
    assert!(plan("timeout -k 5 1h gh run watch 9", 600_000).is_some_and(|c| c.contains("3000s")));
}

#[test]
fn anything_but_one_wait_keeps_the_harness_up() {
    for command in [
        // Work, not a wait.
        "npm run dev",
        "cargo test -p acpmux",
        "gh pr checks 12",
        "tail -f server.log",
        "glaeda-gh land o/r#1",
        // Expansion, groups and backgrounding: not run again.
        "sleep $DELAY",
        "sleep `cat f`",
        "(sleep 60)",
        "sleep 60 & echo x",
        "while true; do sleep 60; done",
        "sleep 60 > out.txt",
        "sleep 60 < in",
        "sleep 6\\0",
        // Two waits, or none.
        "sleep 60; sleep 60",
        "echo hi",
        // Work after a wait.
        "sleep 60 && make deploy",
        "sleep 60 | xargs rm",
        "sleep 60 &&",
        "'sleep 60",
    ] {
        assert_eq!(plan(command, 0), None, "{command}");
    }
}

#[test]
fn a_planned_command_quotes_what_it_must() {
    assert_eq!(
        plan("sleep 5m; echo \"it's done\"", 0).as_deref(),
        Some(r"sleep 300s ; echo 'it'\''s done'")
    );
}

#[test]
fn the_census_lets_the_waits_own_processes_by() {
    assert!(covers("/bin/bash -c source /x/snapshot.sh && eval 'sleep 600' < /dev/null"));
    assert!(covers("sleep 600"));
    assert!(covers("timeout 3700 tail --pid=1 -f /dev/null"));
    assert!(covers("/usr/bin/python3 /home/u/bin/glaeda-gh wait pr o/r#1"));
    assert!(covers("gh api repos/o/r/pulls/1"));
    assert!(!covers("node /x/vite.js --port 5173"));
    assert!(!covers("cargo test"));
    assert!(!covers(""));
}

#[tokio::test]
async fn under_static_nothing_is_handed_over() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    assert_eq!(hub.wait_handoffs(&session), None);
    hub.set_idle_policy(super::super::residency::IdlePolicyKind::AdaptiveV1);
    // No shell runs: nothing to hand over, and nothing keeps it up.
    assert_eq!(hub.wait_handoffs(&session), None);
    assert_eq!(hub.idle_ready(&session), Some(Vec::new()));
}
