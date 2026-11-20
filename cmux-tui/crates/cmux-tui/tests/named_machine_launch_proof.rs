#![cfg(unix)]

use std::collections::HashSet;
use std::io::{Read, Seek};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use wait_timeout::ChildExt as _;

fn invoke(binary: &str, args: &[&str]) -> (Duration, Value) {
    let mut stdout = tempfile::tempfile().unwrap();
    let start = Instant::now();
    let mut child = Command::new(binary)
        .args(args)
        .stdin(Stdio::null())
        .stdout(stdout.try_clone().unwrap())
        .spawn()
        .unwrap();
    let limit = Duration::from_secs(10);
    let status = child.wait_timeout(limit.saturating_sub(start.elapsed())).unwrap();
    let elapsed = start.elapsed();
    let Some(status) = status else {
        let _ = child.kill();
        let _ = child.wait();
        panic!("{args:?} exceeded ten seconds; inspect the machine before retrying");
    };
    assert!(status.success() && elapsed < limit, "{args:?}: {status} after {elapsed:?}");
    stdout.rewind().unwrap();
    let mut bytes = Vec::new();
    stdout.read_to_end(&mut bytes).unwrap();
    (elapsed, serde_json::from_slice(&bytes).unwrap())
}

#[test]
#[ignore = "creates ten real sessions on CMUX_PROOF_MACHINE using the installed CMUX_PROOF_BIN"]
fn ten_consecutive_named_machine_launches() {
    let machine = std::env::var("CMUX_PROOF_MACHINE").expect("name one joined lane machine");
    let binary = std::env::var("CMUX_PROOF_BIN").expect("path to the deployed cmux CLI");
    let mut ids = HashSet::new();
    for attempt in 1..=10 {
        let harness = if attempt % 2 == 1 { "codex" } else { "claude" };
        let (elapsed, result) = invoke(
            &binary,
            &["--json", "chat", "new", "--machine", &machine, "--harness", harness],
        );
        let target = result["session_id"].as_str().expect("no remote chat reference");
        let id = result["remote_session_id"].as_str().expect("no confirmed session");
        let url = result["link"].as_str().expect("no session link");
        let link = acpmux::agent_link::find(url).expect("not a session link").unwrap();
        assert_eq!(link.harness, harness);
        assert_eq!(link.host.as_deref(), Some(machine.as_str()));
        assert!(ids.insert(id.to_owned()), "reused session: {id}");
        let (_, record) = invoke(&binary, &["acp", "session", "info", target, "--json"]);
        assert_eq!(record["sessionId"], id);
        assert_eq!(record["agentSessionId"].as_str(), Some(link.session.as_str()));
        println!("{attempt}/10 {harness} {}ms {url}", elapsed.as_millis());
    }
}
