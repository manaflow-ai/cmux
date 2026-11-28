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

use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::sync::{Mutex, MutexGuard, mpsc};
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
                let stream = TcpStream::connect(&rv).map_err(fail)?;
                let _ = stream.set_nodelay(true);
                let mut w = stream.try_clone().map_err(fail)?;
                let label: String = flag("--label")
                    .unwrap_or_default()
                    .chars()
                    .map(|c| if c.is_whitespace() { '_' } else { c })
                    .collect();
                let _ = writeln!(w, "HELLO {token:x} {} {label}", if role_a { "a" } else { "b" });
                set_out(Box::new(Tee(w)));
                let closer = stream.try_clone().map_err(fail)?;
                let input = Box::new(std::io::BufReader::new(stream));
                pair(role_a, token, duration, pings, input, Some(closer));
            } else {
                pair(
                    role_a,
                    token,
                    duration,
                    pings,
                    Box::new(std::io::BufReader::new(std::io::stdin())),
                    None,
                );
            }
        }
        Some("tailscale") => {
            let rv = flag("--rendezvous")
                .ok_or((2, "tailscale: --rendezvous HOST:PORT is required".to_string()))?;
            let peer = flag("--peer")
                .or_else(|| rv.rsplit_once(':').map(|(host, _)| host.to_string()))
                .unwrap_or_default();
            let count = flag("--count").unwrap_or_else(|| "20".into());
            let bin = flag("--tailscale-bin").unwrap_or_else(|| "tailscale".into());
            let result = tailscale_compare(&bin, &peer, &count);
            note(&rv, flag("--label").unwrap_or_default(), &result).map_err(|why| (1, why))?;
            println!("RESULT {result}");
        }
        Some("rendezvous") => {
            rendezvous(
                &flag("--listen").unwrap_or_else(|| "0.0.0.0:47391".into()),
                args.iter().any(|a| a == "--answer"),
                flag("--ledger"),
            )
            .map_err(|why| (1, why))?;
        }
        _ => {
            return Err((
                2,
                "usage: cmux-nat-probe stun | pair --role a|b --token HEX [--duration-ms N] \
                 [--pings N] [--rendezvous HOST:PORT] [--label L] | tailscale --rendezvous HOST:PORT [--peer IP] [--count N] [--tailscale-bin PATH] \
                 [--label L] | rendezvous [--listen ADDR] [--answer] [--ledger FILE]"
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

/// One side's run. The signalling reader lives in a thread scope: it ends at the input's `DONE`
/// or end, or when `closer` (the rendezvous stream) is shut down after the result is sent.
fn pair(
    role_a: bool,
    token: u64,
    duration: Duration,
    pings: u32,
    input: Box<dyn BufRead + Send>,
    closer: Option<TcpStream>,
) {
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::scope(|s| {
        s.spawn(move || {
            for line in input.lines().map_while(Result::ok) {
                let done = line == "DONE";
                if tx.send(line).is_err() || done {
                    break;
                }
            }
        });
        measure(role_a, token, duration, pings, &rx);
        if let Some(stream) = &closer {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    });
}

fn measure(role_a: bool, token: u64, duration: Duration, pings: u32, rx: &mpsc::Receiver<String>) {
    let start = Instant::now();
    let ms = |at: Instant| at.duration_since(start).as_secs_f64() * 1000.0;
    let mut sides = Sides::bind();
    let me = sides.gather();
    emit("CANDS", &me);

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

static OUT: std::sync::OnceLock<Mutex<Box<dyn Write + Send>>> = std::sync::OnceLock::new();

fn set_out(w: Box<dyn Write + Send>) {
    let _ = OUT.set(Mutex::new(w));
}

/// Writes each line to the rendezvous and to stdout, so the runner's log has the result too.
struct Tee(TcpStream);

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
///
/// With `ledger`, every RESULT is also appended to that file as one JSON line (`at` unix
/// seconds, `token`, the sender's `from` address and `label`, the peer's `peer_label`, and
/// the `result`): the NAT ledger's rows, which NOW's census reads.
fn rendezvous(listen: &str, answer: bool, ledger: Option<String>) -> Result<(), String> {
    let listener = std::net::TcpListener::bind(listen)
        .map_err(|err| format!("rendezvous: bind {listen}: {err}"))?;
    eprintln!("rendezvous: listening on {listen}");
    let ledger = match ledger {
        Some(path) => Some(Mutex::new(
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|err| format!("rendezvous: ledger {path}: {err}"))?,
        )),
        None => None,
    };
    let shared = Shared {
        listen: listen.to_string(),
        answer,
        waiting: Mutex::default(),
        labels: Mutex::default(),
        ledger,
    };
    // Every connection, relay and answered side b is a thread of this scope, joined by it.
    std::thread::scope(|s| {
        for conn in listener.incoming().map_while(Result::ok) {
            let shared = &shared;
            s.spawn(move || serve(s, conn, shared));
        }
    });
    Ok(())
}

/// The rendezvous's state, shared by its connections.
struct Shared {
    listen: String,
    answer: bool,
    /// The first side of each token, waiting for its peer.
    waiting: Mutex<HashMap<String, TcpStream>>,
    labels: Mutex<HashMap<String, String>>,
    ledger: Option<Mutex<std::fs::File>>,
}

fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// One connection: reads its HELLO, then records a note, waits for its peer, or pairs with the
/// peer that waits and relays both directions until either side ends.
fn serve<'scope>(
    s: &'scope std::thread::Scope<'scope, '_>,
    conn: TcpStream,
    shared: &'scope Shared,
) {
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
    let role = parts.next();
    let label = parts.next().unwrap_or("").to_string();
    if role == Some("n") {
        // A note (a Tailscale comparison row): recorded as sent, no pairing.
        let seen = Seen { token, from: peer_addr, label, peer_label: String::new() };
        relay(&mut reader, None, &seen, shared.ledger.as_ref());
        return;
    }
    let Some(other) = locked(&shared.waiting).remove(&token) else {
        locked(&shared.labels).insert(token.clone(), label);
        locked(&shared.waiting).insert(token.clone(), conn);
        if shared.answer && role == Some("a") {
            answer_side_b(s, &shared.listen, &token);
        }
        // The second side's connection relays for both.
        return;
    };
    let other_addr = other.peer_addr().map(|a| a.to_string()).unwrap_or_default();
    let (Ok(other_read), Ok(conn_write)) = (other.try_clone(), conn.try_clone()) else {
        return;
    };
    let other_label = locked(&shared.labels).remove(&token).unwrap_or_default();
    let back = Seen {
        token: token.clone(),
        from: other_addr,
        label: other_label.clone(),
        peer_label: label.clone(),
    };
    s.spawn(move || {
        let mut from = std::io::BufReader::new(other_read);
        relay(&mut from, Some(conn_write), &back, shared.ledger.as_ref());
    });
    // This side's reader already consumed its HELLO line; relay the rest from it.
    let forth = Seen { token, from: peer_addr, label, peer_label: other_label };
    relay(&mut reader, Some(other), &forth, shared.ledger.as_ref());
}

/// Starts this host's side b for `token` against the rendezvous at `listen` (0.0.0.0 dials
/// loopback), and waits for it in the rendezvous's scope. Its RESULT reaches the runner through
/// the rendezvous like any side's.
fn answer_side_b<'scope>(s: &'scope std::thread::Scope<'scope, '_>, listen: &str, token: &str) {
    let dial = listen.replace("0.0.0.0", "127.0.0.1");
    let spawned = std::env::current_exe().and_then(|exe| {
        cmux_process::Command::new(exe)
            .args(["pair", "--role", "b", "--token", token, "--rendezvous", &dial])
            .stdout(cmux_process::Stdio::null())
            .spawn()
    });
    match spawned {
        Ok(mut child) => {
            s.spawn(move || {
                let _ = child.wait();
            });
        }
        Err(err) => eprintln!("rendezvous: answer {token}: {err}"),
    }
}

/// Who sent the lines one relay carries.
struct Seen {
    token: String,
    from: String,
    label: String,
    peer_label: String,
}

/// Relays lines from one side to the other until either ends; prints each RESULT tagged with
/// the token and the sender's address, and appends it to the ledger when there is one.
fn relay(
    from: &mut dyn BufRead,
    mut to: Option<TcpStream>,
    seen: &Seen,
    ledger: Option<&Mutex<std::fs::File>>,
) {
    for line in from.lines().map_while(Result::ok) {
        if let Some(rest) = line.strip_prefix("RESULT ") {
            println!("{} {} {line}", seen.token, seen.from);
            if let Some(file) = ledger {
                let at = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |d| d.as_secs());
                let result = serde_json::from_str::<Value>(rest).unwrap_or(Value::Null);
                let row = json!({"at": at, "token": seen.token, "from": seen.from,
                    "label": seen.label, "peer_label": seen.peer_label, "result": result});
                let _ = writeln!(locked(file), "{row}");
            }
        }
        if let Some(to) = to.as_mut()
            && writeln!(to, "{line}").is_err()
        {
            break;
        }
    }
    if let Some(to) = to {
        let _ = to.shutdown(std::net::Shutdown::Write);
    }
}

/// The same pair over Tailscale: `tailscale ping` to the peer, every reply counted (not stopping once direct).
fn tailscale_compare(bin: &str, peer: &str, count: &str) -> Value {
    let started = Instant::now();
    let output = cmux_process::Command::new(bin)
        .args(["ping", "--until-direct=false", "-c", count, "--timeout", "3s", peer])
        .stdin(cmux_process::Stdio::null())
        .output();
    let text = match output {
        Ok(out) => String::from_utf8_lossy(&out.stdout).into_owned(),
        Err(err) => return json!({"tailscale": {"error": format!("{bin}: {err}")}}),
    };
    let got = cmux_nat_probe::parse_tailscale_ping(&text);
    let direct = got.direct.iter().filter(|d| **d).count();
    json!({"tailscale": {
        "peer": peer, "pings": count.parse::<u32>().ok(), "pongs": got.rtt_ms.len(),
        "direct": direct > 0 && direct * 2 >= got.direct.len(), "direct_pongs": direct,
        "via": got.last_via, "rtt_ms_p50": quantile(&got.rtt_ms, 0.5),
        "rtt_ms_p95": quantile(&got.rtt_ms, 0.95),
        "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0,
    }})
}

/// Sends one note row (role n) to the rendezvous, which records it in its ledger.
fn note(rv: &str, label: String, result: &Value) -> Result<(), String> {
    let mut stream = TcpStream::connect(rv).map_err(|err| format!("rendezvous {rv}: {err}"))?;
    let label: String = label.chars().map(|c| if c.is_whitespace() { '_' } else { c }).collect();
    let token: u64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64);
    writeln!(stream, "HELLO {token:x} n {label}\nRESULT {result}")
        .and_then(|()| stream.shutdown(std::net::Shutdown::Write))
        .map_err(|err| format!("rendezvous {rv}: {err}"))
}
