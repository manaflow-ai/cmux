//! `cmux-nat-probe`: one side of a NAT-traversal measurement (see the library docs).
//!
//! `cmux-nat-probe pair --role a|b --token HEX [--duration-ms N] [--pings N]`
//!
//! Signalling is line-based on stdin and stdout, so a runner can carry it over ssh:
//! - out `CANDS {json}`: this side's candidates and NAT report; the runner hands it to the peer.
//! - in `CANDS {json}`: the peer's.
//! - out `REBIND {json}` (side a): it moved to a new socket; the runner hands it to the peer.
//! - in `REBIND {json}` (side b): punch toward the peer's new candidates too.
//! - out `RESULT {json}`: the measurement; in `DONE`: stop now.
//!
//! With `--rendezvous HOST:PORT` the same lines go over one TCP connection to
//! `cmux-nat-probe rendezvous --listen ADDR`, which pairs the two sides that name one token and
//! relays each one's lines to the other. The rendezvous carries only candidates and results
//! (a few hundred bytes); the measured packets never touch it.
//!
//! `cmux-nat-probe stun` prints only the NAT report (reflexive addresses, whether the mapping
//! varies by destination, IPv6).

use std::collections::BTreeMap;
use std::io::{BufRead, Write};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs, UdpSocket};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_nat_probe::{Kind, Packet, quantile, stun_mapped, stun_request, usable_candidate};
use serde_json::{Value, json};

const STUN_SERVERS: [&str; 3] =
    ["stun.l.google.com:19302", "stun.cloudflare.com:3478", "stun1.l.google.com:19302"];
const PUNCH_EVERY: Duration = Duration::from_millis(50);
const PING_EVERY: Duration = Duration::from_millis(100);
const STUN_WAIT: Duration = Duration::from_millis(900);

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err((code, why)) => {
            eprintln!("cmux-nat-probe: {why}");
            std::process::ExitCode::from(code)
        }
    }
}

fn run(args: &[String]) -> Result<(), (u8, String)> {
    let flag =
        |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    match args.first().map(String::as_str) {
        Some("stun") => {
            let mut sides = Sides::bind();
            println!("{}", sides.gather());
        }
        Some("pair") => {
            let role_a = flag("--role").as_deref() == Some("a");
            let token = flag("--token")
                .and_then(|t| u64::from_str_radix(&t, 16).ok())
                .ok_or((2, "pair: --token HEX is required".to_string()))?;
            let duration = Duration::from_millis(
                flag("--duration-ms").and_then(|v| v.parse().ok()).unwrap_or(15_000),
            );
            let pings = flag("--pings").and_then(|v| v.parse().ok()).unwrap_or(40u32);
            if let Some(rv) = flag("--rendezvous") {
                let fail = |err: std::io::Error| {
                    let why = format!("rendezvous {rv}: {err}");
                    println!("RESULT {}", json!({"error": why}));
                    (1, why)
                };
                let stream = std::net::TcpStream::connect(&rv).map_err(fail)?;
                let _ = stream.set_nodelay(true);
                let mut w = stream.try_clone().map_err(fail)?;
                let _ = writeln!(w, "HELLO {token:x} {}", if role_a { "a" } else { "b" });
                set_out(Box::new(Tee(w)));
                pair(role_a, token, duration, pings, Box::new(std::io::BufReader::new(stream)));
            } else {
                pair(
                    role_a,
                    token,
                    duration,
                    pings,
                    Box::new(std::io::BufReader::new(std::io::stdin())),
                );
            }
        }
        Some("rendezvous") => {
            rendezvous(
                &flag("--listen").unwrap_or_else(|| "0.0.0.0:47391".into()),
                args.iter().any(|a| a == "--answer"),
            )
            .map_err(|why| (1, why))?;
        }
        _ => {
            return Err((
                2,
                "usage: cmux-nat-probe stun | pair --role a|b --token HEX [--duration-ms N] \
                 [--pings N] [--rendezvous HOST:PORT] | rendezvous [--listen ADDR] [--answer]"
                    .into(),
            ));
        }
    }
    Ok(())
}

/// The two sockets a side punches from, one per address family.
struct Sides {
    v4: Option<UdpSocket>,
    v6: Option<UdpSocket>,
    sent: u64,
    recv: u64,
}

