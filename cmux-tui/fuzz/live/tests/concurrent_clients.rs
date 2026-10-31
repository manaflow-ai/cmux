#![cfg(unix)]
//! Live wire fuzz of the daemon's control socket (fuzz catalog row c).
//!
//! One real daemon (`server::serve`). A witness client connects first and
//! sends `identify` every 50 ms for the whole run, and `server-stats` every
//! tenth probe. Then:
//!
//! 1. The limit: the rest of the admission limit plus `EXTRA` more clients
//!    connect one by one and hold. Exactly the free slots are served; every
//!    other client reads the typed `server.busy` refusal, then end of stream.
//!    Eight served clients hang up; eight new clients are served at once
//!    (their slots come back).
//! 2. The storm, `CMUX_WIRE_FUZZ_ROUNDS` rounds (default 3): the limit plus
//!    `EXTRA` clients start at once behind a barrier, each with a behaviour
//!    picked by the seed: mutated request lines (byte changes, cuts, deep
//!    nesting, huge numbers, lone surrogates, trailing bytes, inserted
//!    garbage), invalid UTF-8, a partial line then a half close, a partial
//!    line held open, a line past the 16 MiB limit, 200 pipelined requests,
//!    and connect-and-close bursts.
//!
//! Oracle (every failure is listed in the result line, the test fails on any):
//! - no panic on any daemon thread;
//! - every UTF-8 request line under the limit gets one typed answer (a JSON
//!   object; `ok: false` names its error), or the typed busy refusal;
//! - invalid UTF-8 and over-limit lines end the connection, never a hang;
//! - `active` never passes the limit; `hung_up` never passes it either;
//! - the witness is never disturbed: every probe is answered, with its own
//!   id, within the app's 2 s request timeout;
//! - after each round every slot comes back (`active` is the witness alone).
//!
//! The result is one line, `WIRE-FUZZ-RESULT {json}`, with the seed. Repeat a
//! run with `CMUX_WIRE_FUZZ_SEED=<seed>`.

use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};

/// Clients past the admission limit.
const EXTRA: usize = 16;
/// The app's own request timeout: a witness answer later than this is a
/// disturbed client. `CMUX_WIRE_FUZZ_WITNESS_MS` raises it for a sanitizer
/// build, which runs every thread several times slower.
fn witness_budget() -> Duration {
    let ms = std::env::var("CMUX_WIRE_FUZZ_WITNESS_MS").ok().and_then(|v| v.parse().ok());
    Duration::from_millis(ms.unwrap_or(2_000))
}
const REPLY_TIMEOUT: Duration = Duration::from_secs(10);
/// cmux-tui-core `MAX_JSON_LINE_BYTES` (REMOTE_CLIENT_MESSAGE_MAX_BYTES).
const MAX_LINE: usize = cmux_tui_core::REMOTE_CLIENT_MESSAGE_MAX_BYTES;

static PANICS: Mutex<Vec<String>> = Mutex::new(Vec::new());

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

fn daemon() -> (Arc<Mux>, PathBuf) {
    let mux = Mux::new("wire-fuzz", SurfaceOptions::default());
    let dir = PathBuf::from(format!("/tmp/cwf-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve the daemon socket");
    (mux, socket)
}

fn connect(path: &Path) -> std::io::Result<BufReader<UnixStream>> {
    let stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(REPLY_TIMEOUT))?;
    stream.set_write_timeout(Some(REPLY_TIMEOUT))?;
    Ok(BufReader::new(stream))
}

/// One line, or `None` at end of stream; `Err` on a timeout or reset.
fn read_line(reader: &mut BufReader<UnixStream>) -> std::io::Result<Option<String>> {
    let mut line = String::new();
    match reader.read_line(&mut line)? {
        0 => Ok(None),
        _ => Ok(Some(line)),
    }
}

fn is_busy(line: &str) -> bool {
    serde_json::from_str::<Value>(line)
        .is_ok_and(|v| v["type"] == "refused" && v["code"] == "server.busy")
}

/// A typed answer: a JSON object that is a reply (`ok`) or a refusal
/// (`type`); a failed reply names its error.
fn typed_answer(line: &str) -> Result<(), String> {
    let value: Value =
        serde_json::from_str(line).map_err(|e| format!("answer is not JSON ({e}): {line:.200}"))?;
    let Some(object) = value.as_object() else {
        return Err(format!("answer is not an object: {line:.200}"));
    };
    if object.contains_key("type") {
        return Ok(());
    }
    match object.get("ok") {
        Some(Value::Bool(true)) => Ok(()),
        Some(Value::Bool(false)) => match object.get("error") {
            Some(Value::String(text)) if !text.is_empty() => Ok(()),
            _ => Err(format!("failed reply names no error: {line:.200}")),
        },
        _ => Err(format!("answer has no ok or type: {line:.200}")),
    }
}

