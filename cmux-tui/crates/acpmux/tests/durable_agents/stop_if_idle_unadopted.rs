//! `session stop --if-idle` (`hub/stop_if_idle.rs`) never ends an agent host this daemon could
//! not adopt: what runs there is unknown to it, and the idle pass leaves such a host alone too.
//! A plain stop still ends it, as before.

use super::*;

#[tokio::test]
async fn a_conditional_stop_refuses_an_unadopted_host_and_a_plain_stop_still_ends_it() {
    let mut daemon = Daemon::new("ifidleunad", "approve-all");
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    rpc.call("session/prompt", prompt).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(rpc);
    assert!(alive(harness_pid), "SIGTERM ended the agent");
    // A record this build cannot read: the next daemon cannot adopt the host.
    let record = daemon.home.join("hosts").join(format!("{session}.json"));
    let mut unreadable: Value = serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap();
    unreadable["record_version"] = json!(99);
    std::fs::write(&record, unreadable.to_string()).unwrap();
    daemon.start();
    daemon.wait_event(&session, "host_unadoptable", |e| e["kind"] == "host_unadoptable");
    let mut rpc = daemon.rpc().await;
    let stop = json!({"sessionId": session, "ifIdle": true});
    let refused = rpc.reply("_acpmux/kill", stop).await;
    assert_eq!(refused["error"]["data"]["reason"], "busy", "{refused}");
    assert_eq!(refused["error"]["data"]["busyWith"], "unadopted_host", "{refused}");
    assert!(alive(harness_pid), "a refused conditional stop ended the unadopted host");
    rpc.call("_acpmux/kill", json!({"sessionId": session})).await;
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "a plain stop left the unadopted host running"
    );
}

/// Review 3 of #28439: host records that cannot be read (`ACPMUX_TEST_HOST_RECORDS_FAIL_FILE`)
/// prove no host gone, so a conditional stop is refused until they can be read; the host it may
/// hide runs on.
#[tokio::test]
async fn a_conditional_stop_refuses_while_the_host_records_cannot_be_read() {
    let flag = std::env::temp_dir().join(format!("amd-ifidle-records-flag-{}", std::process::id()));
    let flag_env = flag.to_string_lossy().into_owned();
    let env = [("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE", flag_env.as_str())];
    let mut daemon = Daemon::with_env("ifidlerec", "approve-all", &env);
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    rpc.call("session/prompt", prompt).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(rpc);
    assert!(alive(harness_pid), "SIGTERM ended the agent");
    std::fs::write(&flag, "").unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let refused = rpc.reply("_acpmux/kill", json!({"sessionId": session, "ifIdle": true})).await;
    let hidden_ran_on = alive(harness_pid);
    let _ = std::fs::remove_file(&flag);
    assert_eq!(refused["error"]["data"]["busyWith"], "unadopted_host", "{refused}");
    assert!(hidden_ran_on, "a refused conditional stop ended the host the records hid");
    rpc.call("_acpmux/kill", json!({"sessionId": session})).await;
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "a plain stop left the host running once the records could be read"
    );
}
