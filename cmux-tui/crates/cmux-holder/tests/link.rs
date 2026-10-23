//! The concurrent daemon link: spawns from several threads, output routed
//! per terminal, input written to the custody dup, exits reported, and the
//! lost-link callback when the holder dies.

#![cfg(unix)]

use std::io::Write;
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_holder::link::{HolderLink, TerminalSink};
use cmux_holder::{ExitStatus, SpawnRequest};

const TOKEN: [u8; 32] = [0x33; 32];

#[derive(Default)]
struct Collect {
    bytes: Mutex<Vec<u8>>,
    exit: Mutex<Option<ExitStatus>>,
    refused: Mutex<Option<String>>,
}

impl TerminalSink for Collect {
    fn data(&self, offset: u64, bytes: &[u8]) {
        let mut all = self.bytes.lock().unwrap();
        assert_eq!(offset, all.len() as u64, "offsets continue");
        all.extend_from_slice(bytes);
    }
    fn gap(&self, requested: u64, oldest: u64) {
        panic!("gap {requested}..{oldest}");
    }
    fn exit(&self, status: ExitStatus, _end: u64) {
        *self.exit.lock().unwrap() = Some(status);
    }
    fn refused(&self, message: &str) {
        *self.refused.lock().unwrap() = Some(message.to_string());
    }
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn request(chan: u32, script: &str) -> SpawnRequest {
    let mut id = [0u8; 16];
    id[..4].copy_from_slice(&chan.to_le_bytes());
    SpawnRequest {
        id,
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), script.as_bytes().to_vec()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec()],
        ..SpawnRequest::default()
    }
}

#[test]
fn eight_threads_spawn_at_once_and_each_terminal_gets_only_its_own_output() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let dir = PathBuf::from("/tmp").join(format!("cmhl-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let mut holder = cmux_holder::client::launch(
        std::path::Path::new(env!("CARGO_BIN_EXE_cmux-holder")),
        &socket,
        &TOKEN,
    )
    .unwrap();
    let (lost_tx, lost_rx): (Sender<()>, _) = channel();
    let (link, listed) = HolderLink::connect(
        &socket,
        &TOKEN,
        Box::new(move |_| {
            let _ = lost_tx.send(());
        }),
    )
    .unwrap();
    assert!(listed.is_empty());

    let spawned: Vec<(u32, Arc<Collect>, OwnedFd)> = std::thread::scope(|scope| {
        let handles: Vec<_> = (1..=8u32)
            .map(|chan| {
                let link = link.clone();
                scope.spawn(move || {
                    let sink = Arc::new(Collect::default());
                    let spawned = link
                        .spawn(
                            chan,
                            &request(chan, &format!("echo up-{chan}; exec cat")),
                            sink.clone(),
                        )
                        .unwrap();
                    assert!(spawned.ring.is_some(), "a version 4 holder passes the ring");
                    (chan, sink, spawned.master)
                })
            })
            .collect();
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    for (chan, sink, master) in &spawned {
        wait_for("the first line", || {
            String::from_utf8_lossy(&sink.bytes.lock().unwrap()).contains(&format!("up-{chan}"))
        });
        // Input goes straight to the custody dup, not through the holder.
        std::fs::File::from(master.try_clone().unwrap())
            .write_all(format!("in-{chan}\n").as_bytes())
            .unwrap();
    }
    for (chan, sink, _) in &spawned {
        wait_for("the echo", || {
            String::from_utf8_lossy(&sink.bytes.lock().unwrap())
                .contains(&format!("in-{chan}\r\nin-{chan}"))
        });
        let text = String::from_utf8_lossy(&sink.bytes.lock().unwrap()).into_owned();
        for other in 1..=8u32 {
            if other != *chan {
                assert!(
                    !text.contains(&format!("up-{other}\r")),
                    "terminal {chan} got terminal {other}'s output: {text:?}"
                );
            }
        }
    }
    for (chan, _, _) in &spawned {
        link.close(*chan, 500).unwrap();
    }
    let sinks: Vec<_> = spawned.iter().map(|(_, sink, _)| sink.clone()).collect();
    drop(spawned);
    for sink in &sinks {
        wait_for("the exit", || sink.exit.lock().unwrap().is_some());
    }

    let _ = holder.kill();
    let _ = holder.wait();
    lost_rx.recv_timeout(Duration::from_secs(10)).expect("the link reports the holder's death");
    assert!(!link.is_open());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Holder-core review: an ATTACH or ADOPT the holder refuses ends the sink
/// that waits for it. The link had registered the sink and returned Ok, so
/// without a word that terminal's reader and wait would block for ever (a
/// frozen tab instead of one that reports its host lost).
#[test]
fn an_attach_or_adopt_the_holder_refuses_ends_its_sink() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let dir = PathBuf::from("/tmp").join(format!("cmhr-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let mut holder = cmux_holder::client::launch(
        std::path::Path::new(env!("CARGO_BIN_EXE_cmux-holder")),
        &socket,
        &TOKEN,
    )
    .unwrap();
    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();

    // The holder runs no terminal 77.
    let unknown = Arc::new(Collect::default());
    link.attach(77, 0, unknown.clone()).unwrap();
    wait_for("the refused ATTACH", || unknown.refused.lock().unwrap().is_some());

    // Channel 1 is in use: an ADOPT of it is refused.
    let running = Arc::new(Collect::default());
    let spawned = link.spawn(1, &request(1, "exec cat"), running).unwrap();
    let adopter = Arc::new(Collect::default());
    link.adopt(1, &[9; 16], (spawned.pid, 0, 0), (&spawned.master, None), (adopter.clone(), b""))
        .unwrap();
    wait_for("the refused ADOPT", || adopter.refused.lock().unwrap().is_some());

    link.close(1, 200).unwrap();
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
