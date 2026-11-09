//! The ssh backup carrier (S6 G4) end to end, short of a real sshd: the
//! real `cmux carrier dial` against the stand-in platform, whose answer
//! carries an `ssh` candidate and whose `ssh-endpoint` authorizes the
//! device's carrier key. The ssh client is a stand-in that records the
//! arguments the dial gave it (the ProxyCommand through the tunnel hub, the
//! pin, the key) and runs the carrier key's forced command itself: the real
//! `cmux-tui remote-link --stdio` into the machine daemon's link socket,
//! which is the same daemon the relay reaches. A real sshd and `wg dial`
//! through a provider tunnel are left to the live probe (G5): neither runs
//! in CI.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt as _;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use carrier_support::*;
use serde_json::{Value, json};

fn dial(world: &SshWorld) -> Child {
    Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000", "--wg-hub"])
        .arg(&world.hub)
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .env("CMUX_CARRIER_SSH_BINARY", &world.fake_ssh)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// The child's stdout lines, read on a thread so a test waits with a limit.
fn lines(child: &mut Child) -> mpsc::Receiver<String> {
    let (send, lines) = mpsc::channel();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    std::thread::spawn(move || {
        loop {
            let mut line = String::new();
            match stdout.read_line(&mut line) {
                Ok(n) if n > 0 => {
                    if send.send(line).is_err() {
                        return;
                    }
                }
                _ => return,
            }
        }
    });
    lines
}

fn next(lines: &mpsc::Receiver<String>, what: &str) -> String {
    lines.recv_timeout(Duration::from_secs(30)).unwrap_or_else(|_| panic!("no line: {what}"))
}

/// Writes one line to the daemon and reads its echo and the push that names
/// the mux connection it went out on.
fn round_trip(stdin: &mut impl Write, lines: &mpsc::Receiver<String>, id: u32) -> (String, String) {
    let ask = format!("{{\"cmd\":\"identify\",\"id\":{id}}}\n");
    stdin.write_all(ask.as_bytes()).unwrap();
    stdin.flush().unwrap();
    let echo = next(lines, "echo");
    assert_eq!(echo, ask, "the device's line reached the daemon");
    (echo, next(lines, "push"))
}

fn assert_ssh_ran_pinned_through_the_hub(world: &SshWorld) {
    let args = std::fs::read_to_string(&world.ssh_args).unwrap();
    let args: Vec<&str> = args.lines().collect();
    let key = world.ssh_state().join("id_ed25519");
    let pin = world.ssh_state().join(MACHINE).join("known_hosts");
    let has = |want: &str| args.contains(&want);
    assert!(has("-F") && has("/dev/null"), "{args:?}");
    assert!(has(key.to_str().unwrap()), "the carrier key: {args:?}");
    assert!(has("IdentitiesOnly=yes") && has("IdentityAgent=none"), "{args:?}");
    assert!(has("StrictHostKeyChecking=yes"), "{args:?}");
    assert!(has(&format!("UserKnownHostsFile=\"{}\"", pin.display())), "{args:?}");
    let proxy = format!("ProxyCommand='{BIN}' wg dial --hub '{}' %h %p", world.hub.display());
    assert!(has(&proxy), "{proxy} in {args:?}");
    assert!(has(&format!("cmux@{SSH_HOST}")) && has("22"), "{args:?}");
    // The pin is the ssh-endpoint answer's host key, owner-only.
    assert_eq!(std::fs::read_to_string(&pin).unwrap(), format!("{SSH_HOST} {}\n", ssh_host_key()));
    assert_eq!(std::fs::metadata(&pin).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(std::fs::metadata(&key).unwrap().permissions().mode() & 0o777, 0o600);
    // The platform authorized that key, as a carrier key.
    let asked = world.ssh.asked.lock().unwrap().clone();
    assert!(!asked.is_empty(), "ssh-endpoint was asked");
    let public = asked[0]["publicKey"].as_str().unwrap();
    assert!(public.starts_with("ssh-ed25519 "), "{public}");
    assert!(asked.iter().all(|a| a["purpose"] == "carrier"), "{asked:?}");
}

/// A relay that refuses every connect: the same attempt goes on to the ssh
/// group, which connects, and the stream works on it.
#[test]
fn a_dial_whose_relay_is_refused_connects_over_ssh_in_the_same_attempt() {
    let world = world_ssh(false);
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply, json!({"ok": true, "path_state": "relay", "route": "carrier"}));
    let route = line(&mut stderr);
    assert!(
        route.starts_with(&format!(
            "cloud.connect route=carrier machine={MACHINE} phase=connect outcome=ok ms="
        )),
        "one attempt, ok: {route}"
    );
    let lines = lines(&mut child);
    let mut stdin = child.stdin.take().unwrap();
    let (_, pushed) = round_trip(&mut stdin, &lines, 1);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n");
    assert_ssh_ran_pinned_through_the_hub(&world);
    let log = world.connect_log();
    assert!(
        log.contains(&format!(
            "carrier.routes machine={MACHINE} phase=connect ssh=on carrier=ssh:0 outcome=ok\n"
        )),
        "{log}"
    );
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// A session up on the relay loses it mid-stream: it resumes over ssh on
/// the same session (the same mux connection answers), with no new dial.
#[test]
fn a_session_on_the_relay_fails_over_to_ssh_and_keeps_its_stream() {
    let world = world_ssh(true);
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    let lines = lines(&mut child);
    let mut stdin = child.stdin.take().unwrap();
    let (_, pushed) = round_trip(&mut stdin, &lines, 1);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n");
    let log = world.connect_log();
    assert!(log.contains("phase=connect ssh=on carrier=relay:0 outcome=ok"), "{log}");
    assert!(!world.ssh_args.exists(), "no ssh before the relay failed");

    world.cut.send_replace(true);
    let (_, pushed) = round_trip(&mut stdin, &lines, 2);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n", "the same mux connection");
    assert_ssh_ran_pinned_through_the_hub(&world);
    let log = world.connect_log();
    assert!(log.contains("phase=resume carrier=ssh:0 outcome=ok"), "{log}");
    assert!(
        log.lines().any(|l| l.starts_with(&format!(
            "cloud.connect route=carrier machine={MACHINE} phase=resume outcome=ok"
        ))),
        "{log}"
    );
    let connects =
        log.lines().filter(|l| l.starts_with("cloud.connect ") && l.contains(" phase=connect "));
    assert_eq!(connects.count(), 1, "no new dial: {log}");
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// Without a tunnel hub the dial is the relay's alone, and says why.
#[test]
fn without_a_tunnel_hub_the_ssh_group_is_left_out_and_the_log_says_so() {
    let world = world_ssh(true);
    let mut child = Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000", "--wg-hub"])
        .arg(world.dir.path().join("no-hub.sock"))
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .env("CMUX_CARRIER_SSH_BINARY", &world.fake_ssh)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    let log = world.connect_log();
    assert!(log.contains("phase=connect ssh=no_tunnel carrier=relay:0 outcome=ok"), "{log}");
    assert!(world.ssh.asked.lock().unwrap().is_empty(), "no key asked without a route");
}
