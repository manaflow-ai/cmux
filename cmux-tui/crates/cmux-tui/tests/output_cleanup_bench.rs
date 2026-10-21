//! Measures the stored-output cleanup on a synthetic registry of the shape a
//! long-running owner of an older build left (about 15M live rows, nearly all
//! `terminal.output`, six subject index rows each, and thousands of sealed
//! segments that mix output with other records). Not a test: run it by hand.
//!
//! ```sh
//! CMUX_OUTPUT_CLEANUP_BENCH_DIR=/w/bench CMUX_OUTPUT_CLEANUP_BENCH_SCALE=0.25 \
//!   cargo test --locked -p cmux-tui --test output_cleanup_bench -- --ignored --nocapture
//! ```
//!
//! Scale 1.0 is the real shape: 6.08M sealed and 14.93M live rows.

#![cfg(all(target_os = "linux", debug_assertions))]

use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};

const REGISTRY: &str = "workspace-registry.sqlite3";
const NEVER: &str = "86400000";
const SEALED_ROWS: f64 = 6_022_532.0;
const LIVE_ROWS: f64 = 14_934_714.0;
/// One structural record per this many rows (57k of 15M).
const STRUCTURAL_EVERY: u64 = 262;
const TERMINALS: u64 = 600;

fn command(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"))
        .env("CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS", NEVER)
        .env_remove("CMUX_TUI_SOCKET");
    command
}

struct Owner {
    child: Child,
    dir: PathBuf,
    log: PathBuf,
    started: Instant,
    answered: Duration,
}

impl Owner {
    fn start(dir: &Path, label: &str, cleanup_delay: &str) -> Self {
        let socket = dir.join("mux.sock");
        let _ = fs::remove_file(&socket);
        let log = dir.join(format!("{label}.log"));
        let started = Instant::now();
        let child = command(dir)
            .args(["--headless", "--session", "bench", "--socket"])
            .arg(&socket)
            .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", cleanup_delay)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(File::create(&log).unwrap())
            .spawn()
            .unwrap();
        // Samples the start of this owner (CMUX_OUTPUT_CLEANUP_BENCH_PROFILE=<label>):
        // per-thread CPU and the bytes the process read, every 10 s.
        let profile =
            std::env::var("CMUX_OUTPUT_CLEANUP_BENCH_PROFILE").ok().as_deref() == Some(label);
        let mut next_sample = Instant::now();
        let mut owner =
            Self { child, dir: dir.to_path_buf(), log, started, answered: Duration::ZERO };
        let deadline = Instant::now() + Duration::from_secs(1800);
        while !owner.answers() {
            if profile && Instant::now() >= next_sample {
                next_sample = Instant::now() + Duration::from_secs(10);
                eprintln!(
                    "bench: PROFILE {:.0} s {}",
                    owner.started.elapsed().as_secs_f64(),
                    sample(owner.child.id())
                );
            }
            assert!(
                owner.child.try_wait().unwrap().is_none(),
                "owner exited: {}",
                owner.log_text()
            );
            assert!(Instant::now() < deadline, "owner never answered");
            std::thread::sleep(Duration::from_millis(100));
        }
        owner.answered = owner.started.elapsed();
        eprintln!("bench: owner {label} answered in {:.2} s", owner.answered.as_secs_f64());
        owner
    }

    fn answers(&self) -> bool {
        command(&self.dir)
            .args(["--json", "server", "status", "--session", "bench", "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output()
            .is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains("\"running\"")
            })
    }

