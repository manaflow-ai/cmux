//! `cmux carrier dial` end to end: the real binary fetches a ticket and a
//! grant from a local stand-in for cmux-platform, crosses a real cmux-relay,
//! and is admitted by a real cmux-remote daemon whose grant verifier trusts
//! a keyset made for this test. Bytes then flow both ways between the
//! dial's stdio and the daemon's mux socket. Every key is generated here.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use carrier_support::*;
use serde_json::{Value, json};

fn dial(world: &World) -> Child {
    dial_with(world, &[])
}

fn dial_with(world: &World, extra: &[&str]) -> Child {
    Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(extra)
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn a_carrier_dial_carries_the_daemon_stream_both_ways() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply, json!({"ok": true, "path_state": "relay", "route": "carrier"}));
    let route = line(&mut stderr);
    assert!(
        route.starts_with(&format!(
            "cloud.connect route=carrier machine={MACHINE} phase=connect outcome=ok ms="
        )),
        "{route}"
    );
    assert!(asked.load(Ordering::SeqCst) >= 1, "the ticket came from the platform");

    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    stdin.write_all(b"{\"cmd\":\"identify\",\"id\":1}\n").unwrap();
    stdin.flush().unwrap();
    assert_eq!(
        line(&mut stdout),
        "{\"cmd\":\"identify\",\"id\":1}\n",
        "the device's line reached the daemon"
    );
    assert_eq!(
        line(&mut stdout),
        "{\"event\":\"pushed\",\"conn\":0}\n",
        "the daemon's own line reached the device"
    );

    drop(stdin);
    let status = wait(&mut child, Duration::from_secs(20));
    assert_eq!(status, Some(0), "the dial ends when its stream ends");
    let teams = world.teams.lock().unwrap().clone();
    assert!(
        !teams.is_empty() && teams.iter().all(Option::is_none),
        "no team, no header: {teams:?}"
    );
    // The route line also went to the dial's own connect log, exactly.
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    let text = std::fs::read_to_string(&log).unwrap();
    assert_eq!(text, route, "connect.log holds the route line and nothing else");
    let ms = route.trim_end().rsplit_once(" ms=").unwrap().1;
    assert!(!ms.is_empty() && ms.bytes().all(|b| b.is_ascii_digit()), "nothing after ms=: {route}");
}

#[test]
fn a_named_team_goes_to_the_platform_as_x_cmux_team() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let mut child = dial_with(&world, &["--team", TEAM]);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    let teams = world.teams.lock().unwrap().clone();
    assert!(
        !teams.is_empty() && teams.iter().all(|t| t.as_deref() == Some(TEAM)),
        "every request names the team: {teams:?}"
    );
}

#[test]
fn a_refused_ticket_names_the_ticket_step() {
    let world = world(403, Arc::new(AtomicUsize::new(0)));
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error_code"], "ticket");
    assert!(reply["error_detail"].as_str().unwrap().contains("auth.forbidden"), "{reply}");
    let route = line(&mut stderr);
    assert!(route.contains("phase=connect outcome=ticket"), "{route}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(2));
}

#[test]
fn a_grant_without_mux_control_fails_the_handshake_before_ok() {
    let world = world_granting(200, Arc::new(AtomicUsize::new(0)), "tcp-tunnel");
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "handshake", "{reply}");
    let route = line(&mut stderr);
    assert!(route.contains("phase=connect outcome=handshake"), "{route}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(5));
}

/// The dial's reply line, its route line and exit code with `key` answered.
fn dial_with_key(key: DaemonKey) -> (Value, String, Option<i32>) {
    let world = world_full(200, Arc::new(AtomicUsize::new(0)), "mux-control", key);
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    let route = line(&mut stderr);
    (reply, route, wait(&mut child, Duration::from_secs(20)))
}

#[test]
fn an_answer_without_a_daemon_key_fails_at_the_ticket_before_any_handshake() {
    for key in [DaemonKey::Missing, DaemonKey::Malformed] {
        let (reply, route, code) = dial_with_key(key);
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error_code"], "ticket", "{reply}");
        assert_eq!(reply["error_detail"], "the machine has no daemon key", "{reply}");
        assert!(route.contains("phase=connect outcome=ticket"), "{route}");
        assert_eq!(code, Some(2));
    }
}

#[test]
fn a_daemon_that_is_not_the_pinned_one_fails_the_handshake() {
    let (reply, route, code) = dial_with_key(DaemonKey::Other);
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "handshake", "{reply}");
    assert!(route.contains("phase=connect outcome=handshake"), "{route}");
    assert_eq!(code, Some(5));
}