/// Request lines with no side effect, the seeds of the mutations.
fn seed_line(rng: &mut Rng, id: u64) -> String {
    match rng.below(4) {
        0 => json!({"id": id, "cmd": "identify"}).to_string(),
        1 => json!({"id": id, "cmd": "server-stats"}).to_string(),
        2 => json!({"id": id, "cmd": "list-workspaces"}).to_string(),
        _ => json!({"protocol": "cmux.protocol/2", "type": "request", "id": format!("r{id}"),
            "operation": "workspace.list", "params": {}})
        .to_string(),
    }
}

/// A seed line changed one way; always valid UTF-8, one line, not blank.
fn mutated_line(rng: &mut Rng, id: u64) -> String {
    let seed = seed_line(rng, id);
    let mut line = match rng.below(9) {
        0 => {
            let mut bytes = seed.into_bytes();
            for _ in 0..=rng.below(4) {
                let at = rng.below(bytes.len());
                bytes[at] = b' ' + (rng.below(95) as u8);
            }
            String::from_utf8(bytes).unwrap_or_default()
        }
        1 => seed[..rng.below(seed.len())].to_string(),
        2 => format!("{}{}", "[".repeat(100 + rng.below(4000)), "]".repeat(rng.below(50))),
        3 => seed.replacen(&id.to_string(), "123456789012345678901234567890123456789e400", 1),
        4 => seed.replacen("\"cmd\"", "\"cmd\":\"\\ud800\",\"x\"", 1),
        5 => format!("{seed}{}", ["x", "}", ",", " {}", "\u{0}"][rng.below(5)]),
        6 => seed.replacen("\"id\"", "\"id\":1,\"id\"", 1),
        7 => {
            let at = rng.below(seed.len());
            let (head, tail) =
                seed.split_at(seed.char_indices().map(|(i, _)| i).find(|&i| i >= at).unwrap_or(0));
            format!("{head}\u{feff}\u{202e}\t{tail}")
        }
        _ => (0..1 + rng.below(512)).map(|_| char::from(b' ' + rng.below(95) as u8)).collect(),
    };
    line.retain(|c| c != '\n' && c != '\r');
    if line.trim().is_empty() {
        line = "x".into();
    }
    line
}

#[derive(Default)]
struct Tally {
    answered: usize,
    refused_busy: usize,
    reset: usize,
    closed: usize,
    failures: Vec<String>,
}

impl Tally {
    fn merge(&mut self, other: Tally) {
        self.answered += other.answered;
        self.refused_busy += other.refused_busy;
        self.reset += other.reset;
        self.closed += other.closed;
        self.failures.extend(other.failures);
    }
}

/// Write `bytes`, then read the first line: a typed answer, the busy
/// refusal, or (when `expect_close`) the end of the connection.
fn exchange(path: &Path, bytes: &[u8], expect_close: bool, label: &str) -> Tally {
    let mut tally = Tally::default();
    let mut conn = match connect(path) {
        Ok(conn) => conn,
        Err(error) => {
            tally.failures.push(format!("{label}: connect failed: {error}"));
            return tally;
        }
    };
    let wrote = conn.get_mut().write_all(bytes);
    match read_line(&mut conn) {
        Ok(Some(line)) if is_busy(&line) => tally.refused_busy += 1,
        Ok(Some(line)) if expect_close => {
            tally.failures.push(format!("{label}: answered a line that must close: {line:.200}"));
        }
        Ok(Some(line)) => match typed_answer(&line) {
            Ok(()) => tally.answered += 1,
            Err(why) => tally.failures.push(format!("{label}: {why}")),
        },
        Ok(None) if expect_close => tally.closed += 1,
        Ok(None) if wrote.is_err() => tally.reset += 1,
        Ok(None) => tally.failures.push(format!("{label}: closed with no answer")),
        Err(error)
            if error.kind() == ErrorKind::WouldBlock || error.kind() == ErrorKind::TimedOut =>
        {
            tally.failures.push(format!("{label}: no answer within {REPLY_TIMEOUT:?} (hang)"));
        }
        Err(_) => tally.reset += 1,
    }
    tally
}

