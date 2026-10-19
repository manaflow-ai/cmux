//! `mux2-netbench`: what a remote user feels, measured at the client.
//!
//! Connects like any client (`MUX2_CONNECT=ADDR:PORT` for TCP, else the
//! Unix socket) and prints one JSON line per run:
//!
//!   mux2-netbench echo N [--flood FILE] [--gap-ms MS]
//!       N keystrokes typed into a terminal through an attached viewer, each
//!       timed from the WRITE until its tty echo reaches the viewer. With
//!       `--flood`, a second terminal loops `cat FILE` to its own attached
//!       viewer (another pane on the same link) the whole time (FILE must
//!       not contain `#`); `--flood-connect ADDR` and `--flood-kbps K`
//!       put that viewer on TCP and cap its read rate. Packets and bytes
//!       come from the kernel's TCP counters.
//!   mux2-netbench interrupt N FILE
//!       N times: loop `cat FILE` to an attached viewer, type Ctrl-C after
//!       the flood has run for a while, and time until the viewer shows the
//!       line the shell prints when the interrupt lands.
//!   mux2-netbench tput FILE
//!       `cat FILE` to an attached viewer: time to EXIT, bytes on the wire,
//!       packets, snapshots.
//!   mux2-netbench resize N
//!       N resizes of an attached terminal, each timed until the viewer has
//!       the snapshot at the new size.
//!
//! FILE paths are on the server's machine.

#[cfg(unix)]
fn main() {
    imp::main();
}

#[cfg(not(unix))]
fn main() {
    eprintln!("mux2-netbench: Unix only");
    std::process::exit(2);
}

#[cfg(unix)]
mod imp {
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    use cmux_mux2::net::{Stream, TcpCounters, counters};
    use cmux_mux2::{self as proto};

    fn die(msg: impl std::fmt::Display) -> ! {
        eprintln!("mux2-netbench: {msg}");
        std::process::exit(2);
    }

    fn open() -> Stream {
        match proto::net::connect_addr() {
            Some(addr) => {
                Stream::connect_tcp(&addr).unwrap_or_else(|e| die(format!("connect {addr}: {e}")))
            }
            None => {
                let path = proto::socket_path();
                Stream::Unix(
                    UnixStream::connect(&path)
                        .unwrap_or_else(|e| die(format!("connect {}: {e}", path.display()))),
                )
            }
        }
    }

    fn call(s: &mut Stream, kind: u8, payload: &[u8]) -> Vec<u8> {
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

    fn create(ctl: &mut Stream, cols: u16, rows: u16, script: &str) -> u32 {
        let argv: [&[u8]; 3] = [b"/bin/sh", b"-c", script.as_bytes()];
        let reply = call(ctl, proto::CREATE, &proto::create_payload(cols, rows, b"", &argv));
        u32::from_le_bytes(reply[..4].try_into().unwrap_or_else(|_| die("bad reply")))
    }

    fn quote(path: &str) -> String {
        format!("'{}'", path.replace('\'', "'\\''"))
    }

    fn pct(xs: &mut [f64], f: f64) -> f64 {
        if xs.is_empty() {
            return 0.0;
        }
        xs.sort_by(f64::total_cmp);
        xs[((xs.len() - 1) as f64 * f) as usize]
    }

    fn stats_field(ctl: &mut Stream, name: &str) -> u64 {
        let text = String::from_utf8_lossy(&call(ctl, proto::STATS, &[])).into_owned();
        text.lines()
            .find_map(|l| l.strip_prefix(name)?.strip_prefix('\t')?.parse().ok())
            .unwrap_or(0)
    }

    fn delta(a: Option<TcpCounters>, b: Option<TcpCounters>) -> String {
        match (a, b) {
            (Some(a), Some(b)) => format!(
                "\"tx_packets\":{},\"rx_packets\":{},\"tx_bytes\":{},\"rx_bytes\":{},\"retransmits\":{},\"srtt_ms\":{:.1}",
                b.tx_packets - a.tx_packets,
                b.rx_packets - a.rx_packets,
                b.tx_bytes - a.tx_bytes,
                b.rx_bytes - a.rx_bytes,
                b.retransmit_packets.saturating_sub(a.retransmit_packets),
                b.srtt_us as f64 / 1000.0
            ),
            _ => "\"tcp\":false".to_string(),
        }
    }

    /// What the viewer thread reports to the timing thread.
    enum Seen {
        /// A token appeared in the stream or in a snapshot.
        Token(u32),
        Snapshot {
            cols: u16,
            rows: u16,
        },
        Exit,
    }

    /// Reads the attached viewer's frames until EXIT or EOF, reporting
    /// tokens `#NNNNNN#` and snapshots. Returns frame and byte counts.
    fn viewer(mut v: Stream, tx: mpsc::Sender<Seen>) -> (u64, u64, u64) {
        let (mut frames, mut payload, mut snapshots) = (0u64, 0u64, 0u64);
        // The end of the previous frame, so a token cut between frames is seen.
        let mut tail: Vec<u8> = Vec::new();
        while let Ok((k, body)) = proto::read_frame(&mut v) {
            frames += 1;
            payload += body.len() as u64;
            let text: &[u8] = match k {
                proto::OUTPUT => &body,
                proto::SNAPSHOT if body.len() >= 4 => {
                    snapshots += 1;
                    let cols = u16::from_le_bytes([body[0], body[1]]);
                    let rows = u16::from_le_bytes([body[2], body[3]]);
                    let _ = tx.send(Seen::Snapshot { cols, rows });
                    tail.clear();
                    &body[4..]
                }
                proto::EXIT => {
                    let _ = tx.send(Seen::Exit);
                    break;
                }
                _ => continue,
            };
            let mut joined = std::mem::take(&mut tail);
            joined.extend_from_slice(text);
            let mut i = 0;
            while let Some(off) = joined[i..].iter().position(|b| *b == b'#') {
                let at = i + off;
                if joined.len() >= at + 8 && joined[at + 7] == b'#' {
                    if let Some(n) = std::str::from_utf8(&joined[at + 1..at + 7])
                        .ok()
                        .and_then(|d| d.parse().ok())
                    {
                        let _ = tx.send(Seen::Token(n));
                    }
                    i = at + 8;
                } else if joined.len() < at + 8 {
                    break;
                } else {
                    i = at + 1;
                }
            }
            let keep = joined.len().saturating_sub(7);
            tail = joined[keep..].to_vec();
        }
        (frames, payload, snapshots)
    }

    fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
        args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
    }