impl Sides {
    fn bind() -> Self {
        let open = |addr: &str| {
            UdpSocket::bind(addr).ok().inspect(|s| {
                let _ = s.set_nonblocking(true);
            })
        };
        Self { v4: open("0.0.0.0:0"), v6: open("[::]:0"), sent: 0, recv: 0 }
    }

    fn sock(&self, to: &SocketAddr) -> Option<&UdpSocket> {
        if to.is_ipv4() { self.v4.as_ref() } else { self.v6.as_ref() }
    }

    fn send(&mut self, to: &SocketAddr, bytes: &[u8]) {
        if let Some(s) = self.sock(to)
            && s.send_to(bytes, to).is_ok()
        {
            self.sent += bytes.len() as u64;
        }
    }

    /// STUN on each socket, then this side's candidates and NAT report as one JSON value.
    fn gather(&mut self) -> Value {
        let mut cands: Vec<SocketAddr> = Vec::new();
        let mut nat = serde_json::Map::new();
        for (fam, sock) in [("v4", self.v4.as_ref()), ("v6", self.v6.as_ref())] {
            let Some(sock) = sock else {
                nat.insert(fam.into(), json!({"socket": false}));
                continue;
            };
            let port = sock.local_addr().map(|a| a.port()).unwrap_or(0);
            let mapped = stun_all(sock, fam == "v6");
            let reflexive: Vec<String> = mapped.iter().map(|(_, a, _)| a.to_string()).collect();
            let distinct: std::collections::BTreeSet<_> =
                mapped.iter().map(|(_, a, _)| *a).collect();
            let stun_rtt: Vec<f64> = mapped.iter().map(|(_, _, ms)| *ms).collect();
            if let Some((_, first, _)) = mapped.first() {
                cands.push(*first);
            }
            if let Some(ip) = local_ip(fam == "v6") {
                let local = SocketAddr::new(ip, port);
                if usable_candidate(&local) && !cands.contains(&local) {
                    cands.push(local);
                }
            }
            nat.insert(
                fam.into(),
                json!({
                    "socket": true,
                    "reflexive": reflexive,
                    "servers_answered": mapped.len(),
                    "mapping_varies_by_dest": distinct.len() > 1,
                    "port_preserved": mapped.first().map(|(_, a, _)| a.port() == port),
                    "stun_rtt_ms_p50": quantile(&stun_rtt, 0.5),
                }),
            );
        }
        json!({"cands": cands.iter().map(ToString::to_string).collect::<Vec<_>>(), "nat": nat})
    }
}

/// Every STUN server's answer on `sock`: (server, mapped address, round trip ms).
fn stun_all(sock: &UdpSocket, v6: bool) -> Vec<(String, SocketAddr, f64)> {
    let mut asked = Vec::new();
    for (k, server) in STUN_SERVERS.iter().enumerate() {
        let Some(addr) =
            server.to_socket_addrs().ok().and_then(|mut it| it.find(|a| a.is_ipv6() == v6))
        else {
            continue;
        };
        let mut txid = [0u8; 12];
        txid[0] = k as u8;
        txid[1..9].copy_from_slice(
            &(Instant::now().elapsed().as_nanos() as u64 ^ rand_u64()).to_be_bytes(),
        );
        if sock.send_to(&stun_request(txid), addr).is_ok() {
            asked.push((server.to_string(), txid, Instant::now()));
        }
    }
    let mut out = Vec::new();
    let deadline = Instant::now() + STUN_WAIT;
    let mut buf = [0u8; 1500];
    while Instant::now() < deadline && out.len() < asked.len() {
        match sock.recv_from(&mut buf) {
            Ok((n, _)) => {
                for (server, txid, at) in &asked {
                    if let Some(mapped) = stun_mapped(&buf[..n], *txid) {
                        out.push((server.clone(), mapped, at.elapsed().as_secs_f64() * 1000.0));
                    }
                }
            }
            Err(_) => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    out
}

/// This host's source address toward the internet for one family (a connected UDP socket
/// sends nothing).
fn local_ip(v6: bool) -> Option<IpAddr> {
    let (bind, to) =
        if v6 { ("[::]:0", "[2001:4860:4860::8888]:53") } else { ("0.0.0.0:0", "8.8.8.8:53") };
    let s = UdpSocket::bind(bind).ok()?;
    s.connect(to).ok()?;
    s.local_addr().ok().map(|a| a.ip())
}

fn rand_u64() -> u64 {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    (t as u64) ^ (u64::from(std::process::id()) << 32)
}

fn parse_cands(v: &Value) -> Vec<SocketAddr> {
    v.get("cands")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|c| c.as_str()?.parse().ok()).collect())
        .unwrap_or_default()
}