fn storm_client(path: &Path, seed: u64, hold: &AtomicBool) -> Tally {
    let mut rng = Rng(seed | 1);
    let behaviour = rng.below(100);
    let label = format!("client seed {seed:#x} behaviour {behaviour}");
    match behaviour {
        // Mutated request lines, one per connection.
        0..=39 => {
            let line = mutated_line(&mut rng, seed % 1_000_000);
            exchange(
                path,
                format!("{line}\n").as_bytes(),
                false,
                &format!("{label} line {line:.120}"),
            )
        }
        // Invalid UTF-8 ends the connection.
        40..=47 => {
            let mut bytes = seed_line(&mut rng, 1).into_bytes();
            let at = rng.below(bytes.len());
            bytes.insert(at, [0xff, 0xc3, 0x80 | 0x40, 0xed][rng.below(4)]);
            bytes.push(b'\n');
            exchange(path, &bytes, true, &label)
        }
        // A partial line, then a half close: at most one answer, then the end.
        48..=59 => {
            let mut tally = Tally::default();
            let Ok(mut conn) = connect(path) else {
                tally.failures.push(format!("{label}: connect failed"));
                return tally;
            };
            let line = seed_line(&mut rng, 7);
            let cut = rng.below(line.len() + 1);
            let _ = conn.get_mut().write_all(&line.as_bytes()[..cut]);
            std::thread::sleep(Duration::from_millis(rng.below(300) as u64));
            let _ = conn.get_mut().shutdown(std::net::Shutdown::Write);
            for _ in 0..3 {
                match read_line(&mut conn) {
                    Ok(Some(answer)) if is_busy(&answer) => tally.refused_busy += 1,
                    Ok(Some(answer)) => {
                        if let Err(why) = typed_answer(&answer) {
                            tally.failures.push(format!("{label}: {why}"));
                        }
                        tally.answered += 1;
                    }
                    Ok(None) => {
                        tally.closed += 1;
                        return tally;
                    }
                    Err(error)
                        if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                    {
                        tally.failures.push(format!(
                            "{label}: half-closed connection not ended within {REPLY_TIMEOUT:?}"
                        ));
                        return tally;
                    }
                    Err(_) => {
                        tally.reset += 1;
                        return tally;
                    }
                }
            }
            tally.failures.push(format!("{label}: more than two lines after a half close"));
            tally
        }
        // A partial line held open while the storm runs (a slow client).
        60..=69 => {
            let mut tally = Tally::default();
            if let Ok(mut conn) = connect(path) {
                let line = seed_line(&mut rng, 9);
                let _ = conn.get_mut().write_all(&line.as_bytes()[..line.len() / 2]);
                let deadline = Instant::now() + Duration::from_secs(5);
                while hold.load(Ordering::Acquire) && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(20));
                }
                tally.closed += 1;
            }
            tally
        }
        // A line past the limit ends the connection (two such clients a round
        // at most, by the seed spacing: 16 MiB each).
        70..=71 => {
            let mut bytes = vec![b'a'; MAX_LINE + 1 + rng.below(64)];
            bytes.push(b'\n');
            exchange(path, &bytes, true, &label)
        }
        // 200 pipelined requests: one answer each, every id once.
        72..=84 => {
            let mut tally = Tally::default();
            let Ok(mut conn) = connect(path) else {
                tally.failures.push(format!("{label}: connect failed"));
                return tally;
            };
            let mut batch = String::new();
            for id in 0..200u64 {
                batch.push_str(&json!({"id": id, "cmd": "identify"}).to_string());
                batch.push('\n');
            }
            let wrote = conn.get_mut().write_all(batch.as_bytes());
            let mut seen = vec![false; 200];
            for _ in 0..200 {
                match read_line(&mut conn) {
                    Ok(Some(line)) if is_busy(&line) => {
                        tally.refused_busy += 1;
                        return tally;
                    }
                    Ok(Some(line)) => {
                        let value: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                        match value["id"].as_u64().filter(|&id| id < 200) {
                            Some(id) if !seen[id as usize] && value["ok"] == true => {
                                seen[id as usize] = true
                            }
                            _ => {
                                tally.failures.push(format!(
                                    "{label}: pipelined answer wrong or repeated: {line:.200}"
                                ));
                                return tally;
                            }
                        }
                    }
                    Ok(None) if wrote.is_err() => {
                        tally.reset += 1;
                        return tally;
                    }
                    Ok(None) => {
                        tally.failures.push(format!(
                            "{label}: closed after {} of 200 pipelined answers",
                            seen.iter().filter(|s| **s).count()
                        ));
                        return tally;
                    }
                    Err(error) => {
                        tally.failures.push(format!(
                            "{label}: pipelined read failed after {} answers: {error}",
                            seen.iter().filter(|s| **s).count()
                        ));
                        return tally;
                    }
                }
            }
            tally.answered += 200;
            tally
        }
        // Connect and close at once, 20 times.
        _ => {
            let mut tally = Tally::default();
            for _ in 0..20 {
                if UnixStream::connect(path).is_ok() {
                    tally.closed += 1;
                }
            }
            tally
        }
    }
}