    fn echo(args: &[String]) {
        let n: u32 = args.first().and_then(|a| a.parse().ok()).unwrap_or(200);
        let flood = flag(args, "--flood");
        let gap = Duration::from_millis(
            flag(args, "--gap-ms").and_then(|v| v.parse().ok()).unwrap_or(30),
        );
        let timeout = Duration::from_secs(60);
        let mut ctl = open();
        // The flooding pane: its own terminal and viewer connection, read as
        // fast as the link allows and discarded.
        // `--flood-connect ADDR` puts the flooding viewer on TCP while the
        // measured pane uses the default transport, and `--flood-kbps`
        // caps how fast it reads, standing in for a slow link (each lag
        // then costs the server a snapshot of the flooding terminal).
        let flood_addr = flag(args, "--flood-connect").map(str::to_string);
        let flood_kbps: u64 = flag(args, "--flood-kbps").and_then(|v| v.parse().ok()).unwrap_or(0);
        let flood_term = flood.map(|f| {
            let ft = create(&mut ctl, 120, 40, &format!("while :; do cat {}; done", quote(f)));
            let mut fv = match &flood_addr {
                Some(a) => {
                    Stream::connect_tcp(a).unwrap_or_else(|e| die(format!("connect {a}: {e}")))
                }
                None => open(),
            };
            proto::write_frame(&mut fv, proto::ATTACH, &ft.to_le_bytes())
                .unwrap_or_else(|e| die(e));
            std::thread::spawn(move || {
                let chunk = if flood_kbps > 0 { 16 << 10 } else { 1 << 20 };
                let mut buf = vec![0u8; chunk];
                while matches!(std::io::Read::read(&mut fv, &mut buf), Ok(n) if n > 0) {
                    if let Some(us) = (16_000_000u64).checked_div(flood_kbps) {
                        std::thread::sleep(Duration::from_micros(us));
                    }
                }
            });
            ft
        });
        let t = create(&mut ctl, 120, 40, "exec cat >/dev/null");
        let idp = t.to_le_bytes();
        let mut v = open();
        let fd = v.raw_fd();
        proto::write_frame(&mut v, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
        let mut writer = v.try_clone().unwrap_or_else(|e| die(e));
        let (tx, rx) = mpsc::channel();
        let reader = std::thread::spawn(move || viewer(v, tx));
        // Let the snapshot and (with a flood) the backlog build up first.
        std::thread::sleep(Duration::from_millis(if flood.is_some() { 1500 } else { 200 }));
        let resyncs0 = stats_field(&mut ctl, "resyncs");
        let before = counters(fd);
        let mut lat = Vec::with_capacity(n as usize);
        let mut misses = 0;
        for i in 0..n {
            let mut w = idp.to_vec();
            // A newline each time: a canonical-mode tty stops echoing once
            // a line passes MAX_CANON (1024 bytes on macOS).
            w.extend_from_slice(format!("#{i:06}#\n").as_bytes());
            let start = Instant::now();
            proto::write_frame(&mut writer, proto::WRITE, &w).unwrap_or_else(|e| die(e));
            loop {
                match rx.recv_timeout(timeout.saturating_sub(start.elapsed())) {
                    Ok(Seen::Token(k)) if k == i => {
                        lat.push(start.elapsed().as_secs_f64() * 1e3);
                        break;
                    }
                    Ok(Seen::Exit) => die("terminal exited"),
                    Ok(_) => {}
                    Err(_) => {
                        misses += 1;
                        break;
                    }
                }
            }
            std::thread::sleep(gap);
        }
        let after = counters(fd);
        let resyncs = stats_field(&mut ctl, "resyncs") - resyncs0;
        call(&mut ctl, proto::KILL, &idp);
        if let Some(ft) = flood_term {
            call(&mut ctl, proto::KILL, &ft.to_le_bytes());
        }
        let _ = reader.join();
        let samples = lat.len();
        println!(
            "{{\"bench\":\"echo\",\"flood\":{},\"n\":{n},\"misses\":{misses},\"p50_ms\":{:.2},\"p95_ms\":{:.2},\"p99_ms\":{:.2},\"max_ms\":{:.2},\"resyncs\":{resyncs},{},\"per_key_tx_packets\":{:.2},\"per_key_rx_packets\":{:.2}}}",
            flood.map_or("null".to_string(), |f| format!("\"{f}\"")),
            pct(&mut lat, 0.5),
            pct(&mut lat, 0.95),
            pct(&mut lat, 0.99),
            pct(&mut lat, 1.0),
            delta(before, after),
            match (before, after) {
                (Some(a), Some(b)) => (b.tx_packets - a.tx_packets) as f64 / samples.max(1) as f64,
                _ => 0.0,
            },
            match (before, after) {
                (Some(a), Some(b)) => (b.rx_packets - a.rx_packets) as f64 / samples.max(1) as f64,
                _ => 0.0,
            },
        );
    }

    fn interrupt(args: &[String]) {
        let n: u32 = args.first().and_then(|a| a.parse().ok()).unwrap_or(10);
        let file = args.get(1).unwrap_or_else(|| die("interrupt N FILE"));
        let run_ms: u64 = flag(args, "--run-ms").and_then(|v| v.parse().ok()).unwrap_or(1500);
        let mut ctl = open();
        let mut lat = Vec::new();
        let (mut misses, mut rx_after) = (0, Vec::new());
        let resyncs0 = stats_field(&mut ctl, "resyncs");
        for i in 0..n {
            let script = format!(
                "trap 'printf \"\\n#%06d#\\n\" {i}; exec cat >/dev/null' INT; while :; do cat {}; done",
                quote(file)
            );
            let t = create(&mut ctl, 120, 40, &script);
            let idp = t.to_le_bytes();
            let mut v = open();
            let fd = v.raw_fd();
            proto::write_frame(&mut v, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
            let mut writer = v.try_clone().unwrap_or_else(|e| die(e));
            let (tx, rx) = mpsc::channel();
            let reader = std::thread::spawn(move || viewer(v, tx));
            std::thread::sleep(Duration::from_millis(run_ms));
            let mut w = idp.to_vec();
            w.push(0x03);
            let before = counters(fd);
            let start = Instant::now();
            proto::write_frame(&mut writer, proto::WRITE, &w).unwrap_or_else(|e| die(e));
            loop {
                match rx.recv_timeout(Duration::from_secs(120).saturating_sub(start.elapsed())) {
                    Ok(Seen::Token(k)) if k == i => {
                        lat.push(start.elapsed().as_secs_f64() * 1e3);
                        break;
                    }
                    Ok(Seen::Exit) | Err(_) => {
                        misses += 1;
                        break;
                    }
                    Ok(_) => {}
                }
            }
            if let (Some(a), Some(b)) = (before, counters(fd)) {
                rx_after.push((b.rx_bytes - a.rx_bytes) as f64 / 1e6);
            }
            call(&mut ctl, proto::KILL, &idp);
            let _ = writer.shutdown(std::net::Shutdown::Both);
            let _ = reader.join();
        }
        let resyncs = stats_field(&mut ctl, "resyncs") - resyncs0;
        println!(
            "{{\"bench\":\"interrupt\",\"file\":\"{file}\",\"n\":{n},\"misses\":{misses},\"p50_ms\":{:.1},\"max_ms\":{:.1},\"mb_after_ctrl_c_p50\":{:.2},\"resyncs\":{resyncs}}}",
            pct(&mut lat, 0.5),
            pct(&mut lat, 1.0),
            pct(&mut rx_after, 0.5)
        );
    }

    fn tput(args: &[String]) {
        let file = args.first().unwrap_or_else(|| die("tput FILE"));
        let mut ctl = open();
        let t = create(&mut ctl, 120, 40, &format!("read go; exec cat {}", quote(file)));
        let idp = t.to_le_bytes();
        let mut v = open();
        // A second handle keeps the socket open for the counters after the
        // viewer thread is done with it.
        let keep = v.try_clone().unwrap_or_else(|e| die(e));
        let fd = keep.raw_fd();
        proto::write_frame(&mut v, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
        let (tx, rx) = mpsc::channel();
        let before = counters(fd);
        let resyncs0 = stats_field(&mut ctl, "resyncs");
        let reader = std::thread::spawn(move || viewer(v, tx));
        // The first snapshot arrives before the program prints.
        while !matches!(rx.recv(), Ok(Seen::Snapshot { .. })) {}
        let mut w = idp.to_vec();
        w.extend_from_slice(b"\n");
        let start = Instant::now();
        call(&mut ctl, proto::WRITE, &w);
        let (frames, payload, snapshots) = reader.join().unwrap_or((0, 0, 0));
        let secs = start.elapsed().as_secs_f64();
        let after = counters(fd);
        let resyncs = stats_field(&mut ctl, "resyncs") - resyncs0;
        let bytes_in = stats_field(&mut ctl, "bytes_in");
        call(&mut ctl, proto::KILL, &idp);
        println!(
            "{{\"bench\":\"tput\",\"file\":\"{file}\",\"secs\":{secs:.3},\"payload_mb\":{:.1},\"mb_per_s\":{:.1},\"frames\":{frames},\"payload_bytes\":{payload},\"snapshots\":{snapshots},\"resyncs\":{resyncs},\"server_bytes_in_all\":{bytes_in},{}}}",
            payload as f64 / 1e6,
            payload as f64 / 1e6 / secs,
            delta(before, after)
        );
    }

    fn resize(args: &[String]) {
        let n: u32 = args.first().and_then(|a| a.parse().ok()).unwrap_or(50);
        let mut ctl = open();
        let t = create(&mut ctl, 120, 40, "exec cat >/dev/null");
        let idp = t.to_le_bytes();
        let mut v = open();
        proto::write_frame(&mut v, proto::ATTACH, &idp).unwrap_or_else(|e| die(e));
        let mut writer = v.try_clone().unwrap_or_else(|e| die(e));
        let (tx, rx) = mpsc::channel();
        let reader = std::thread::spawn(move || viewer(v, tx));
        while !matches!(rx.recv(), Ok(Seen::Snapshot { .. })) {}
        let mut lat = Vec::new();
        for i in 0..n {
            let (cols, rows) = if i % 2 == 0 { (100u16, 30u16) } else { (120, 40) };
            let mut p = idp.to_vec();
            p.extend_from_slice(&cols.to_le_bytes());
            p.extend_from_slice(&rows.to_le_bytes());
            let start = Instant::now();
            proto::write_frame(&mut writer, proto::RESIZE, &p).unwrap_or_else(|e| die(e));
            loop {
                match rx.recv_timeout(Duration::from_secs(10)) {
                    Ok(Seen::Snapshot { cols: c, rows: r }) if (c, r) == (cols, rows) => break,
                    Ok(_) => {}
                    Err(_) => die("no snapshot after resize"),
                }
            }
            lat.push(start.elapsed().as_secs_f64() * 1e3);
        }
        call(&mut ctl, proto::KILL, &idp);
        let _ = reader.join();
        println!(
            "{{\"bench\":\"resize\",\"n\":{n},\"p50_ms\":{:.2},\"p99_ms\":{:.2}}}",
            pct(&mut lat, 0.5),
            pct(&mut lat, 0.99)
        );
    }

    pub fn main() {
        let args: Vec<String> = std::env::args().skip(1).collect();
        match args.first().map(String::as_str) {
            Some("echo") => echo(&args[1..]),
            Some("tput") => tput(&args[1..]),
            Some("interrupt") => interrupt(&args[1..]),
            Some("resize") => resize(&args[1..]),
            _ => die(
                "echo N [--flood FILE] [--gap-ms MS] | interrupt N FILE [--run-ms MS] | tput FILE | resize N",
            ),
        }
    }
}
