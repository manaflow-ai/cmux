//! The ssh backup carrier (S6 G4) end to end, short of a real sshd: the
//! real `cmux carrier dial` against the stand-in platform, whose answer
//! carries an `ssh` candidate and whose `ssh-endpoint` authorizes the
//! device's carrier key. The ssh client is a stand-in that records the
//! arguments the dial gave it (the ProxyCommand through the tunnel hub, the
//! pin, the key) and runs the carrier key's forced command itself: the real
//! `cmux-tui remote-link --stdio` into the machine daemon's link socket,
//! which is the same daemon the relay reaches. The `carrier_faults` ssh row
//! (G5) goes further: its fake ssh runs the dial's ProxyCommand, the real
//! `wg dial`, into a stand-in tunnel hub. A real sshd and a provider
//! WireGuard tunnel are left to the live probe: neither runs in CI.
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
    assert!(has(&format!("IdentityFile=\"{}\"", key.display())), "the carrier key: {args:?}");
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

/// The connect log once it holds `want`, waiting up to 10 s for it.
fn log_with(world: &SshWorld, want: &str) -> String {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let log = world.connect_log();
        if log.contains(want) {
            return log;
        }
        assert!(std::time::Instant::now() < deadline, "no {want:?} in the connect log: {log}");
        std::thread::sleep(Duration::from_millis(50));
    }
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
    // The rest of stderr (route lines, the fake ssh's and remote-link's own
    // words), printed for a failure's story.
    std::thread::spawn(move || {
        for line in stderr.lines().map_while(Result::ok) {
            eprintln!("dial stderr: {line}");
        }
    });
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
    // The resume's lines are written when its attempt ends, which may come
    // just after the replayed stream already flows.
    let log = log_with(&world, "phase=resume carrier=ssh:0 outcome=ok");
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

/// A session fails over to ssh and, when ssh goes down too, back to the
/// relay: the relay route connects a fresh group (the first one was closed
/// when the session left it) and the same mux connection still answers.
#[test]
fn a_session_fails_over_to_ssh_and_back_to_a_fresh_relay_group() {
    let world = world_ssh(true);
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    std::thread::spawn(move || {
        for line in stderr.lines().map_while(Result::ok) {
            eprintln!("dial stderr: {line}");
        }
    });
    let lines = lines(&mut child);
    let mut stdin = child.stdin.take().unwrap();
    let (_, pushed) = round_trip(&mut stdin, &lines, 1);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n");

    world.cut.send_replace(true);
    let (_, pushed) = round_trip(&mut stdin, &lines, 2);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n", "the same mux connection");
    log_with(&world, "phase=resume carrier=ssh:0 outcome=ok");

    // The relay is back; ssh goes down.
    world.cut.send_replace(false);
    std::fs::write(&world.ssh_cut, b"").unwrap();
    let (_, pushed) = round_trip(&mut stdin, &lines, 3);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n", "still the same mux connection");
    let log = log_with(&world, "phase=resume carrier=relay:0 outcome=ok");
    let connects =
        log.lines().filter(|l| l.starts_with("cloud.connect ") && l.contains(" phase=connect "));
    assert_eq!(connects.count(), 1, "no new dial: {log}");
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// ssh's own stderr never reaches the dial's: with the relay refused and
/// ssh failing loudly, every stderr line is the reply or a route line, and
/// what ssh said is in the connect log as one quoted field.
#[test]
fn a_failing_ssh_s_stderr_stays_out_of_the_dial_s_stderr_and_goes_to_the_log() {
    let world = world_ssh(false);
    std::fs::write(&world.ssh_junk, b"").unwrap();
    let mut child = Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "3000", "--wg-hub"])
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
        .unwrap();
    let mut stderr = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut stderr).unwrap();
    assert_ne!(wait(&mut child, Duration::from_secs(20)), Some(0), "{stderr}");
    let mut lines = stderr.lines();
    let reply: Value = serde_json::from_str(lines.next().unwrap_or_default()).expect(&stderr);
    assert_eq!(reply["ok"], false, "{stderr}");
    for line in lines {
        assert!(line.starts_with("cloud.connect route=carrier "), "only route lines: {stderr}");
    }
    // ssh's words appear only inside the reply's JSON string, never raw.
    assert!(!stderr.lines().any(|line| line.starts_with("ssh:")), "{stderr}");
    let log = world.connect_log();
    assert!(
        log.contains(&format!(
            " ssh_stderr=\"ssh: connect to host {SSH_HOST} port 22: Connection refused {{'ok': 'junk'}}\"\n"
        )),
        "{log}"
    );
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