#[derive(Default)]
struct Family {
    heard_ms: Option<f64>,
    direct_ms: Option<f64>,
    path: Option<SocketAddr>,
    rtt: Vec<f64>,
    pings_sent: u32,
    last_ping: Option<Instant>,
}

fn fam(addr: &SocketAddr) -> &'static str {
    if addr.is_ipv4() { "v4" } else { "v6" }
}

fn pair(role_a: bool, token: u64, duration: Duration, pings: u32, input: Box<dyn BufRead + Send>) {
    let start = Instant::now();
    let ms = |at: Instant| at.duration_since(start).as_secs_f64() * 1000.0;
    let mut sides = Sides::bind();
    let me = sides.gather();
    emit("CANDS", &me);

    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in input.lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let peer = loop {
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(line) => {
                if let Some(rest) = line.strip_prefix("CANDS ")
                    && let Ok(v) = serde_json::from_str::<Value>(rest)
                {
                    break v;
                }
            }
            Err(_) => {
                emit(
                    "RESULT",
                    &json!({"role": if role_a {"a"} else {"b"}, "error": "no peer candidates within 30 s", "nat": me["nat"]}),
                );
                return;
            }
        }
    };
    let mut targets = parse_cands(&peer);
    let punch_start = Instant::now();
    let deadline = punch_start + duration;
    let mut fams: BTreeMap<&'static str, Family> = BTreeMap::new();
    let mut last_punch: Option<Instant> = None;
    let mut seq = 0u32;
    let mut buf = [0u8; 1500];
    // Side a's rebind: a new v4 socket, as after a network change.
    let mut rebind: Option<(UdpSocket, Instant, Vec<SocketAddr>)> = None;
    let mut rebind_ms: Option<f64> = None;
    let mut rebind_note: Option<&'static str> = None;
    let mut done = false;

    while Instant::now() < deadline && !done {
        let now = Instant::now();
        while let Ok(line) = rx.try_recv() {
            if line == "DONE" {
                done = true;
            } else if let Some(rest) = line.strip_prefix("REBIND ")
                && let Ok(v) = serde_json::from_str::<Value>(rest)
            {
                for c in parse_cands(&v) {
                    if !targets.contains(&c) {
                        targets.push(c);
                    }
                }
            }
        }
        if last_punch.is_none_or(|t| now.duration_since(t) >= PUNCH_EVERY) {
            last_punch = Some(now);
            for to in targets.clone() {
                let heard = fams.get(fam(&to)).is_some_and(|f| f.heard_ms.is_some());
                seq += 1;
                let p = Packet { kind: Kind::Punch { heard }, token, seq, sent_us: 0 };
                sides.send(&to, &p.encode());
            }
            if let Some((sock, _, peer_paths)) = &rebind {
                for to in peer_paths {
                    seq += 1;
                    let p = Packet { kind: Kind::Punch { heard: true }, token, seq, sent_us: 0 };
                    if sock.send_to(&p.encode(), to).is_ok() {
                        sides.sent += p.encode().len() as u64;
                    }
                }
            }
        }
        // Side a pings each established path.
        if role_a {
            for f in fams.values_mut() {
                if let Some(path) = f.path
                    && f.pings_sent < pings
                    && f.last_ping.is_none_or(|t| now.duration_since(t) >= PING_EVERY)
                {
                    f.last_ping = Some(now);
                    f.pings_sent += 1;
                    let p = Packet {
                        kind: Kind::Ping,
                        token,
                        seq: f.pings_sent,
                        sent_us: start.elapsed().as_micros() as u64,
                    };
                    if let Some(s) =
                        if path.is_ipv4() { sides.v4.as_ref() } else { sides.v6.as_ref() }
                        && s.send_to(&p.encode(), path).is_ok()
                    {
                        sides.sent += p.encode().len() as u64;
                    }
                }
            }
            let pings_done = !fams.is_empty()
                && fams.values().all(|f| f.path.is_none() || f.pings_sent >= pings)
                && fams.get("v4").and_then(|f| f.path).is_some();
            if pings_done && rebind.is_none() && rebind_ms.is_none() {
                if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
                    let _ = sock.set_nonblocking(true);
                    let mapped = stun_all(&sock, false);
                    let port = sock.local_addr().map(|a| a.port()).unwrap_or(0);
                    let mut cands: Vec<String> =
                        mapped.first().map(|(_, a, _)| a.to_string()).into_iter().collect();
                    if let Some(ip) = local_ip(false) {
                        cands.push(SocketAddr::new(ip, port).to_string());
                    }
                    emit("REBIND", &json!({"cands": cands}));
                    let peer_paths: Vec<SocketAddr> =
                        targets.iter().filter(|a| a.is_ipv4()).copied().collect();
                    rebind = Some((sock, Instant::now(), peer_paths));
                } else {
                    rebind_note = Some("could not open a new socket");
                }
            }
        }
        let mut got_any = false;
        for which in 0..3 {
            let sock = match which {
                0 => sides.v4.as_ref(),
                1 => sides.v6.as_ref(),
                _ => rebind.as_ref().map(|r| &r.0),
            };
            let Some(sock) = sock else { continue };
            while let Ok((n, from)) = sock.recv_from(&mut buf) {
                got_any = true;
                sides.recv += n as u64;
                let Some(p) = Packet::decode(&buf[..n], token) else { continue };
                let at = Instant::now();
                if which == 2 {
                    if let Some((_, since, _)) = &rebind
                        && rebind_ms.is_none()
                    {
                        rebind_ms = Some(at.duration_since(*since).as_secs_f64() * 1000.0);
                    }
                    continue;
                }
                let f = fams.entry(fam(&from)).or_default();
                match p.kind {
                    Kind::Punch { heard } => {
                        f.heard_ms.get_or_insert(ms(at) - ms(punch_start));
                        if heard && f.direct_ms.is_none() {
                            f.direct_ms =
                                Some(at.duration_since(punch_start).as_secs_f64() * 1000.0);
                            f.path = Some(from);
                        }
                        if !targets.contains(&from) {
                            // The peer's mapping as we see it (a symmetric NAT's per-peer port).
                            targets.push(from);
                        }
                    }
                    Kind::Ping => {
                        let pong = Packet { kind: Kind::Pong, ..p };
                        if sock.send_to(&pong.encode(), from).is_ok() {
                            sides.sent += pong.encode().len() as u64;
                        }
                    }
                    Kind::Pong => {
                        let now_us = start.elapsed().as_micros() as u64;
                        f.rtt.push(now_us.saturating_sub(p.sent_us) as f64 / 1000.0);
                    }
                }
            }
        }
        if role_a && rebind_ms.is_some() {
            // Let the last pongs come in, then finish.
            std::thread::sleep(Duration::from_millis(150));
            break;
        }
        if !got_any {
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    let mut direct = serde_json::Map::new();
    for name in ["v4", "v6"] {
        let f = fams.get(name);
        let rtt = f.map(|f| f.rtt.as_slice()).unwrap_or(&[]);
        direct.insert(
            name.into(),
            json!({
                "ok": f.and_then(|f| f.direct_ms).is_some(),
                "time_to_direct_ms": f.and_then(|f| f.direct_ms),
                "first_heard_ms": f.and_then(|f| f.heard_ms),
                "path": f.and_then(|f| f.path).map(|p| p.to_string()),
                "rtt_ms_p50": quantile(rtt, 0.5),
                "rtt_ms_p95": quantile(rtt, 0.95),
                "pings": f.map_or(0, |f| f.pings_sent),
                "pongs": rtt.len(),
            }),
        );
    }
    emit(
        "RESULT",
        &json!({
            "role": if role_a {"a"} else {"b"},
            "nat": me["nat"],
            "peer_nat": peer["nat"],
            "direct": direct,
            "reconnect_after_rebind_ms": rebind_ms,
            "rebind_note": rebind_note.or(if role_a && rebind_ms.is_none() { Some("no direct reply on the new socket before the deadline") } else { None }),
            "bytes": {"sent": sides.sent, "recv": sides.recv},
            "elapsed_ms": ms(Instant::now()),
        }),
    );
}

