//! Run against a deployed build with `CMUX_PROOF_BIN`, its release receipt's full
//! `CMUX_PROOF_COMMIT`, the registry's `CMUX_PROOF_MACHINE` and `CMUX_PROOF_HOSTNAME`
//! (the output of `hostname` read independently on the test VM). The two harnesses must
//! be signed in on that VM and allowed to run `hostname`. Only startup is timed.
#![cfg(unix)]

use std::collections::HashSet;
use std::io::{Read, Seek};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use wait_timeout::ChildExt as _;

const LAUNCH_LIMIT: Duration = Duration::from_secs(10);

fn invoke(binary: &str, args: &[&str], limit: Duration) -> (Duration, Value) {
    let mut stdout = tempfile::tempfile().unwrap();
    let start = Instant::now();
    let mut child = Command::new(binary)
        .args(args)
        .stdin(Stdio::null())
        .stdout(stdout.try_clone().unwrap())
        .spawn()
        .unwrap();
    let status = child.wait_timeout(limit.saturating_sub(start.elapsed())).unwrap();
    let elapsed = start.elapsed();
    let Some(status) = status else {
        let _ = child.kill();
        let _ = child.wait();
        panic!("{args:?} exceeded {limit:?}; inspect the machine before retrying");
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
    let commit = std::env::var("CMUX_PROOF_COMMIT").expect("full commit from the build receipt");
    let hostname = std::env::var("CMUX_PROOF_HOSTNAME").expect("hostname read on the test VM");
    assert!(commit.len() == 40 && commit.bytes().all(|c| c.is_ascii_hexdigit()));
    assert!(!hostname.is_empty() && !hostname.contains(char::is_whitespace));
    let (_, version) = invoke(&binary, &["--version", "--json"], LAUNCH_LIMIT);
    let build = version["build_commit"].as_str().expect("deployed binary has no build commit");
    assert_eq!(build, commit.as_str(), "wrong build; no sessions were started");
    let dir = tempfile::tempdir().unwrap();
    let run = dir.path().file_name().unwrap().to_str().unwrap();
    println!("cmux={build} machine={machine}");
    let mut ids = HashSet::new();
    for attempt in 1..=10 {
        let harness = if attempt % 2 == 1 { "codex" } else { "claude" };
        let suffix = format!("{run}-{attempt}");
        let expected = format!("received-{suffix} {hostname}");
        let path = dir.path().join(format!("prompt-{attempt}.txt"));
        std::fs::write(
            &path,
            format!("Run `hostname` in your shell. Join `received-` and `{suffix}`, then add a space and the hostname you read. Reply with that single line."),
        )
        .unwrap();
        let (elapsed, result) = invoke(
            &binary,
            &[
                "--json",
                "chat",
                "new",
                "--machine",
                &machine,
                "--harness",
                harness,
                "--prompt-file",
                path.to_str().unwrap(),
            ],
            LAUNCH_LIMIT,
        );
        let target = result["session_id"].as_str().expect("no remote chat reference");
        let id = result["remote_session_id"].as_str().expect("no confirmed session");
        let url = result["link"].as_str().expect("no session link");
        let link = acpmux::agent_link::find(url).expect("not a session link").unwrap();
        assert_eq!(link.harness, harness);
        assert_eq!(link.host.as_deref(), Some(machine.as_str()));
        assert!(ids.insert(id.to_owned()), "reused session: {id}");
        println!("{attempt}/10 {harness} launch={}ms {url}", elapsed.as_millis());
        // The first turn can take longer than the launch. Wait once for this attempt's
        // marker, then read assistant text: even a match in tool output is not a reply.
        let (_, matched) = invoke(
            &binary,
            &["acp", "wait", target, "--match", &expected, "--timeout", "90", "--json"],
            Duration::from_secs(95),
        );
        // A thought or streaming chunk can match before the turn has finished.
        invoke(
            &binary,
            &["acp", "wait", target, "--until", "ready", "--timeout", "90", "--json"],
            Duration::from_secs(95),
        );
        let (_, last) = invoke(&binary, &["acp", "last", target, "--json"], LAUNCH_LIMIT);
        let (_, record) =
            invoke(&binary, &["acp", "session", "info", target, "--json"], LAUNCH_LIMIT);
        assert_eq!(record["sessionId"], id);
        assert_eq!(record["agentSessionId"].as_str(), Some(link.session.as_str()));
        let routed = last["sessionId"].as_str().expect("no identity on assistant reply");
        assert!(
            routed == id
                || record["peer"].as_str().is_some_and(|peer| routed == format!("{peer}/{id}"))
        );
        assert_eq!(matched["sessions"][0]["sessionId"], routed);
        assert_eq!(
            last["replies"].as_array().unwrap().last().and_then(Value::as_str).map(str::trim),
            Some(expected.as_str())
        );
        println!("{attempt}/10 verified {routed} replied to its prompt file");
    }
}
