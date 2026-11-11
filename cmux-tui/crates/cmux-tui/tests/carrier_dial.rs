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
    // The route line also went to the dial's own connect log, exactly,
    // followed by the attempt's phases line and its carriers line (which
    // stderr never gets): no ssh candidate in this answer, so the relay alone.
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    let text = std::fs::read_to_string(&log).unwrap();
    let (logged, rest) = text.split_at(route.len().min(text.len()));
    assert_eq!(logged, route, "connect.log starts with the route line: {text}");
    let (phases, routes) = rest.split_once('\n').unwrap_or((rest, ""));
    assert!(
        phases.starts_with(&format!(
            "carrier.phases machine={MACHINE} phase=connect carrier=relay:0 outcome=ok ticket_ms="
        )),
        "then one phases line: {text}"
    );
    assert_eq!(
        routes,
        format!(
            "carrier.routes machine={MACHINE} phase=connect ssh=no_candidate carrier=relay:0 outcome=ok\n"
        ),
        "then its carriers line and nothing else: {text}"
    );
    assert!(phases.contains(" lanes=") && !phases.contains("cloud.connect"), "{text}");
    let ms = route.trim_end().rsplit_once(" ms=").unwrap().1;
    assert!(!ms.is_empty() && ms.bytes().all(|b| b.is_ascii_digit()), "nothing after ms=: {route}");
}

/// A fresh machine's daemon registers after the dial's Connect: the relay
/// parks the Connect until then. A Register 20 s later, past the relay
/// client's 15 s control timeout, is still inside the dial's one deadline
/// (30 s here), so the first attempt connects: one route line, ok, and no
/// retry.
#[test]
fn a_dial_parked_until_the_daemon_registers_20_s_later_connects_on_its_first_attempt() {
    let world = world_parked(Duration::from_secs(20));
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply, json!({"ok": true, "path_state": "relay", "route": "carrier"}));
    let route = line(&mut stderr);
    let prefix =
        format!("cloud.connect route=carrier machine={MACHINE} phase=connect outcome=ok ms=");
    let ms: u64 = route
        .strip_prefix(&prefix)
        .and_then(|ms| ms.trim_end().parse().ok())
        .unwrap_or_else(|| panic!("not the first attempt's ok line: {route}"));
    assert!(ms >= 20_000, "connected after {ms} ms, before the daemon registered");

    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    stdin.write_all(b"{\"cmd\":\"identify\",\"id\":1}\n").unwrap();
    stdin.flush().unwrap();
    assert_eq!(line(&mut stdout), "{\"cmd\":\"identify\",\"id\":1}\n");
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    // The connect log has every attempt's route line (each followed by its
    // phases line): this one alone.
    assert_eq!(route_lines(&world), [route.trim_end()], "the dial retried");
}

/// The route lines of the dial's connect log, without its phases lines.
fn route_lines(world: &World) -> Vec<String> {
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    let text = std::fs::read_to_string(&log).unwrap();
    text.lines().filter(|l| l.starts_with("cloud.connect ")).map(str::to_owned).collect()
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
fn the_ok_line_says_the_grant_s_vmk() {
    for vmk in ["owner", "team"] {
        let world = world_signed(
            200,
            Arc::new(AtomicUsize::new(0)),
            "mux-control",
            DaemonKey::Real,
            Some(vmk),
        );
        let mut child = dial(&world);
        let mut stderr = BufReader::new(child.stderr.take().unwrap());
        let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
        assert_eq!(
            reply,
            json!({"ok": true, "path_state": "relay", "route": "carrier", "vmk": vmk}),
            "the daemon admitted the grant and the dial read its vmk"
        );
        drop(child.stdin.take());
        assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    }
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
    // The platform's status is the detail code, after ms, on stderr and in
    // the connect log alike.
    assert!(route.trim_end().ends_with(" detail=http_403"), "{route}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(2));
    assert_eq!(route_lines(&world), [route.trim_end()]);
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

/// The desktop is the machine owner's alone: this test's grants carry no
/// `vmk`, so the daemon refuses the desktop stream and the dial says so.
#[test]
fn a_desktop_dial_without_the_owner_grant_is_refused_as_a_service() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let mut child = dial_with(&world, &["--service", "desktop"]);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "service_refused", "{reply}");
    assert!(
        reply["error_detail"].as_str().unwrap().contains("does not allow local-socket"),
        "{reply}"
    );
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(6));
}

/// Another device's Noise key (base64url of 32 bytes of 5).
const OTHER_DEVICE: &str = "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU";

#[test]
fn a_handed_over_answer_is_the_first_attempt_s_without_asking_the_platform() {
    // Off a Mac each dial makes its own Noise key, so the handed-over grant
    // names another device's: the daemon refusing it shows the dial used it.
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let mut child = dial_with(&world, &["--answer-fd", "0"]);
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(world.answer_line(OTHER_DEVICE, true).as_bytes()).unwrap();
    stdin.flush().unwrap();
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    let route = line(&mut stderr);
    assert!(route.contains("phase=connect outcome=handshake"), "{route} {reply}");
    let keys = world.keys.lock().unwrap().clone();
    assert!(
        keys.iter().all(|key| key.as_deref() != Some(OTHER_DEVICE)),
        "the platform never named the other device: {keys:?}"
    );
    drop(stdin);
    let _ = wait(&mut child, Duration::from_secs(20));
}

#[test]
fn an_answer_line_that_is_not_an_answer_is_bad_usage() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    for bad in ["not json\n", "{\"carrier_answer\":{}}\n", ""] {
        let mut child = dial_with(&world, &["--answer-fd", "0"]);
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(bad.as_bytes()).unwrap();
        drop(stdin);
        let mut stderr = BufReader::new(child.stderr.take().unwrap());
        let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
        assert_eq!(reply["error_code"], "bad_request", "{bad:?}: {reply}");
        assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(64), "{bad:?}");
    }
}

#[test]
fn key_public_prints_no_key_where_none_lasts_past_one_dial() {
    let dir = tempfile::tempdir().unwrap();
    let run = |args: &[&str]| {
        Command::new(BIN)
            .arg("carrier")
            .args(args)
            .env_clear()
            .env("HOME", dir.path())
            .output()
            .unwrap()
    };
    // Off a Mac each dial makes its own key, so no key printed here could
    // be the one a later dial presents: nothing on stdout, dial's line.
    let out = run(&["key", "--public"]);
    assert!(out.stdout.is_empty(), "{:?}", String::from_utf8_lossy(&out.stdout));
    let reply: Value = serde_json::from_slice(&out.stderr).unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "handshake", "{reply}");
    assert_eq!(out.status.code(), Some(5));
    for bad in [&["key"][..], &["key", "--private"], &["key", "--public", "x"]] {
        let out = run(bad);
        assert!(out.stdout.is_empty());
        let reply: Value = serde_json::from_slice(&out.stderr).unwrap();
        assert_eq!(reply["error_code"], "bad_request", "{bad:?}: {reply}");
        assert_eq!(out.status.code(), Some(64), "{bad:?}");
    }
}