/// `cmux carrier capabilities --json` on the world's device: the dial's own
/// environment, and the default hub socket the dial uses too.
fn capabilities(world: &SshWorld) -> Value {
    let out = Command::new(BIN)
        .args(["carrier", "capabilities", "--json"])
        .env_clear()
        .env("HOME", world.dir.path())
        .output()
        .unwrap();
    assert!(out.status.success(), "capabilities: {out:?}");
    serde_json::from_slice(&out.stdout).unwrap()
}

/// [`round_trip`] for the row: when no line comes, the failure says what
/// the dial, the fake ssh and the stand-in hub saw.
fn row_round_trip(
    world: &SshWorld,
    stdin: &mut impl Write,
    lines: &mpsc::Receiver<String>,
    id: u32,
) -> String {
    let ask = format!("{{\"cmd\":\"identify\",\"id\":{id}}}\n");
    stdin.write_all(ask.as_bytes()).unwrap();
    stdin.flush().unwrap();
    let mut got = Vec::new();
    while got.len() < 2 {
        match lines.recv_timeout(Duration::from_secs(30)) {
            Ok(line) => got.push(line),
            Err(why) => {
                // The connect log's tail first: a CI log may keep only the
                // panic's first lines.
                let log = world.connect_log();
                let tail: Vec<&str> = log.lines().rev().take(12).collect();
                let tail: Vec<&str> = tail.into_iter().rev().collect();
                panic!(
                    "round trip {id}: {why:?} after {got:?}\nconnect log tail:\n{}\nhub dialed: {:?}\nssh args:\n{}",
                    tail.join("\n"),
                    world.hub_dialed.lock().unwrap(),
                    std::fs::read_to_string(&world.ssh_args).unwrap_or_default().replace('\n', " "),
                )
            }
        }
    }
    assert_eq!(got[0], ask, "the device's line reached the daemon");
    got.remove(1)
}

