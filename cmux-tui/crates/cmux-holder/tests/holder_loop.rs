//! The holder's one event loop serves every terminal of a session, so no
//! daemon frame may stall it, and a daemon it replaces always learns why
//! (holder-core review). The test speaks the wire itself on a raw link,
//! so it controls exactly what the holder reads in one go and what this
//! side leaves unread.

#![cfg(unix)]

use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_holder::client::{HolderClient, launch};
use cmux_holder::holder::error_code;
use cmux_holder::wire::{self, Frame, In, Kind, Out, Reader};

const TOKEN: [u8; 32] = [0x4c; 32];

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!(
        "cmhl-{}-{}",
        std::process::id(),
        stamp % 1_000_000_000
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn kill(mut holder: Child) {
    let _ = holder.kill();
    let _ = holder.wait();
}

/// A daemon link spoken frame by frame: blocking reads, no reader thread.
struct RawLink {
    stream: UnixStream,
    reader: Reader,
}

impl RawLink {
    /// Connect, say HELLO and read the WELCOME of a holder that runs
    /// nothing.
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        wire::tune_socket(stream.as_raw_fd());
        let mut link = Self { stream, reader: Reader::default() };
        let hello = Out::default().u16(wire::VERSION).bytes(&TOKEN).0;
        link.send(&wire::encode(Kind::Hello, 0, &hello));
        let welcome = link.frame().unwrap().expect("the holder closed the link");
        assert_eq!(Kind::from_u16(welcome.kind), Some(Kind::Welcome));
        let mut input = In(&welcome.payload);
        input.u16().unwrap();
        assert_eq!(input.u32().unwrap(), 0, "a fresh holder lists no terminal");
        link
    }

    /// Write `bytes` (any number of frames) with one write.
    fn send(&self, bytes: &[u8]) {
        wire::send_all(self.stream.as_raw_fd(), bytes, &[]).unwrap();
    }

    /// The next frame; `None` once the holder closed the link.
    fn frame(&mut self) -> io::Result<Option<Frame>> {
        loop {
            if let Some(frame) = self.reader.next_frame()? {
                return Ok(Some(frame));
            }
            match self.reader.fill(self.stream.as_raw_fd()) {
                Ok(true) => {}
                Ok(false) => return Ok(None),
                // Linux reports a peer that closed with frames of ours
                // still unread as a reset, after every byte it sent.
                Err(error) if error.kind() == io::ErrorKind::ConnectionReset => return Ok(None),
                Err(error) => return Err(error),
            }
        }
    }
}

fn ping(nonce: u64) -> Vec<u8> {
    wire::encode(Kind::Ping, 0, &nonce.to_le_bytes())
}

