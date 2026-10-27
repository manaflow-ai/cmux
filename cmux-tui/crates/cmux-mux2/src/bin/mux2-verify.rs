//! `mux2-verify FILE [--size COLSxROWS] [--attach-at-start | --attach-midway]`
//!
//! Correctness gate for mux2. Runs `cat FILE` in a mux2 terminal and checks
//! that three views of the result are identical:
//! 1. the server's terminal (SCREEN text and REPLAY bytes);
//! 2. a client that attached and rebuilt the terminal from SNAPSHOT plus the
//!    OUTPUT stream;
//! 3. a reference terminal that parsed the bytes the PTY must have produced
//!    (the file with the tty's ONLCR mapping applied), never touching mux2.
//!
//! Prints one JSON line and exits 0 only when all views match.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

use std::os::unix::net::UnixStream;

use cmux_mux2::{self as proto};
use ghostty_vt::{Callbacks, Terminal};

const SCROLLBACK: usize = 10_000_000;

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("mux2-verify: {msg}");
    std::process::exit(2);
}

fn call(s: &mut UnixStream, kind: u8, payload: &[u8]) -> Vec<u8> {
    proto::write_frame(s, kind, payload).unwrap_or_else(|e| die(e));
    loop {
        let (k, body) = proto::read_frame(s).unwrap_or_else(|e| die(e));
        match k {
            proto::OK | proto::EXIT => return body,
            proto::ERR => die(String::from_utf8_lossy(&body)),
            _ => {}
        }
    }
}

fn parse(cols: u16, rows: u16, bytes: &[u8]) -> Terminal {
    let mut t =
        Terminal::new(cols, rows, SCROLLBACK, Callbacks::default()).unwrap_or_else(|e| die(e));
    t.vt_write(bytes);
    t
}

