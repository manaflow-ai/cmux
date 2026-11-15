//! A Cloud chat streams over `cmux carrier dial` while the link drops for
//! a few seconds or for longer than the session's resume deadline, as the
//! staging probe cloud-carrier-chaos-staging drops a machine's 443 traffic
//! for 5 s and 60 s mid-turn. The chat's records ride the carrier's bulk
//! lane (`agent-session-record` pushes). After the link is back, every
//! record appended before, during and after the drop reaches the dial's
//! stdout once and in order, or the dial ends (so its client dials again
//! and re-attaches from the last seq it holds). A dial that stays up while
//! its chat stream went silent is the failure: the client has no way to
//! know it must re-attach.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use carrier_support::host::{HostWorld, Mux, Restart, host_world};
use carrier_support::{BIN, MACHINE, TOKEN, line};
use serde_json::{Value, json};

fn dial(world: &HostWorld) -> Child {
    Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000"])
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

/// What the dial's stdout carried: each record's seq, and whether it ended.
#[derive(Default)]
struct Seen {
    seqs: Vec<u64>,
    ended: bool,
}

fn wait_until(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + limit;
    while Instant::now() < until {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    done()
}

fn drop_for(outage: Outage, hold: Duration) {
    let world = Arc::new(host_world(Restart::OnRequest, Mux::Records));
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    let notes = Arc::new(Mutex::new(Vec::<String>::new()));
    {
        let notes = notes.clone();
        std::thread::spawn(move || {
            for line in stderr.lines() {
                let Ok(line) = line else { return };
                notes.lock().unwrap().push(line);
            }
        });
    }
    let seen = Arc::new(Mutex::new(Seen::default()));
    {
        let seen = seen.clone();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        std::thread::spawn(move || {
            for line in stdout.lines() {
                let Ok(line) = line else { break };
                let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
                if let Some(seq) = event["record"]["seq"].as_u64() {
                    seen.lock().unwrap().seqs.push(seq);
                }
            }
            seen.lock().unwrap().ended = true;
        });
    }
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(format!("{}\n", json!({"cmd": "attach", "afterSeq": 0})).as_bytes()).unwrap();
    stdin.flush().unwrap();

    // The turn: a record every 20 ms, before, during and after the drop.
    let stop = Arc::new(AtomicBool::new(false));
    let appender = {
        let (world, stop) = (world.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                world.events.append();
                std::thread::sleep(Duration::from_millis(20));
            }
        })
    };
    assert!(
        wait_until(Duration::from_secs(20), || seen.lock().unwrap().seqs.len() >= 50),
        "the chat streamed before the drop"
    );

    match outage {
        Outage::Client => world.hold(),
        Outage::Machine => world.black_hole_machine(),
    }
    std::thread::sleep(hold);
    match outage {
        Outage::Client => world.release(),
        Outage::Machine => world.light_machine(),
    }
    std::thread::sleep(Duration::from_secs(3));
    stop.store(true, Ordering::SeqCst);
    appender.join().unwrap();
    let last = world.events.last();

    let caught_up = wait_until(Duration::from_secs(40), || {
        let seen = seen.lock().unwrap();
        seen.ended || seen.seqs.last() == Some(&last)
    });
    let seen = seen.lock().unwrap();
    let notes = notes.lock().unwrap().join("\n");
    let held = seen.seqs.last().copied().unwrap_or(0);
    let gap = seen.seqs.windows(2).find(|w| w[1] != w[0] + 1).map(|w| (w[0], w[1]));
    assert_eq!(gap, None, "the stream skipped: held {held} of {last}\n{notes}");
    assert!(
        caught_up,
        "the dial stayed up while its chat stream went silent: it held seq {held} of {last} \
         40 s after the link came back, so its client never knows to re-attach\n{notes}\n{}",
        world.connect_log()
    );
    if !seen.ended {
        assert_eq!(seen.seqs, (1..=last).collect::<Vec<_>>(), "every record once, in order");
    }
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
}

/// Where the network drops.
#[derive(Clone, Copy)]
enum Outage {
    /// The client's links to the relay are cut and new ones held.
    Client,
    /// The machine's links to the relay carry nothing, and nothing closes
    /// (the staging probe's iptables DROP of the machine's 443 traffic).
    Machine,
}

/// The machine's network drops for 5 s, shorter than the resume deadline.
#[test]
fn a_chat_streaming_through_a_5_s_machine_drop_gets_every_record() {
    drop_for(Outage::Machine, Duration::from_secs(5));
}

/// The machine's network drops for 60 s, as the probe's long drop.
#[test]
fn a_chat_streaming_through_a_60_s_machine_drop_gets_every_record_or_ends() {
    drop_for(Outage::Machine, Duration::from_secs(60));
}

/// The client's links drop for longer than the resume deadline
/// (`client::RESUME_DEADLINE`, 10 s).
#[test]
fn a_chat_streaming_through_a_25_s_client_drop_gets_every_record_or_ends() {
    drop_for(Outage::Client, Duration::from_secs(25));
}