    fn log_text(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    fn wait_for_log(&self, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(7200);
        loop {
            if let Some(line) = self.log_text().lines().find(|line| line.contains(needle)) {
                return line.to_string();
            }
            assert!(Instant::now() < deadline, "no {needle:?}: {}", self.log_text());
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// Peak resident set of the owner so far.
    fn peak_rss_kib(&self) -> u64 {
        let status = fs::read_to_string(format!("/proc/{}/status", self.child.id())).unwrap();
        status
            .lines()
            .find_map(|line| line.strip_prefix("VmHWM:"))
            .and_then(|value| value.trim().trim_end_matches("kB").trim().parse().ok())
            .unwrap()
    }

    fn stop(mut self) {
        let _ = command(&self.dir)
            .args(["server", "stop", "--session", "bench", "--end-terminals", "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output();
        let deadline = Instant::now() + Duration::from_secs(600);
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "owner did not stop");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

/// Read bytes and the busiest threads (name, CPU ticks) of a process.
fn sample(pid: u32) -> String {
    let io = fs::read_to_string(format!("/proc/{pid}/io")).unwrap_or_default();
    let read =
        io.lines().find_map(|line| line.strip_prefix("read_bytes: ")).unwrap_or("?").to_string();
    let rchar = io.lines().find_map(|line| line.strip_prefix("rchar: ")).unwrap_or("?").to_string();
    let mut threads = Vec::new();
    for task in fs::read_dir(format!("/proc/{pid}/task")).into_iter().flatten().flatten() {
        let stat = fs::read_to_string(task.path().join("stat")).unwrap_or_default();
        let Some(close) = stat.rfind(')') else { continue };
        let name = stat[stat.find('(').unwrap_or(0) + 1..close].to_string();
        let fields: Vec<&str> = stat[close + 2..].split(' ').collect();
        let ticks: u64 = fields.get(11).and_then(|v| v.parse().ok()).unwrap_or(0)
            + fields.get(12).and_then(|v| v.parse().ok()).unwrap_or(0);
        let wchan = fs::read_to_string(task.path().join("wchan")).unwrap_or_default();
        threads.push((ticks, name, wchan));
    }
    threads.sort_by_key(|thread| std::cmp::Reverse(thread.0));
    threads.truncate(4);
    format!("read_bytes {read} rchar {rchar} threads {threads:?}")
}

fn resource_request(
    socket: &Path,
    operation: &str,
    params: serde_json::Value,
    key: &str,
) -> serde_json::Value {
    let request = serde_json::json!({
        "protocol":"cmux.protocol/2", "type":"request", "id":key,
        "operation":operation, "params":params, "idempotency_key":key,
    });
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response["result"].clone()
}

fn decimal(value: &serde_json::Value) -> u64 {
    value.as_str().map(|text| text.parse().unwrap()).or_else(|| value.as_u64()).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

/// Appends `rows` journal rows: output for one of `TERMINALS` terminals, and
/// one structural record per `STRUCTURAL_EVERY` rows.
fn append_rows(db: &mut Connection, rows: u64, rng: &mut Rng, offsets: &mut [u64]) -> u64 {
    let mut structural = 0;
    let words: Vec<&str> =
        "the quick brown fox jumps over a lazy dog cargo build test ok running warning error"
            .split(' ')
            .collect();
    let tx = db.transaction().unwrap();
    {
        let mut insert = tx
            .prepare(
                "INSERT INTO session_journal(
                   event_id, schema_version, kind, class, replay_policy, occurred_at_ms,
                   committed_at_ms, producer_json, authority_json, causation_depth, subjects_json,
                   sensitivity, payload_json, content
                 ) VALUES(?1, 1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, 0, ?8, ?9, ?10, ?11)",
            )
            .unwrap();
        let mut event = tx
            .prepare(
                "INSERT INTO journal_event_index(event_id, sequence, causation_depth)
                 VALUES(?1, ?2, 0)",
            )
            .unwrap();
        let mut subject = tx
            .prepare("INSERT INTO journal_subject_index(sequence, kind, id) VALUES(?1, ?2, ?3)")
            .unwrap();
        for index in 0..rows {
            let terminal_index = (rng.next() % TERMINALS) as usize;
            let terminal = format!("terminal_{:032x}", terminal_index as u128 * 7919 + 1);
            let workspace = format!("workspace_{:032x}", (terminal_index / 6) as u128 + 1);
            let subjects = serde_json::json!([
                {"kind":"pane","id":format!("pane_{:032x}", terminal_index as u128 + 3)},
                {"kind":"session","id":"session_00000000000000000000000000000001"},
                {"kind":"surface","id":format!("surface_{:032x}", terminal_index as u128 + 5)},
                {"kind":"tab","id":format!("tab_{:032x}", terminal_index as u128 + 9)},
                {"kind":"terminal","id":terminal},
                {"kind":"workspace","id":workspace},
            ]);
            let event_id = format!("event_terminal_{:016x}{:016x}", rng.next(), rng.next());
            let now = 1_790_000_000_000_i64 + index as i64;
            let is_structural = rng.next().is_multiple_of(STRUCTURAL_EVERY);
            let (kind, class, replay, sensitivity, payload, content): (
                _,
                _,
                _,
                _,
                String,
                Option<Vec<u8>>,
            ) = if is_structural {
                structural += 1;
                let mut text = String::new();
                while text.len() < 900 {
                    text.push_str(words[(rng.next() % words.len() as u64) as usize]);
                    text.push(' ');
                }
                (
                    "bench.structural",
                    "state",
                    "advisory",
                    "metadata",
                    serde_json::json!({"format":"bench.v1","text":text}).to_string(),
                    None,
                )
            } else {
                let length = 40 + (rng.next() % 80) as usize;
                let mut bytes = Vec::with_capacity(length);
                while bytes.len() < length {
                    bytes.extend_from_slice(
                        words[(rng.next() % words.len() as u64) as usize].as_bytes(),
                    );
                    bytes.push(b' ');
                }
                bytes.truncate(length);
                let start = offsets[terminal_index];
                let end = start + bytes.len() as u64;
                offsets[terminal_index] = end;
                (
                    "terminal.output",
                    "observation",
                    "required",
                    "sensitive",
                    serde_json::json!({
                        "format":"cmux.terminal-output.v1",
                        "encoding":"raw",
                        "byte_count":bytes.len().to_string(),
                        "sha256":hex(&Sha256::digest(&bytes)),
                        "stream_offset_start":start.to_string(),
                        "stream_offset_end":end.to_string(),
                    })
                    .to_string(),
                    Some(bytes),
                )
            };
            insert
                .execute(params![
                    event_id,
                    kind,
                    class,
                    replay,
                    now,
                    serde_json::json!({"kind":"terminal_runtime","id":terminal}).to_string(),
                    serde_json::json!({
                        "principal_id":"cmux.terminal-runtime",
                        "lease_id":format!("terminal:{terminal}"),
                        "generation":format!("generation_{terminal_index:024}"),
                        "role":"terminal.runtime",
                    })
                    .to_string(),
                    subjects.to_string(),
                    sensitivity,
                    payload,
                    content,
                ])
                .unwrap();
            let sequence = tx.last_insert_rowid();
            event.execute(params![event_id, sequence]).unwrap();
            for item in subjects.as_array().unwrap() {
                subject
                    .execute(params![sequence, item["kind"].as_str(), item["id"].as_str()])
                    .unwrap();
            }
        }
    }
    tx.commit().unwrap();
    structural
}

fn bulk_append(registry: &Path, rows: u64, rng: &mut Rng, offsets: &mut [u64]) -> u64 {
    let mut db = Connection::open(registry).unwrap();
    db.execute_batch(
        "PRAGMA journal_mode=DELETE; PRAGMA synchronous=OFF; PRAGMA cache_size=-8000000;",
    )
    .unwrap();
    let mut structural = 0;
    let mut done = 0;
    let started = Instant::now();
    while done < rows {
        let batch = (rows - done).min(1_000_000);
        structural += append_rows(&mut db, batch, rng, offsets);
        done += batch;
        eprintln!("bench: appended {done}/{rows} rows in {:.0} s", started.elapsed().as_secs_f64());
    }
    db.execute_batch("PRAGMA journal_mode=WAL;").unwrap();
    structural
}

fn registry_path(dir: &Path) -> PathBuf {
    fs::read_dir(dir.join("state").join("sessions"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.join(REGISTRY).is_file())
        .unwrap()
        .join(REGISTRY)
}

fn file_bytes(path: &Path) -> u64 {
    fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0)
}

fn gib(bytes: u64) -> String {
    format!("{:.2} GiB", bytes as f64 / f64::from(1 << 30))
}

#[test]
#[ignore = "benchmark: builds a registry of many GB"]
fn measure_output_cleanup_on_a_synthetic_registry() {
    let root = PathBuf::from(std::env::var("CMUX_OUTPUT_CLEANUP_BENCH_DIR").unwrap());
    let scale: f64 = std::env::var("CMUX_OUTPUT_CLEANUP_BENCH_SCALE")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0.1);
    let dir = root.join(format!("bench-{}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    let sealed_rows = (SEALED_ROWS * scale) as u64;
    let live_rows = (LIVE_ROWS * scale) as u64;
    let cache = std::env::var("CMUX_OUTPUT_CLEANUP_BENCH_CACHE").ok().map(PathBuf::from);
    let cached = cache.as_ref().filter(|cache| cache.join("done").is_file());
    let registry = if let Some(cache) = cached {
        let copied = Instant::now();
        let status =
            Command::new("cp").arg("-a").arg(cache.join("state")).arg(&dir).status().unwrap();
        assert!(status.success());
        eprintln!("bench: copied the cached registry in {:.0} s", copied.elapsed().as_secs_f64());
        registry_path(&dir)
    } else {
        generate(&dir, sealed_rows, live_rows)
    };
    if let Some(cache) = cache.as_ref().filter(|_| cached.is_none()) {
        fs::create_dir_all(cache).unwrap();
        let status =
            Command::new("cp").arg("-a").arg(dir.join("state")).arg(cache).status().unwrap();
        assert!(status.success());
        fs::write(cache.join("done"), b"").unwrap();
    }
    let before = file_bytes(&registry);

    // A start with the old file present, before any cleanup.
    let owner = Owner::start(&dir, "plain-start", NEVER);
    let plain_start = owner.answered;
    owner.stop();
    finish(&dir, &registry, scale, before, plain_start);
}

fn generate(dir: &Path, sealed_rows: u64, live_rows: u64) -> PathBuf {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let mut offsets = vec![0_u64; TERMINALS as usize];
    let owner = Owner::start(dir, "create", NEVER);
    owner.stop();
    let registry = registry_path(dir);
    let generated = Instant::now();
    let mut structural = bulk_append(&registry, sealed_rows, &mut rng, &mut offsets);

    // The owner seals the first part into segments, as maintenance did.
    let owner = Owner::start(dir, "seal", NEVER);
    let socket = dir.join("mux.sock");
    let scope = serde_json::json!({"machine":"current","session":"current"});
    let checkpoint = resource_request(
        &socket,
        "session.journal.checkpoint.create",
        scope.clone(),
        "bench-checkpoint",
    );
    let target = decimal(&checkpoint["value"]["source_sequence"]);
    let sealing = Instant::now();
    let mut batch = 0;
    loop {
        let mut params = scope.clone();
        params["through_sequence"] = serde_json::json!(target.to_string());
        let sealed = resource_request(
            &socket,
            "session.journal.segment.seal",
            params,
            &format!("bench-seal-{batch}"),
        );
        batch += 1;
        if batch % 500 == 0 {
            eprintln!("bench: sealed {batch} segments in {:.0} s", sealing.elapsed().as_secs_f64());
        }
        if decimal(&sealed["value"]["through_sequence"]) >= target {
            break;
        }
    }
    owner.stop();
    structural += bulk_append(&registry, live_rows, &mut rng, &mut offsets);
    eprintln!(
        "bench: generated {sealed_rows} sealed + {live_rows} live rows ({structural} structural), \
         {batch} segments, in {:.0} s",
        generated.elapsed().as_secs_f64()
    );
    {
        let db = Connection::open(&registry).unwrap();
        db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    }
    registry
}

fn finish(dir: &Path, registry: &Path, scale: f64, before: u64, plain_start: Duration) {
    let owner = Owner::start(dir, "phase-a", "0");
    let phase_a = owner.wait_for_log("output cleanup: phase A complete");
    let phase_a_rss = owner.peak_rss_kib();
    owner.stop();
    let staged = file_bytes(&registry.with_file_name(format!("{REGISTRY}.output-cleanup")));

    let owner = Owner::start(dir, "phase-b", NEVER);
    let swap = owner.wait_for_log("output cleanup: swapped the registry");
    let swap_start = owner.answered;
    let phase_b_rss = owner.peak_rss_kib();
    owner.stop();
    let after = file_bytes(registry);

    let owner = Owner::start(dir, "after", NEVER);
    let after_start = owner.answered;
    owner.stop();

    eprintln!("bench: RESULT scale {scale}");
    eprintln!(
        "bench: RESULT registry before {} ({before} bytes), after {} ({after} bytes)",
        gib(before),
        gib(after)
    );
    eprintln!("bench: RESULT staged file at the end of phase A {}", gib(staged));
    eprintln!(
        "bench: RESULT start with the old file (no cleanup) {:.2} s",
        plain_start.as_secs_f64()
    );
    eprintln!("bench: RESULT {phase_a}");
    eprintln!("bench: RESULT phase A owner peak RSS {} MiB", phase_a_rss / 1024);
    eprintln!("bench: RESULT {swap}");
    eprintln!(
        "bench: RESULT start that swapped, until it answered {:.2} s",
        swap_start.as_secs_f64()
    );
    eprintln!("bench: RESULT phase B owner peak RSS {} MiB", phase_b_rss / 1024);
    eprintln!("bench: RESULT start after the swap {:.2} s", after_start.as_secs_f64());
    fs::remove_dir_all(dir).unwrap();
}
