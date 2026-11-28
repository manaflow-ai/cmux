//! A `cmux carrier dial` held open through a person's pause sends nothing
//! while the machine reads paused and the caller is idle, and the caller's
//! next line still goes out (cmux-platform#1849: freestyle wakes a paused VM
//! on any inbound byte, and the dial's 2 s heartbeat woke it). On the
//! stand-in platform, real relay and real daemon of `carrier_dial.rs`, with a
//! proxy before the relay that counts every byte the dial sends.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use carrier_support::*;
use serde_json::{Value, json};

/// How long an idle session goes before it reads the machine, here.
const LOOK_MS: u64 = 1000;

fn dial(world: &World) -> Child {
    Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .env("CMUX_CARRIER_IDLE_LOOK_MS", LOOK_MS.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// A connected dial and its stream.
fn connected(world: &World) -> (Child, ChildStdin, BufReader<ChildStdout>) {
    let mut child = dial(world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply, json!({"ok": true, "path_state": "relay", "route": "carrier"}));
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    (child, stdin, stdout)
}

/// One caller line, and the daemon's echo and push back.
fn keystroke(stdin: &mut ChildStdin, stdout: &mut BufReader<ChildStdout>, id: u32) {
    let sent = format!("{{\"cmd\":\"identify\",\"id\":{id}}}\n");
    stdin.write_all(sent.as_bytes()).unwrap();
    stdin.flush().unwrap();
    assert_eq!(line(stdout), sent, "the caller's line reached the daemon");
    assert!(line(stdout).contains("\"event\":\"pushed\""), "and the daemon answered");
}

/// Waits up to `limit` for `done`; whether it came.
fn within(limit: Duration, done: impl Fn() -> bool) -> bool {
    let started = Instant::now();
    while !done() {
        if started.elapsed() > limit {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}

#[test]
fn an_idle_dial_sends_nothing_to_a_paused_machine_and_a_keystroke_still_goes_out() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world_counted(asked.clone());
    let (mut child, mut stdin, mut stdout) = connected(&world);
    keystroke(&mut stdin, &mut stdout, 1);
    let carriers = asked.load(Ordering::SeqCst);

    // The person pauses the machine. The idle session reads it asleep within
    // a look or two of its last send (a dial without the gate never reads).
    world.machine.set("paused");
    let read = within(Duration::from_secs(8), || world.machine.reads.load(Ordering::SeqCst) >= 1);
    std::thread::sleep(Duration::from_millis(1500));

    // Three heartbeat intervals (2 s each) and several looks: not one byte.
    let before = world.sent.load(Ordering::SeqCst);
    std::thread::sleep(Duration::from_secs(7));
    let after = world.sent.load(Ordering::SeqCst);
    assert_eq!(
        after - before,
        0,
        "an idle dial sent {} bytes toward a paused machine (machine read: {read})",
        after - before
    );
    assert!(
        world.machine.reads.load(Ordering::SeqCst) >= 3,
        "the idle session kept reading the machine, once per look"
    );
    assert_eq!(asked.load(Ordering::SeqCst), carriers, "and asked for no new carrier");

    // A keystroke: it goes out at once, and that byte is the wake.
    keystroke(&mut stdin, &mut stdout, 2);
    assert!(world.sent.load(Ordering::SeqCst) > after, "the keystroke went out");
    assert_eq!(asked.load(Ordering::SeqCst), carriers, "on the session held, no new carrier");

    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

#[test]
fn an_idle_dial_probes_again_once_the_machine_reads_up() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world_counted(asked.clone());
    let (mut child, mut stdin, mut stdout) = connected(&world);
    keystroke(&mut stdin, &mut stdout, 1);

    world.machine.set("paused");
    assert!(within(Duration::from_secs(8), || world.machine.reads.load(Ordering::SeqCst) >= 1));
    std::thread::sleep(Duration::from_millis(1500));
    let quiet = world.sent.load(Ordering::SeqCst);

    // Woken elsewhere (the phone, the app): the next read says so, and the
    // idle session's heartbeat comes back with no caller byte.
    world.machine.set("running");
    assert!(
        within(Duration::from_secs(8), || world.sent.load(Ordering::SeqCst) > quiet),
        "an idle dial probes a machine that reads up"
    );

    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}