#[derive(Default)]
struct WitnessLog {
    probes: usize,
    max_latency: Duration,
    failures: Vec<String>,
    /// The last `connections` section of `server-stats`.
    connections: Value,
    max_active: u64,
    max_hung_up: u64,
}

fn witness_loop(
    mut conn: BufReader<UnixStream>,
    stop: Arc<AtomicBool>,
    log: Arc<Mutex<WitnessLog>>,
    limit: u64,
) {
    let mut id = 1_000_000u64;
    while !stop.load(Ordering::Acquire) {
        id += 1;
        let stats = id % 10 == 0;
        let request = if stats {
            json!({"id": id, "cmd": "server-stats"})
        } else {
            json!({"id": id, "cmd": "identify"})
        };
        let started = Instant::now();
        let result =
            writeln!(conn.get_mut(), "{request}").map_err(|e| e.to_string()).and_then(|()| {
                read_line(&mut conn)
                    .map_err(|e| e.to_string())?
                    .ok_or_else(|| "witness connection closed".to_string())
            });
        let elapsed = started.elapsed();
        let mut log = log.lock().unwrap();
        log.probes += 1;
        log.max_latency = log.max_latency.max(elapsed);
        match result {
            Err(why) => {
                log.failures.push(format!("witness probe {id}: {why}"));
                return;
            }
            Ok(line) => {
                let value: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                if value["id"] != id || value["ok"] != true {
                    log.failures.push(format!("witness probe {id}: wrong answer {line:.200}"));
                }
                if elapsed > witness_budget() {
                    log.failures.push(format!(
                        "witness probe {id}: answered in {elapsed:?} (budget {:?})",
                        witness_budget()
                    ));
                }
                if stats {
                    let connections = value["data"]["connections"].clone();
                    let active = connections["active"].as_u64().unwrap_or(0);
                    let hung_up = connections["hung_up"].as_u64().unwrap_or(0);
                    log.max_active = log.max_active.max(active);
                    log.max_hung_up = log.max_hung_up.max(hung_up);
                    if active > limit || hung_up > limit {
                        log.failures.push(format!("limit broken: {connections}"));
                    }
                    log.connections = connections;
                }
            }
        }
        drop(log);
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Waits until the witness sees only itself connected.
fn wait_for_slots(log: &Mutex<WitnessLog>, what: &str, failures: &mut Vec<String>) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let connections = log.lock().unwrap().connections.clone();
        if connections["active"] == 1 && connections["hung_up"] == 0 {
            return;
        }
        if Instant::now() > deadline {
            failures.push(format!("{what}: slots did not come back within 20 s: {connections}"));
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn the_socket_survives_garbage_and_a_full_house() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current().name().unwrap_or("?").to_string();
        PANICS.lock().unwrap_or_else(|e| e.into_inner()).push(format!("{thread}: {info}"));
        default_hook(info);
    }));
    let seed = std::env::var("CMUX_WIRE_FUZZ_SEED")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| {
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
                as u64
        });
    let rounds: usize =
        std::env::var("CMUX_WIRE_FUZZ_ROUNDS").ok().and_then(|s| s.parse().ok()).unwrap_or(3);
    eprintln!("wire fuzz: seed {seed} rounds {rounds}");
    let (_mux, path) = daemon();
    let mut failures = Vec::new();

    let mut witness = connect(&path).expect("witness connects");
    writeln!(witness.get_mut(), "{}", json!({"id": 0, "cmd": "server-stats"})).unwrap();
    let first: Value = serde_json::from_str(&read_line(&mut witness).unwrap().unwrap()).unwrap();
    let limit =
        first["data"]["connections"]["limit"].as_u64().expect("server-stats names the limit");
    let log = Arc::new(Mutex::new(WitnessLog {
        connections: first["data"]["connections"].clone(),
        ..Default::default()
    }));
    let stop = Arc::new(AtomicBool::new(false));
    let witness_thread = {
        let (stop, log) = (stop.clone(), log.clone());
        std::thread::spawn(move || witness_loop(witness, stop, log, limit))
    };

    // 1. The limit, one client at a time.
    let mut held = Vec::new();
    let (mut served, mut refused) = (0, 0);
    for index in 0..(limit as usize - 1 + EXTRA) {
        let mut conn = connect(&path).expect("connect");
        let _ = writeln!(conn.get_mut(), "{}", json!({"id": index, "cmd": "identify"}));
        match read_line(&mut conn) {
            Ok(Some(line)) if is_busy(&line) => {
                refused += 1;
                if !matches!(read_line(&mut conn), Ok(None) | Err(_)) {
                    failures
                        .push(format!("limit: refused client {index} read more after the refusal"));
                }
            }
            Ok(Some(line)) if typed_answer(&line).is_ok() => {
                served += 1;
                held.push(conn);
            }
            other => failures.push(format!("limit: client {index}: {other:?}")),
        }
    }
    if served != limit as usize - 1 || refused != EXTRA {
        failures.push(format!(
            "limit: served {served} refused {refused}; expected {} and {EXTRA}",
            limit - 1
        ));
    }
    held.truncate(held.len().saturating_sub(8));
    let mut back = 0;
    for index in 0..8 {
        let mut conn = connect(&path).expect("connect");
        let _ = writeln!(conn.get_mut(), "{}", json!({"id": index, "cmd": "identify"}));
        if matches!(read_line(&mut conn), Ok(Some(line)) if !is_busy(&line)) {
            back += 1;
            held.push(conn);
        }
    }
    if back != 8 {
        failures.push(format!("limit: {back} of 8 clients served after 8 hang-ups"));
    }
    drop(held);
    wait_for_slots(&log, "after the limit phase", &mut failures);

    // 2. The storm.
    let mut tally = Tally::default();
    let mut rng = Rng(seed | 1);
    for round in 0..rounds {
        let clients = limit as usize + EXTRA;
        let barrier = Arc::new(Barrier::new(clients));
        let hold = Arc::new(AtomicBool::new(true));
        let mut huge = 0;
        let handles: Vec<_> = (0..clients)
            .map(|_| {
                let mut client_seed = rng.next();
                // At most two 16 MiB clients a round.
                if (70..=71).contains(&Rng(client_seed | 1).below(100)) {
                    huge += 1;
                    if huge > 2 {
                        client_seed = client_seed.wrapping_add(0x9e37_79b9);
                    }
                }
                let (barrier, hold, path) = (barrier.clone(), hold.clone(), path.clone());
                std::thread::spawn(move || {
                    barrier.wait();
                    storm_client(&path, client_seed, &hold)
                })
            })
            .collect();
        std::thread::sleep(Duration::from_secs(2));
        hold.store(false, Ordering::Release);
        for handle in handles {
            match handle.join() {
                Ok(result) => tally.merge(result),
                Err(_) => failures.push(format!("round {round}: a client thread panicked")),
            }
        }
        wait_for_slots(&log, &format!("after storm round {round}"), &mut failures);
    }

    stop.store(true, Ordering::Release);
    let _ = witness_thread.join();
    let log = log.lock().unwrap();
    failures.extend(log.failures.iter().cloned());
    failures.extend(tally.failures.iter().cloned());
    let panics = PANICS.lock().unwrap_or_else(|e| e.into_inner()).clone();
    failures.extend(panics.iter().map(|p| format!("daemon panic: {p}")));
    let result = json!({
        "seed": seed, "rounds": rounds, "limit": limit,
        "limit_phase": {"served": served, "refused": refused, "back_after_hangup": back},
        "storm": {"answered": tally.answered, "refused_busy": tally.refused_busy,
                  "reset": tally.reset, "closed": tally.closed},
        "witness": {"probes": log.probes, "max_latency_ms": log.max_latency.as_millis() as u64,
                    "max_active": log.max_active, "max_hung_up": log.max_hung_up},
        "failures": failures,
    });
    println!("WIRE-FUZZ-RESULT {result}");
    server::cleanup(&path);
    assert!(failures.is_empty(), "wire fuzz failures (seed {seed}): {failures:#?}");
}
