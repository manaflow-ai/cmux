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
//!
//! On Windows the program runs on a pseudoconsole, and the bytes the server
//! reads are conhost's rendering of the program's output, not the file. The
//! reference is then a terminal that parsed exactly the bytes the server
//! read (the server writes them to `MUX2_TAP_DIR/<id>.raw` when that is set,
//! for this gate only), so the gate still proves that every byte is parsed
//! in order and that snapshot plus stream rebuild the server's terminal.
//! Whether conhost's rendering shows the file as a Unix PTY would is reported
//! separately (`conpty_screen_faithful`) and does not decide the result.
//! The program is this binary (`mux2-verify --cat FILE`): it waits for one
//! line, enables VT output, and writes the file.

use cmux_mux2::{self as proto, Stream as UnixStream};
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

/// `mux2-verify --cat FILE`: the program the Windows gate runs.
fn cat(file: &str) -> ! {
    use std::io::{BufRead, Write};
    let data = std::fs::read(file).unwrap_or_else(|e| die(e));
    let mut line = String::new();
    let _ = std::io::stdin().lock().read_line(&mut line);
    #[cfg(windows)]
    // SAFETY: switching our own console output to VT processing.
    unsafe {
        use windows_sys::Win32::System::Console::*;
        let out = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut mode = 0;
        GetConsoleMode(out, &mut mode);
        SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
    let mut out = std::io::stdout().lock();
    for chunk in data.chunks(64 << 10) {
        out.write_all(chunk).unwrap_or_else(|e| die(e));
    }
    let _ = out.flush();
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--cat") {
        cat(args.get(1).unwrap_or_else(|| die("--cat FILE")));
    }
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
    let mut ctl =
        proto::connect(&path).unwrap_or_else(|e| die(format!("connect {}: {e}", path.display())));

    // The program waits for one line before it prints, so the attach happens
    // at a known point. tty echo of that line is part of the expected bytes.
    #[cfg(unix)]
    let (script, enter) =
        (format!("read go; exec /bin/cat '{}'", file.replace('\'', "'\\''")), b"\n");
    #[cfg(unix)]
    let argv: [&[u8]; 3] = [b"/bin/sh", b"-c", script.as_bytes()];
    #[cfg(windows)]
    let (exe, enter) =
        (std::env::current_exe().unwrap_or_else(|e| die(e)).to_string_lossy().into_owned(), b"\r");
    #[cfg(windows)]
    let argv: [&[u8]; 3] = [exe.as_bytes(), b"--cat", file.as_bytes()];
    // Windows: the reference is the bytes the server read (see the top).
    let tap = std::env::var_os("MUX2_TAP_DIR").map(std::path::PathBuf::from);
    if cfg!(windows) && tap.is_none() {
        die("on Windows the server and this gate need MUX2_TAP_DIR (the same directory)");
    }
    let reply = call(&mut ctl, proto::CREATE, &proto::create_payload(cols, rows, b"", &argv));
    let id = u32::from_le_bytes(reply[..4].try_into().expect("id"));
    let idp = id.to_le_bytes();

    let mut viewer = proto::connect(&path).unwrap_or_else(|e| die(e));
    if !midway && !no_viewer {
        proto::write_frame(&mut viewer, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
    }
    let mut w = idp.to_vec();
    w.extend_from_slice(enter);
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
        let mut waiter = proto::connect(&path).unwrap_or_else(|e| die(e));
        call(&mut waiter, proto::WAIT, &idp);
    }

    if no_viewer {
        let mut waiter = proto::connect(&path).unwrap_or_else(|e| die(e));
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
                let c = u16::from_le_bytes([body[0], body[1]]);
                let r = u16::from_le_bytes([body[2], body[3]]);
                client = Some(parse(c, r, &body[4..]));
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
    // What a terminal shows for the file itself; on Unix that is the
    // reference, on Windows it is compared only to report conhost's fidelity.
    let mut file_view = parse(cols, rows, &expected);
    let file_screen = file_view.viewport_text().unwrap_or_else(|e| die(e)).into_bytes();
    let mut reference = match &tap {
        Some(dir) if cfg!(windows) => {
            let raw = std::fs::read(dir.join(format!("{id}.raw"))).unwrap_or_else(|e| die(e));
            parse(cols, rows, &raw)
        }
        _ => file_view,
    };
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
    let faithful = server_screen == file_screen;
    // MUX2_VERIFY_DUMP=DIR writes every replay, so a mismatch can be diffed.
    if let Some(dir) = std::env::var_os("MUX2_VERIFY_DUMP") {
        let dir = std::path::PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&dir);
        for (name, bytes) in [
            ("server.vt", &server_replay),
            ("client.vt", &client_replay),
            ("ref.vt", &ref_replay),
            ("server-rt.vt", &server_rt),
            ("client-rt.vt", &client_rt),
        ] {
            let _ = std::fs::write(dir.join(name), bytes);
        }
    }
    println!(
        "{{\"verify\":\"{}\",\"ok\":{ok},\"screen_match\":{screen_ok},\"replay_exact\":{replay_ok},\"replay_roundtrip\":{replay_rt_ok},\"bytes\":{},\"stream_bytes\":{stream_bytes},\"snapshots\":{snapshots},\"midway\":{midway},\"slow\":{slow},\"resize\":{resize},\"resync_ok\":{resync_ok},\"conpty_screen_faithful\":{faithful}}}",
        file.replace('\\', "/"),
        data.len()
    );
    if !ok {
        let first_diff = server_screen.iter().zip(&ref_screen).position(|(a, b)| a != b);
        eprintln!("first screen difference at byte {first_diff:?}");
        std::process::exit(1);
    }
}