/// The `carrier_faults` ssh row for the Cloud carrier (goal
/// cloud-carrier-ssh-backup S2, G5), the one the failover probe's
/// capability gate stands for: with this device's tunnel hub up,
/// `carrier capabilities` lists ssh after the relay; a session on the relay
/// whose relay is cut resumes over ssh through the ProxyCommand's
/// `wg dial` (to the answer's mesh address), and when ssh is cut in turn it
/// comes back on the relay, on the same session and mux connection, with
/// no new dial. The tunnel and sshd are stand-ins ([`world_ssh_via_hub`]):
/// neither a WireGuard gateway nor sshd runs in CI.
#[test]
fn carrier_faults_ssh_row_relay_cut_fails_over_to_ssh_through_wg_dial_and_back() {
    let world = world_ssh_via_hub();
    let caps = capabilities(&world);
    assert_eq!(caps["carriers"]["ssh"]["available"], true, "ssh must be available: {caps}");
    assert_eq!(caps["routes"], json!(["relay", "ssh"]), "{caps}");
    assert_eq!(caps["faults"], json!(["kill-route"]), "{caps}");

    let started = std::time::Instant::now();
    // No --wg-hub: the dial looks at the default socket, as capabilities did.
    let mut child = Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000"])
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
    std::thread::spawn(move || {
        for line in stderr.lines().map_while(Result::ok) {
            eprintln!("dial stderr: {line}");
        }
    });
    let lines = lines(&mut child);
    let mut stdin = child.stdin.take().unwrap();
    let pushed = row_round_trip(&world, &mut stdin, &lines, 1);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n");
    let log = world.connect_log();
    assert!(log.contains("phase=connect ssh=on carrier=relay:0 outcome=ok"), "{log}");
    assert!(world.hub_dialed.lock().unwrap().is_empty(), "nothing through the tunnel yet");

    // Cut the relay: the session goes on over ssh, through `wg dial`.
    let relay_cut = std::time::Instant::now();
    world.cut.send_replace(true);
    let pushed = row_round_trip(&world, &mut stdin, &lines, 2);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n", "the same mux connection");
    let to_ssh = relay_cut.elapsed();
    log_with(&world, "phase=resume carrier=ssh:0 outcome=ok");
    let dialed = world.hub_dialed.lock().unwrap().clone();
    assert!(!dialed.is_empty(), "ssh went through the tunnel hub");
    assert!(dialed.iter().all(|d| *d == format!("{SSH_HOST}:22")), "{dialed:?}");
    let args = std::fs::read_to_string(&world.ssh_args).unwrap();
    let proxy = format!("ProxyCommand='{BIN}' wg dial --hub '{}' %h %p", world.hub.display());
    assert!(args.lines().any(|a| a == proxy), "{proxy} in {args}");

    // The relay is back; cut ssh (the tunnel): the session comes back on the relay.
    world.cut.send_replace(false);
    let ssh_cut = std::time::Instant::now();
    world.hub_cut.store(true, std::sync::atomic::Ordering::SeqCst);
    let pushed = row_round_trip(&world, &mut stdin, &lines, 3);
    assert_eq!(pushed, "{\"event\":\"pushed\",\"conn\":0}\n", "still the same mux connection");
    let to_relay = ssh_cut.elapsed();
    let log = log_with(&world, "phase=resume carrier=relay:0 outcome=ok");
    let connects =
        log.lines().filter(|l| l.starts_with("cloud.connect ") && l.contains(" phase=connect "));
    assert_eq!(connects.count(), 1, "no new dial: {log}");
    eprintln!(
        "carrier_faults row=cloud-ssh cut=relay,ssh relay_to_ssh_ms={} ssh_to_relay_ms={} total_ms={}",
        to_ssh.as_millis(),
        to_relay.as_millis(),
        started.elapsed().as_millis()
    );
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// A state directory ssh would expand (`${` in the path) is no ssh route
/// on either side: `carrier capabilities` says `no_key`, and the dial
/// connects on the relay with `ssh=no_key` in its route line.
#[test]
fn a_state_dir_ssh_would_expand_is_no_key_in_capabilities_and_the_dial() {
    let world = world_ssh(true);
    let home = world.dir.path().join("a${b}");
    std::fs::create_dir_all(&home).unwrap();
    let out = Command::new(BIN)
        .args(["carrier", "capabilities", "--json", "--wg-hub"])
        .arg(&world.hub)
        .env_clear()
        .env("HOME", &home)
        .output()
        .unwrap();
    assert!(out.status.success(), "capabilities: {out:?}");
    let caps: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(caps["carriers"]["ssh"]["code"], "no_key", "{caps}");
    assert_eq!(caps["routes"], json!(["relay"]), "{caps}");

    let mut child = Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000", "--wg-hub"])
        .arg(&world.hub)
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", &home)
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
    let log =
        std::fs::read_to_string(home.join(".local/state/cmux-tui/sessions/carrier/connect.log"))
            .unwrap_or_default();
    assert!(log.contains("phase=connect ssh=no_key carrier=relay:0 outcome=ok"), "{log}");
    assert!(world.ssh.asked.lock().unwrap().is_empty(), "no key asked without a route");
}