static OUT: std::sync::OnceLock<std::sync::Mutex<Box<dyn Write + Send>>> =
    std::sync::OnceLock::new();

fn set_out(w: Box<dyn Write + Send>) {
    let _ = OUT.set(std::sync::Mutex::new(w));
}

/// Writes each line to the rendezvous and to stdout, so the runner's log has the result too.
struct Tee(std::net::TcpStream);

impl Write for Tee {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = std::io::stdout().write_all(buf);
        self.0.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        let _ = std::io::stdout().flush();
        self.0.flush()
    }
}

fn emit(tag: &str, v: &Value) {
    let line = format!("{tag} {v}\n");
    if let Some(out) = OUT.get() {
        let mut out = out.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = out.write_all(line.as_bytes());
        let _ = out.flush();
    } else {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(line.as_bytes());
        let _ = out.flush();
    }
}

/// Pairs the two connections that say `HELLO TOKEN ROLE` with one token and relays lines
/// between them; prints every RESULT line it relays, tagged with the token and the side's
/// address, so the runner reads both sides' results from here.
///
/// With `answer`, a side a whose token nobody waits on gets this host's own side b: the
/// rendezvous starts `cmux-nat-probe pair --role b` for that token, so any remote host can
/// measure its path to this one whenever its job runs, with no side b started by hand.
fn rendezvous(listen: &str, answer: bool) -> Result<(), String> {
    use std::collections::HashMap;
    use std::net::TcpStream;
    use std::sync::{Arc, Mutex};
    let listener = std::net::TcpListener::bind(listen)
        .map_err(|err| format!("rendezvous: bind {listen}: {err}"))?;
    eprintln!("rendezvous: listening on {listen}");
    let waiting: Arc<Mutex<HashMap<String, TcpStream>>> = Arc::default();
    let listen = listen.to_string();
    for conn in listener.incoming().map_while(Result::ok) {
        let waiting = Arc::clone(&waiting);
        let listen = listen.clone();
        std::thread::spawn(move || {
            let _ = conn.set_nodelay(true);
            let peer_addr = conn.peer_addr().map(|a| a.to_string()).unwrap_or_default();
            let Ok(read_half) = conn.try_clone() else { return };
            let mut reader = std::io::BufReader::new(read_half);
            let mut hello = String::new();
            if reader.read_line(&mut hello).is_err() {
                return;
            }
            let mut parts = hello.split_whitespace();
            let (Some("HELLO"), Some(token)) = (parts.next(), parts.next()) else { return };
            let token = token.to_string();
            let role_a = parts.next() == Some("a");
            let other = {
                let mut w = waiting.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                match w.remove(&token) {
                    Some(other) => other,
                    None => {
                        w.insert(token.clone(), conn);
                        if answer && role_a {
                            answer_side_b(&listen, &token);
                        }
                        // The second side's thread relays for both.
                        return;
                    }
                }
            };
            let other_addr = other.peer_addr().map(|a| a.to_string()).unwrap_or_default();
            let relay = |from: TcpStream, mut to: TcpStream, from_addr: String, token: String| {
                std::thread::spawn(move || {
                    for line in std::io::BufReader::new(from).lines().map_while(Result::ok) {
                        if line.starts_with("RESULT ") {
                            println!("{token} {from_addr} {line}");
                        }
                        if writeln!(to, "{line}").is_err() {
                            break;
                        }
                    }
                    let _ = to.shutdown(std::net::Shutdown::Write);
                })
            };
            let (Ok(other_read), Ok(conn_write)) = (other.try_clone(), conn.try_clone()) else {
                return;
            };
            let a = relay(other_read, conn_write, other_addr, token.clone());
            // This side's reader already consumed its HELLO line; relay the rest from it.
            let mut to = other;
            let me = std::thread::spawn({
                let token = token.clone();
                move || {
                    for line in reader.lines().map_while(Result::ok) {
                        if line.starts_with("RESULT ") {
                            println!("{token} {peer_addr} {line}");
                        }
                        if writeln!(to, "{line}").is_err() {
                            break;
                        }
                    }
                    let _ = to.shutdown(std::net::Shutdown::Write);
                }
            });
            let _ = a.join();
            let _ = me.join();
        });
    }
    Ok(())
}

/// Starts this host's side b for `token` against the rendezvous at `listen` (0.0.0.0 dials
/// loopback). Its RESULT reaches the runner through the rendezvous like any side's.
fn answer_side_b(listen: &str, token: &str) {
    let dial = listen.replace("0.0.0.0", "127.0.0.1");
    let spawned = std::env::current_exe().and_then(|exe| {
        std::process::Command::new(exe)
            .args(["pair", "--role", "b", "--token", token, "--rendezvous", &dial])
            .stdout(std::process::Stdio::null())
            .spawn()
    });
    match spawned {
        Ok(mut child) => {
            std::thread::spawn(move || child.wait());
        }
        Err(err) => eprintln!("rendezvous: answer {token}: {err}"),
    }
}
