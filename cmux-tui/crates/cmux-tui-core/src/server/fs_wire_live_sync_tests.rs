//! `sync.live` through the real remote entry route ([`route_first_line`]: the gate, the owner's
//! scope, the remote client's registration, the line framing) with the Mac's half, the real
//! [`cmux_live_sync::Leader`], dialing it over a loopback socket pair per connection, as
//! `cmux link live serve` dials the machine link. Prints save-to-visible both ways.
//!
//! Leo: "we need to be able to toggle a chat on and off of autocloud".

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_live_sync::{Event, Leader};
use serde_json::Value;

use super::tests::{Home, peer, test_mux};
use super::*;
use crate::projection::{LineReader, LineWriter};

type Dialed = (LineReader<BufReader<UnixStream>>, LineWriter<UnixStream>);

/// One dial of `sync.live` for `at`: the daemon's side served by the real route on a thread of its
/// own, the answer read here (the Mac's `dial_on`), then the framed halves.
fn dial(entry: EntryFs, at: &str) -> std::io::Result<Dialed> {
    let (mac, daemon) = UnixStream::pair()?;
    std::thread::spawn(move || {
        let routed = route_first_line(&test_mux(), daemon, &FsGate, &peer(), entry);
        assert!(routed.is_none(), "a sync.live dial is served by the route, not handed on");
    });
    let line = serde_json::json!({"id": 1, "cmd": "sync.live", "root": at});
    (&mac).write_all(format!("{line}\n").as_bytes())?;
    let mut reader = BufReader::new(mac.try_clone()?);
    let mut answer = String::new();
    reader.read_line(&mut answer)?;
    let answer: Value = serde_json::from_str(answer.trim()).map_err(std::io::Error::other)?;
    if answer["ok"] != Value::Bool(true) {
        return Err(std::io::Error::other(format!(
            "{}: {}",
            answer["error_code"].as_str().unwrap_or_default(),
            answer["error"].as_str().unwrap_or_default()
        )));
    }
    Ok((LineReader::new(reader), LineWriter::binary(mac)))
}

fn wait_for(path: &Path, want: &[u8], within: Duration) -> Option<Duration> {
    let start = Instant::now();
    while start.elapsed() < within {
        if std::fs::read(path).is_ok_and(|got| got == want) {
            return Some(start.elapsed());
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    None
}

fn p50(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() / 2]
}

#[test]
fn a_dial_outside_the_roots_is_refused_with_its_code() {
    let home = Home::new("live-refused");
    let entry = home.entry();
    let error = dial(entry, "/").err().expect("refused");
    assert!(error.to_string().starts_with("sync.denied: "), "{error}");
    let error = dial(entry, "relative").err().expect("refused");
    assert!(error.to_string().starts_with("sync.bad_request: "), "{error}");
}

#[test]
fn edits_sync_both_ways_through_the_real_route() {
    let home = Home::new("live-route");
    let entry = home.entry();
    let vm: PathBuf = home.path.join("chat");
    let mac_base = Home::new("live-mac");
    let mac = mac_base.path.join("folder");
    std::fs::create_dir_all(&mac).unwrap();
    std::fs::write(mac.join("seeded.txt"), b"from the mac\n").unwrap();

    let (stop, stopped) = crossbeam_channel::unbounded::<()>();
    let (events, seen) = crossbeam_channel::unbounded::<Event>();
    let at = vm.display().to_string();
    let (leader_root, leader_state) = (mac.clone(), mac_base.path.join("state"));
    let leader = std::thread::spawn(move || {
        let mut leader = Leader::new(leader_root, leader_state, events).unwrap();
        leader.run(|| dial(entry, &at), &stopped);
    });

    // The first catch-up: the Mac's folder reaches the machine.
    assert!(
        wait_for(&vm.join("seeded.txt"), b"from the mac\n", Duration::from_secs(20)).is_some(),
        "the first catch-up never reached the machine; events: {:?}",
        seen.try_iter().collect::<Vec<_>>()
    );

    let rounds = 10;
    let (mut to_vm, mut to_mac) = (Vec::new(), Vec::new());
    for i in 0..rounds {
        let body = format!("mac edit {i}\n");
        std::fs::write(mac.join("mac.txt"), &body).unwrap();
        to_vm.push(
            wait_for(&vm.join("mac.txt"), body.as_bytes(), Duration::from_secs(10))
                .unwrap_or_else(|| panic!("mac edit {i} never reached the machine")),
        );
        let body = format!("vm edit {i}\n");
        std::fs::write(vm.join("vm.txt"), &body).unwrap();
        to_mac.push(
            wait_for(&mac.join("vm.txt"), body.as_bytes(), Duration::from_secs(10))
                .unwrap_or_else(|| panic!("vm edit {i} never reached the Mac")),
        );
    }
    let alerts: Vec<Event> =
        seen.try_iter().filter(|event| matches!(event, Event::Alert { .. })).collect();
    assert!(alerts.is_empty(), "alerts: {alerts:?}");
    eprintln!(
        "LIVE_SYNC_ROUTE save-to-visible p50: mac->vm {} ms, vm->mac {} ms ({rounds} edits each way, max {} / {} ms)",
        p50(to_vm.clone()).as_millis(),
        p50(to_mac.clone()).as_millis(),
        to_vm.iter().max().unwrap().as_millis(),
        to_mac.iter().max().unwrap().as_millis(),
    );
    stop.send(()).unwrap();
    leader.join().unwrap();
}
