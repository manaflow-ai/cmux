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
    /// Each ADOPTED answer's ring end, with the bytes received before it.
    adopted: Mutex<Vec<(u64, usize)>>,
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
    fn adopted(&self, end: u64) {
        let received = self.bytes.lock().unwrap().len();
        self.adopted.lock().unwrap().push((end, received));
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

mod support;

#[test]
fn eight_threads_spawn_at_once_and_each_terminal_gets_only_its_own_output() {
    let dir = support::unique_dir("cmhl");
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

/// Review 2 of holder items 1-3: the daemon learns which ring a new holder
/// writes. The ADOPT hands over a descriptor that is no ring segment, so
/// the holder starts a fresh ring at `resume`; the link's answer is that
/// fresh segment (the daemon's new custody copy), and the output it gets
/// next is exactly what the holder writes there.
#[test]
fn an_adoption_answers_with_the_segment_the_new_holder_writes() {
    let dir = support::unique_dir("cmhla");
    let socket = dir.join("h.sock");
    let binary = std::path::Path::new(env!("CARGO_BIN_EXE_cmux-holder"));
    let mut first = cmux_holder::client::launch(binary, &socket, &TOKEN).unwrap();
    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();
    assert!(link.takes_rings(), "this build's holder takes ring segments");
    let sink = Arc::new(Collect::default());
    let spawned = link.spawn(1, &request(1, "echo up-1; exec cat"), sink.clone()).unwrap();
    wait_for("the first line", || {
        String::from_utf8_lossy(&sink.bytes.lock().unwrap()).contains("up-1")
    });
    let _ = first.kill();
    let _ = first.wait();
    wait_for("the lost link", || !link.is_open());

    let mut second = cmux_holder::client::launch(binary, &socket, &TOKEN).unwrap();
    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();
    let received = sink.bytes.lock().unwrap().len() as u64;
    let not_a_ring: OwnedFd = std::fs::File::create(dir.join("not-a-ring")).unwrap().into();
    let mut id = [0u8; 16];
    id[..4].copy_from_slice(&1u32.to_le_bytes());
    let answer = link
        .adopt(
            1,
            &id,
            (spawned.pid, received, received),
            (&spawned.master, Some(&not_a_ring)),
            (sink.clone(), b""),
        )
        .unwrap();
    let written = answer.wait().unwrap().expect("the holder names the fresh segment it writes");
    assert_eq!(cmux_holder::ring::segment_end(&written).unwrap(), received);
    // Review 2 of pl-holder-11: the sink hears where the ring it writes
    // ends (a fresh ring: at `resume`) before any output of the adopted
    // stream, so the daemon marks its loss at the right offset.
    assert_eq!(
        *sink.adopted.lock().unwrap(),
        vec![(received, received as usize)],
        "the ADOPTED answer reaches the sink once, before the new output"
    );
    std::fs::File::from(spawned.master.try_clone().unwrap()).write_all(b"after\n").unwrap();
    wait_for("the echo on the new holder", || {
        String::from_utf8_lossy(&sink.bytes.lock().unwrap()).contains("after\r\nafter")
    });
    let end = sink.bytes.lock().unwrap().len() as u64;
    wait_for("the holder's ring to hold what it sent", || {
        cmux_holder::ring::segment_end(&written).unwrap() >= end
    });
    link.close(1, 200).unwrap();
    wait_for("the exit", || sink.exit.lock().unwrap().is_some());
    let _ = second.kill();
    let _ = second.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 1 of pl-holder-11: a SPAWN whose answer comes after the spawn
/// timeout leaves no terminal on the holder. A stand-in holder takes the
/// SPAWN and its ATTACH and answers nothing: the spawn times out and the
/// link sends a CLOSE for the channel. The stand-in's late SPAWNED (nobody
/// waits for it any more) gets another CLOSE, and the output the terminal
/// prints meanwhile (no sink parses it) is acknowledged, so the shell never
/// blocks behind credit nobody gives and can end. Before, the holder kept
/// the shell, its PTY and its ring for the life of the link.
#[test]
fn a_spawn_that_times_out_leaves_no_terminal_on_the_holder() {
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::net::UnixListener;

    use cmux_holder::wire::{self, In, Kind, Out};

    let dir = support::unique_dir("cmhlt");
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let stand_in = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        // Only fails a link that never sends what this test waits for.
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let fd = stream.as_raw_fd();
        let mut reader = wire::Reader::default();
        let mut next = |what: &str| loop {
            if let Some(frame) = reader.next_frame().unwrap() {
                return frame;
            }
            match reader.fill(fd) {
                Ok(true) => {}
                other => panic!("the link sent no {what}: {other:?}"),
            }
        };
        let hello = next("HELLO");
        assert_eq!(hello.kind, Kind::Hello as u16);
        let welcome = Out::default().u16(wire::VERSION).u32(0).0;
        wire::send_all(fd, &wire::encode(Kind::Welcome, 0, &welcome), &[]).unwrap();
        let spawn = next("SPAWN");
        assert_eq!((spawn.kind, spawn.chan), (Kind::Spawn as u16, 1));
        let attach = next("ATTACH");
        assert_eq!((attach.kind, attach.chan), (Kind::Attach as u16, 1));
        let close = next("CLOSE after the spawn timed out");
        assert_eq!((close.kind, close.chan), (Kind::Close as u16, 1), "{close:?}");
        // The late answer, with a stand-in for the master.
        let mut ends = [0; 2];
        // SAFETY: pipe fills two descriptors this thread then owns.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both are fresh descriptors nothing else owns.
        let (read_end, _write_end) =
            unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
        let spawned = wire::encode_with_fds(Kind::Spawned, 0, 1, &Out::default().i32(4242).0, 1);
        wire::send_all(fd, &spawned, &[read_end.as_raw_fd()]).unwrap();
        let close = next("CLOSE for the late SPAWNED");
        assert_eq!((close.kind, close.chan), (Kind::Close as u16, 1), "{close:?}");
        // Output nobody parses is consumed.
        let (offset, output) = (0u64.to_le_bytes(), [b'x'; 100]);
        let data = wire::encode_parts(Kind::Data, 0, 1, &[&offset[..], &output[..]]);
        wire::send_all(fd, &data, &[]).unwrap();
        let ack = next("ACK for output no sink parses");
        assert_eq!((ack.kind, ack.chan), (Kind::Ack as u16, 1), "{ack:?}");
        assert_eq!(In(&ack.payload).u64().unwrap(), 100);
        stream
    });
    let (link, _) = HolderLink::connect_with_spawn_timeout(
        &socket,
        &TOKEN,
        Box::new(|_| {}),
        Duration::from_millis(200),
    )
    .unwrap();
    let error = link.spawn(1, &request(1, "exec cat"), Arc::new(Collect::default())).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut, "{error}");
    let stream = stand_in.join().expect("the stand-in holder saw every frame it waits for");
    drop(stream);
    drop(link);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Holder-core review: an ATTACH or ADOPT the holder refuses ends the sink
/// that waits for it. The link had registered the sink and returned Ok, so
/// without a word that terminal's reader and wait would block for ever (a
/// frozen tab instead of one that reports its host lost).
#[test]
fn an_attach_or_adopt_the_holder_refuses_ends_its_sink() {
    let dir = support::unique_dir("cmhr");
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
    let _answer = link
        .adopt(1, &[9; 16], (spawned.pid, 0, 0), (&spawned.master, None), (adopter.clone(), b""))
        .unwrap();
    wait_for("the refused ADOPT", || adopter.refused.lock().unwrap().is_some());

    link.close(1, 200).unwrap();
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Holder-core deep review: a SPAWN the holder refuses at once (here: an
/// empty argv) fails that spawn, and nothing else. `HolderLink::spawn`
/// sends an ATTACH right behind its SPAWN, which the holder then refuses
/// too (it runs no terminal on that channel); that second refusal must not
/// reach the spawn's sink as a refused stream (a spurious "refused a
/// terminal's stream" and a lose of a sink nobody uses). Before, the link
/// removed only the spawn's waiter on the first refusal, so the second
/// found the sink unless the spawn's caller had already dropped it. A
/// spawn on another channel answers after both refusals, so the link has
/// routed them both when it returns.
#[test]
fn a_spawn_the_holder_refuses_at_once_never_reaches_its_sink() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let dir = PathBuf::from("/tmp").join(format!("cmhs-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let mut holder = cmux_holder::client::launch(
        std::path::Path::new(env!("CARGO_BIN_EXE_cmux-holder")),
        &socket,
        &TOKEN,
    )
    .unwrap();
    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();

    let refused = Arc::new(Collect::default());
    let empty = SpawnRequest { argv: Vec::new(), ..request(5, "") };
    let failed = link.spawn(5, &empty, refused.clone()).expect_err("an empty argv spawned");
    assert!(failed.to_string().contains("empty argv"), "failed elsewhere: {failed}");
    let next = Arc::new(Collect::default());
    link.spawn(6, &request(6, "exec cat"), next).unwrap();
    assert_eq!(
        refused.refused.lock().unwrap().as_deref(),
        None,
        "the refused SPAWN's ATTACH reached its sink"
    );

    link.close(6, 200).unwrap();
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