/// The bytes a tty with default output processing emits for `data`: every
/// LF becomes CR LF (ONLCR). Nothing else applies to `cat` of a file.
fn onlcr(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + data.len() / 32);
    for &b in data {
        if b == b'\n' {
            out.push(b'\r');
        }
        out.push(b);
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let file = args
        .first()
        .unwrap_or_else(|| die("usage: mux2-verify FILE [--size CxR] [--attach-midway]"));
    let (mut cols, mut rows) = (120u16, 40u16);
    if let Some(i) = args.iter().position(|a| a == "--size") {
        let v = args.get(i + 1).unwrap_or_else(|| die("--size needs COLSxROWS"));
        let (c, r) = v.split_once('x').unwrap_or_else(|| die("size is COLSxROWS"));
        (cols, rows) =
            (c.parse().unwrap_or_else(|_| die("cols")), r.parse().unwrap_or_else(|_| die("rows")));
    }
    let midway = args.iter().any(|a| a == "--attach-midway");
    // The viewer reads nothing until the program has exited, so the server
    // must drop its backlog and resync it with a snapshot.
    let slow = args.iter().any(|a| a == "--slow-viewer");
    // Resize while output flows: the reference cannot know where the resize
    // landed, so the client must match the server exactly instead.
    let resize = args.iter().any(|a| a == "--resize-midway");
    // Nobody watches until the program has exited: every byte goes through
    // the unwatched path (batches, parse workers, carried tails), and the
    // viewer only checks the final snapshot.
    let no_viewer = args.iter().any(|a| a == "--no-viewer");
    let data = std::fs::read(file).unwrap_or_else(|e| die(e));
    let path = proto::socket_path();
    let mut ctl = UnixStream::connect(&path)
        .unwrap_or_else(|e| die(format!("connect {}: {e}", path.display())));

    // The program waits for one line before it prints, so the attach happens
    // at a known point. tty echo of that line is part of the expected bytes.
    let script = format!("read go; exec /bin/cat '{}'", file.replace('\'', "'\\''"));
    let argv: [&[u8]; 3] = [b"/bin/sh", b"-c", script.as_bytes()];
    let create = proto::create_payload(cols, rows, b"", &argv).unwrap_or_else(|e| die(e));
    let reply = call(&mut ctl, proto::CREATE, &create);
    let Some((id, _)) = reply.split_first_chunk::<4>() else { die("CREATE reply has no id") };
    let id = u32::from_le_bytes(*id);
    let idp = id.to_le_bytes();

    let mut viewer = UnixStream::connect(&path).unwrap_or_else(|e| die(e));
    if !midway && !no_viewer {
        proto::write_frame(&mut viewer, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
    }
    let mut w = idp.to_vec();
    w.extend_from_slice(b"\n");
    call(&mut ctl, proto::WRITE, &w);
    if midway || resize {
        // Attach while output is flowing: wait until the screen shows output
        // beyond the echoed line, so the snapshot holds real content and the
        // stream the rest.
        while call(&mut ctl, proto::SCREEN, &idp)
            .iter()
            .filter(|b| !b.is_ascii_whitespace())
            .count()
            < 64
        {}
        if midway {
            proto::write_frame(&mut viewer, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
        }
    }
    if resize {
        for (c, r) in [(cols / 2 + 7, rows / 2 + 3), (cols + 13, rows + 5), (cols, rows)] {
            let mut p = idp.to_vec();
            p.extend_from_slice(&c.to_le_bytes());
            p.extend_from_slice(&r.to_le_bytes());
            call(&mut ctl, proto::RESIZE, &p);
        }
    }
    if slow {
        let mut waiter = UnixStream::connect(&path).unwrap_or_else(|e| die(e));
        call(&mut waiter, proto::WAIT, &idp);
    }

    if no_viewer {
        let mut waiter = UnixStream::connect(&path).unwrap_or_else(|e| die(e));
        call(&mut waiter, proto::WAIT, &idp);
        proto::write_frame(&mut viewer, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
    }
    // Rebuild the terminal on the client side from what the server sent.
    let mut client: Option<Terminal> = None;
    let mut snapshots = 0u32;
    let mut stream_bytes = 0u64;
    loop {
        let (k, body) =
            proto::read_frame(&mut viewer).unwrap_or_else(|e| die(format!("viewer: {e}")));
        match k {
            proto::SNAPSHOT => {
                snapshots += 1;
                let Some((&[c0, c1, r0, r1], screen)) = body.split_first_chunk::<4>() else {
                    die("SNAPSHOT shorter than its size")
                };
                let (c, r) = (u16::from_le_bytes([c0, c1]), u16::from_le_bytes([r0, r1]));
                client = Some(parse(c, r, screen));
            }
            proto::OUTPUT => {
                stream_bytes += body.len() as u64;
                client.as_mut().unwrap_or_else(|| die("output before snapshot")).vt_write(&body);
            }
            proto::EXIT => break,
            proto::ERR => die(String::from_utf8_lossy(&body)),
            _ => {}
        }
    }
    let mut client = client.unwrap_or_else(|| die("no snapshot"));

    let server_screen = call(&mut ctl, proto::SCREEN, &idp);
    let server_replay = call(&mut ctl, proto::REPLAY, &idp);
    call(&mut ctl, proto::KILL, &idp);

    let mut expected = b"\r\n".to_vec();
    expected.extend_from_slice(&onlcr(&data));
    let mut reference = parse(cols, rows, &expected);
    let ref_screen = reference.viewport_text().unwrap_or_else(|e| die(e)).into_bytes();
    let ref_replay = reference.vt_replay_bytes().unwrap_or_else(|e| die(e));
    let client_screen = client.viewport_text().unwrap_or_else(|e| die(e)).into_bytes();
    let client_replay = client.vt_replay_bytes().unwrap_or_else(|e| die(e));
    // A replay is canonical: parse each replay in a fresh terminal and compare
    // those replays too, so equal state with different encodings still passes
    // only if it re-encodes identically.
    let server_rt = parse(cols, rows, &server_replay).vt_replay_bytes().unwrap_or_else(|e| die(e));
    let ref_rt = parse(cols, rows, &ref_replay).vt_replay_bytes().unwrap_or_else(|e| die(e));

    let client_rt = parse(cols, rows, &client_replay).vt_replay_bytes().unwrap_or_else(|e| die(e));
    let (screen_ok, replay_ok, replay_rt_ok) = if resize {
        (server_screen == client_screen, server_replay == client_replay, server_rt == client_rt)
    } else {
        (
            server_screen == ref_screen && client_screen == ref_screen,
            server_replay == ref_replay && client_replay == ref_replay,
            server_rt == ref_rt && client_rt == ref_rt,
        )
    };
    // The slow-viewer run only proves the resync path if it was taken.
    let resync_ok = !slow || snapshots >= 2;
    let ok = screen_ok && (replay_ok || replay_rt_ok) && resync_ok;
    println!(
        "{{\"verify\":\"{file}\",\"ok\":{ok},\"screen_match\":{screen_ok},\"replay_exact\":{replay_ok},\"replay_roundtrip\":{replay_rt_ok},\"bytes\":{},\"stream_bytes\":{stream_bytes},\"snapshots\":{snapshots},\"midway\":{midway},\"slow\":{slow},\"resize\":{resize},\"resync_ok\":{resync_ok}}}",
        data.len()
    );
    if !ok {
        let first_diff = server_screen.iter().zip(&ref_screen).position(|(a, b)| a != b);
        eprintln!("first screen difference at byte {first_diff:?}");
        std::process::exit(1);
    }
}