/// A daemon replaced while the holder has more queued for it than the
/// socket takes still hears SUPERSEDED, as the last frame of a stream
/// that stays well formed, so it does not take the holder back. The old
/// daemon sends 4 MiB of PINGs and reads nothing: the holder reads them
/// (the write returns only once it took all but a socket buffer), so it has
/// queued far more PONGs than the socket holds when the new daemon comes.
#[test]
fn a_daemon_superseded_with_a_full_queue_still_hears_superseded_last() {
    const PINGS: u64 = 4 * 1024 * 1024 / 24;
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let mut old = RawLink::connect(&socket);
    let flood: Vec<u8> = (0..PINGS).flat_map(ping).collect();
    old.send(&flood);

    let (_new, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(listed.is_empty());
    let mut pongs = 0u64;
    let mut last = None;
    while let Some(frame) = old.frame().expect("the old link's stream broke mid-frame") {
        if Kind::from_u16(frame.kind) == Some(Kind::Pong) {
            let nonce = In(&frame.payload).u64().unwrap();
            assert_eq!(nonce, pongs, "PONGs come in order, none cut");
            pongs += 1;
        }
        last = Some(frame);
    }
    let last = last.expect("the old daemon got nothing");
    assert_eq!(
        Kind::from_u16(last.kind),
        Some(Kind::Error),
        "the old daemon's link ended without SUPERSEDED after {pongs} PONGs"
    );
    let mut input = In(&last.payload);
    assert_eq!((last.chan, input.u16().unwrap()), (0, Kind::Hello as u16));
    assert_eq!(input.u16().unwrap(), error_code::SUPERSEDED);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A SPAWN never stalls the loop that serves every other terminal: the
/// holder neither searches `PATH` itself nor waits for the child to enter
/// its directory and run its program (a directory on a dead network mount
/// would stop every terminal's output). A PING written in the same write
/// right behind a SPAWN that fails gets its PONG before that SPAWN's error:
/// the holder answered it while the child was still starting.
#[test]
fn a_spawn_never_stalls_the_holder_loop() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let mut link = RawLink::connect(&socket);
    let request = |chan: u32, cwd: &[u8], program: &[u8]| cmux_holder::SpawnRequest {
        id: [chan as u8; 16],
        cols: 80,
        rows: 24,
        cwd: cwd.to_vec(),
        argv: vec![program.to_vec()],
        env: vec![b"PATH=/nonexistent-cmux-holder-path:/usr/bin:/bin".to_vec()],
        ..cmux_holder::SpawnRequest::default()
    };
    let spawns = [
        (1, request(1, b"/nonexistent-cmux-holder-dir", b"/bin/sh"), "nonexistent-cmux-holder-dir"),
        (2, request(2, b"/tmp", b"cmux-no-such-program"), "cmux-no-such-program"),
    ];
    for (chan, request, named) in spawns {
        let mut bytes = wire::encode(Kind::Spawn, chan, &request.encode());
        bytes.extend_from_slice(&ping(u64::from(chan)));
        link.send(&bytes);
        let first = link.frame().unwrap().expect("the holder closed the link");
        assert_eq!(
            Kind::from_u16(first.kind),
            Some(Kind::Pong),
            "spawn {chan}: the PING waited for the SPAWN (frame {} on channel {})",
            first.kind,
            first.chan
        );
        assert_eq!(In(&first.payload).u64().unwrap(), u64::from(chan));
        let second = link.frame().unwrap().expect("the holder closed the link");
        assert_eq!((Kind::from_u16(second.kind), second.chan), (Some(Kind::Error), chan));
        let mut input = In(&second.payload);
        assert_eq!(input.u16().unwrap(), Kind::Spawn as u16);
        assert_eq!(input.u16().unwrap(), error_code::SPAWN_FAILED);
        let message = String::from_utf8_lossy(input.rest()).into_owned();
        assert!(message.contains(named), "spawn {chan}: {message}");
    }
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Holder-core deep review: a CLOSE with no grace written in the same
/// write as its SPAWN (and the ATTACH that follows a spawn) ends the child,
/// although the holder handles it before the child ran its program. A
/// SPAWN returns once it forked, so the child may not have called `setsid`
/// yet: it leads no group, the PTY has no foreground group, and it still
/// ignores the hang-up as the holder does. Before, the CLOSE signaled the
/// groups only: the SIGKILL missed a child that had not reached `setsid`,
/// and the grace was spent, so the program ran on under a closing terminal
/// that never ended. Each round is one write; any round whose child the
/// SIGKILL missed never gets its EXIT.
#[test]
fn a_close_right_behind_a_spawn_ends_the_child_before_it_runs_its_program() {
    const ROUNDS: u32 = 32;
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let mut link = RawLink::connect(&socket);
    link.stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    for chan in 1..=ROUNDS {
        let request = cmux_holder::SpawnRequest {
            id: [chan as u8; 16],
            cols: 80,
            rows: 24,
            cwd: b"/tmp".to_vec(),
            argv: vec![b"/bin/sleep".to_vec(), b"600".to_vec()],
            env: vec![b"PATH=/usr/bin:/bin".to_vec()],
            ..cmux_holder::SpawnRequest::default()
        };
        let mut bytes = wire::encode(Kind::Spawn, chan, &request.encode());
        bytes.extend_from_slice(&wire::encode(Kind::Attach, chan, &0u64.to_le_bytes()));
        bytes.extend_from_slice(&wire::encode(Kind::Close, chan, &0u32.to_le_bytes()));
        link.send(&bytes);
        let status = loop {
            let frame = link
                .frame()
                .unwrap_or_else(|error| panic!("round {chan}: no EXIT, the child runs on: {error}"))
                .expect("the holder closed the link");
            if frame.chan != chan {
                continue;
            }
            match Kind::from_u16(frame.kind) {
                Some(Kind::Exit) => {
                    let mut input = In(&frame.payload);
                    break (input.u8().unwrap(), input.i32().unwrap());
                }
                Some(Kind::Error) => {
                    let message = String::from_utf8_lossy(&frame.payload).into_owned();
                    panic!("round {chan}: an error instead of the EXIT: {message:?}")
                }
                _ => {}
            }
        };
        // Signaled (1) by the CLOSE's SIGKILL, and reaped: the holder sends
        // a started child's EXIT only once it read its status.
        assert_eq!(status, (1, libc::SIGKILL), "round {chan}: ended otherwise");
    }
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}
