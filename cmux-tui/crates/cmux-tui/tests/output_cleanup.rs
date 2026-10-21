//! The one-time stored-output cleanup on the real owner binary. A registry
//! of an older build holds `terminal.output` rows, live and inside sealed
//! segments. An owner stages the sealed segments in the background
//! (Phase A); the next owner start builds a new registry without the
//! output, renames it into place and keeps the old file as
//! `.pre-output-cleanup`, which the start after that removes.
//!
//! Output rows are seeded with SQLite into a registry the daemon created
//! (this branch still journals output, but a seed gives fixed counts); the
//! segments that hold them are sealed by the daemon itself
//! (`session.journal.checkpoint.create` + `session.journal.segment.seal`).
//! Results are read through the socket and the CLI (workspace list, a
//! bounded `session.journal.subscribe` read from the beginning) and from the
//! files on disk.

#![cfg(all(unix, debug_assertions))]

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use sha2::{Digest, Sha256};

const REGISTRY: &str = "workspace-registry.sqlite3";
/// Owners that only prepare the registry never start the cleanup.
const NEVER: &str = "86400000";
const SEEDED_SEALED: usize = 2_600;
const SEEDED_LIVE: usize = 1_500;
const OUTPUT_BYTES: usize = 2_048;

struct StateDir(PathBuf);

impl Drop for StateDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn state_dir(label: &str) -> StateDir {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-oc-{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    StateDir(dir)
}

fn command(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"))
        .env_remove("CMUX_TUI_SOCKET");
    command
}

struct Owner {
    child: Child,
    dir: PathBuf,
    session: String,
    log: PathBuf,
}

impl Owner {
    /// Starts an owner whose stderr goes to `<label>.log`.
    fn start(dir: &Path, session: &str, label: &str, env: &[(&str, &str)]) -> Self {
        let socket = dir.join("mux.sock");
        let _ = fs::remove_file(&socket);
        let log = dir.join(format!("{label}.log"));
        let mut command = command(dir);
        command
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", NEVER)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(File::create(&log).unwrap());
        for (key, value) in env {
            command.env(key, value);
        }
        let child = command.spawn().unwrap();
        let mut owner = Self { child, dir: dir.to_path_buf(), session: session.into(), log };
        let deadline = Instant::now() + Duration::from_secs(60);
        while !owner.answers() {
            if let Some(status) = owner.child.try_wait().unwrap() {
                panic!("the owner exited with {status}: {}", owner.log_text());
            }
            assert!(Instant::now() < deadline, "the owner never answered: {}", owner.log_text());
            std::thread::sleep(Duration::from_millis(50));
        }
        owner
    }

    fn socket(&self) -> PathBuf {
        self.dir.join("mux.sock")
    }

    fn answers(&self) -> bool {
        command(&self.dir)
            .args(["--json", "server", "status", "--session", &self.session, "--socket"])
            .arg(self.socket())
            .output()
            .is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains("\"running\"")
            })
    }

    fn log_text(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    /// Waits for a stderr line that contains `needle`.
    fn wait_for_log(&self, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let text = self.log_text();
            if let Some(line) = text.lines().find(|line| line.contains(needle)) {
                return line.to_string();
            }
            assert!(Instant::now() < deadline, "no log line with {needle:?}: {text}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn cli(&self, args: &[&str]) -> serde_json::Value {
        let output = command(&self.dir)
            .arg("--json")
            .arg("--socket")
            .arg(self.socket())
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{args:?} failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn stop(mut self) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let _ = command(&self.dir)
                .args(["server", "stop", "--session", &self.session, "--end-terminals", "--socket"])
                .arg(self.socket())
                .output();
            let retry = Instant::now() + Duration::from_secs(1);
            while Instant::now() < retry {
                if self.child.try_wait().unwrap().is_some() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                panic!("the owner of {} did not stop", self.session);
            }
        }
    }

    fn kill(mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }
}

fn resource_request(
    socket: &Path,
    operation: &str,
    params: serde_json::Value,
    key: &str,
) -> serde_json::Value {
    let request = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":key,
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

fn decimal(value: &serde_json::Value) -> u64 {
    value.as_str().map(|text| text.parse().unwrap()).or_else(|| value.as_u64()).unwrap()
}

/// One journal record as a reader sees it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Seen {
    sequence: u64,
    event_id: String,
    kind: String,
}

/// Every journal record from the beginning to the head at open, and the
/// reason the bounded stream ended (`completed`, or `gap` on a read error).
fn read_journal(socket: &Path) -> (Vec<Seen>, String) {
    let stream = transport::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"output-cleanup-read",
            "operation":"session.journal.subscribe",
            "params":{
                "machine":"current",
                "session":"current",
                "stream_id":"stream_33333333333343338333333333333333",
                "start":"beginning",
                "follow":false,
                "filter":{"max_sensitivity":"sensitive"},
            },
        })
    )
    .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let opened: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(opened["ok"], true, "journal subscription failed: {opened}");
    let mut records = Vec::new();
    loop {
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert!(!line.is_empty(), "the journal stream closed without an end");
        let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
        if envelope["type"] == "stream_end" {
            return (records, envelope["reason"].as_str().unwrap_or_default().to_string());
        }
        let item = &envelope["item"];
        records.push(Seen {
            sequence: decimal(&item["sequence"]),
            event_id: item["event_id"].as_str().unwrap().to_string(),
            kind: item["kind"].as_str().unwrap().to_string(),
        });
    }
}

/// Workspace ids and names, sorted.
fn workspaces(owner: &Owner) -> BTreeSet<(String, String)> {
    let listed = owner.cli(&["workspace", "list"]);
    let items = listed["items"]
        .as_array()
        .or_else(|| listed["workspaces"].as_array())
        .or_else(|| listed.as_array())
        .unwrap_or_else(|| panic!("workspace list shape: {listed}"))
        .clone();
    items
        .iter()
        .map(|workspace| {
            (
                workspace["id"].as_str().unwrap_or_default().to_string(),
                workspace["name"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect()
}

fn registry_path(dir: &Path) -> PathBuf {
    fs::read_dir(dir.join("state").join("sessions"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.join(REGISTRY).is_file())
        .expect("a first start creates the registry")
        .join(REGISTRY)
}

fn sidecar(registry: &Path, suffix: &str) -> PathBuf {
    let mut name = registry.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn read_only(path: &Path) -> Connection {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap()
}

fn count(db: &Connection, sql: &str) -> i64 {
    db.query_row(sql, [], |row| row.get(0)).unwrap()
}

fn live_output_rows(registry: &Path) -> i64 {
    count(
        &read_only(registry),
        "SELECT COUNT(*) FROM session_journal WHERE kind = 'terminal.output'",
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Appends `rows` `terminal.output` rows the way an older build wrote them,
/// with their event and subject index rows. The owner is stopped.
fn seed_output(registry: &Path, rows: usize, salt: &str) {
    let mut db = Connection::open(registry).unwrap();
    let terminal = format!("terminal_{}", hex(&Sha256::digest(salt.as_bytes())[..16]));
    let tx = db.transaction().unwrap();
    let mut offset = 0_u64;
    for index in 0..rows {
        let mut bytes = format!("{salt} line {index} ").into_bytes();
        bytes.resize(OUTPUT_BYTES, b'x');
        let end = offset + bytes.len() as u64;
        let payload = serde_json::json!({
            "format":"cmux.terminal-output.v1",
            "encoding":"raw",
            "byte_count":bytes.len().to_string(),
            "sha256":hex(&Sha256::digest(&bytes)),
            "stream_offset_start":offset.to_string(),
            "stream_offset_end":end.to_string(),
        });
        offset = end;
        let event_id =
            format!("event_terminal_{}", hex(&Sha256::digest(format!("{salt}{index}"))[..16]));
        tx.execute(
            "INSERT INTO session_journal(
               event_id, schema_version, kind, class, replay_policy, occurred_at_ms,
               committed_at_ms, producer_json, authority_json, causation_depth, subjects_json,
               sensitivity, payload_json, content
             ) VALUES(?1, 1, 'terminal.output', 'observation', 'required', 1, 1, ?2, ?3, 0, ?4,
                      'sensitive', ?5, ?6)",
            params![
                event_id,
                serde_json::json!({"kind":"terminal_runtime","id":terminal}).to_string(),
                serde_json::json!({
                    "principal_id":"cmux.terminal-runtime",
                    "lease_id":format!("terminal:{terminal}"),
                    "generation":format!("{salt}-generation"),
                    "role":"terminal.runtime",
                })
                .to_string(),
                serde_json::json!([{"kind":"terminal","id":terminal}]).to_string(),
                payload.to_string(),
                bytes,
            ],
        )
        .unwrap();
        let sequence = tx.last_insert_rowid();
        tx.execute(
            "INSERT INTO journal_event_index(event_id, sequence, causation_depth) VALUES(?1, ?2, 0)",
            params![event_id, sequence],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO journal_subject_index(sequence, kind, id) VALUES(?1, 'terminal', ?2)",
            params![sequence, terminal],
        )
        .unwrap();
    }
    tx.commit().unwrap();
    db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
}

/// Seals the journal through a new checkpoint, one segment per request.
fn seal_through_checkpoint(owner: &Owner, label: &str) {
    let socket = owner.socket();
    let scope = serde_json::json!({"machine":"current","session":"current"});
    let checkpoint = resource_request(
        &socket,
        "session.journal.checkpoint.create",
        scope.clone(),
        &format!("{label}-checkpoint"),
    );
    let target = decimal(&checkpoint["value"]["source_sequence"]);
    for batch in 0..64 {
        let mut params = scope.clone();
        params["through_sequence"] = serde_json::json!(target.to_string());
        let sealed = resource_request(
            &socket,
            "session.journal.segment.seal",
            params,
            &format!("{label}-seal-{batch}"),
        );
        if decimal(&sealed["value"]["through_sequence"]) >= target {
            return;
        }
    }
    panic!("sealing never reached sequence {target}");
}

struct Prepared {
    registry: PathBuf,
    workspaces: BTreeSet<(String, String)>,
    journal: Vec<Seen>,
    bytes: u64,
}

/// A registry of an older build: workspaces, sealed segments that mix output
/// with other records, and live output rows after them.
fn prepare(dir: &Path, session: &str) -> Prepared {
    let owner = Owner::start(dir, session, "prepare-1", &[]);
    owner.cli(&["workspace", "create", "--empty", "--name", "before-output"]);
    owner.stop();
    let registry = registry_path(dir);
    seed_output(&registry, SEEDED_SEALED, "sealed");

    let owner = Owner::start(dir, session, "prepare-2", &[]);
    owner.cli(&["workspace", "create", "--empty", "--name", "between-output"]);
    seal_through_checkpoint(&owner, "prepare");
    owner.stop();
    seed_output(&registry, SEEDED_LIVE, "live");

    let owner = Owner::start(dir, session, "prepare-3", &[]);
    owner.cli(&["workspace", "create", "--empty", "--name", "after-output"]);
    let workspaces = workspaces(&owner);
    let (journal, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed", "the prepared journal reads to its head");
    owner.stop();

    let segments = read_only(&registry);
    assert!(
        count(&segments, "SELECT COUNT(*) FROM journal_segments") >= 3,
        "the fixture seals several segments"
    );
    assert!(
        count(
            &segments,
            "SELECT COUNT(*) FROM journal_segment_kinds WHERE kind = 'terminal.output'"
        ) >= 3,
        "sealed segments hold output"
    );
    assert_eq!(live_output_rows(&registry), SEEDED_LIVE as i64);
    let output = journal.iter().filter(|record| record.kind == "terminal.output").count();
    assert_eq!(output, SEEDED_SEALED + SEEDED_LIVE, "a reader sees every seeded output record");
    let bytes = fs::metadata(&registry).unwrap().len()
        + fs::metadata(sidecar(&registry, "-wal")).map(|metadata| metadata.len()).unwrap_or(0);
    Prepared { registry, workspaces, journal, bytes }
}

/// Phase A finished in the background and wrote its staging file.
fn stage(dir: &Path, session: &str, label: &str) -> Owner {
    let owner =
        Owner::start(dir, session, label, &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0")]);
    let line = owner.wait_for_log("output cleanup: phase A complete");
    assert!(line.contains("records kept"), "{line}");
    owner
}

/// The registry after the swap holds no output and reads the same records.
fn assert_cleaned(owner: &Owner, prepared: &Prepared) {
    let registry = &prepared.registry;
    assert!(sidecar(registry, ".pre-output-cleanup").is_file(), "the previous file is kept");
    assert!(!sidecar(registry, ".output-cleanup").exists(), "the staging file became the registry");
    let db = read_only(registry);
    assert_eq!(live_output_rows(registry), 0, "no live output row is left");
    assert_eq!(
        count(&db, "SELECT COUNT(*) FROM journal_segment_kinds WHERE kind = 'terminal.output'"),
        0,
        "no sealed segment holds output"
    );
    assert!(count(&db, "SELECT COUNT(*) FROM journal_pruned_ranges") > 0);
    let after_bytes = fs::metadata(registry).unwrap().len()
        + fs::metadata(sidecar(registry, "-wal")).map(|metadata| metadata.len()).unwrap_or(0);
    let output_bytes = ((SEEDED_SEALED + SEEDED_LIVE) * OUTPUT_BYTES) as u64;
    assert!(
        after_bytes + output_bytes / 2 < prepared.bytes,
        "the registry shrinks by about the output it held: {} -> {after_bytes} bytes",
        prepared.bytes
    );

    assert_eq!(workspaces(owner), prepared.workspaces, "the workspaces survive the swap");
    let (journal, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed", "the journal reads across the pruned ranges");
    assert!(journal.iter().all(|record| record.kind != "terminal.output"), "no output is read");
    let prepared_head = prepared.journal.last().unwrap().sequence;
    let kept = prepared
        .journal
        .iter()
        .filter(|record| record.kind != "terminal.output")
        .cloned()
        .collect::<Vec<_>>();
    let read_back = journal
        .iter()
        .filter(|record| record.sequence <= prepared_head)
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(read_back, kept, "every other record keeps its sequence and event id");
    // The registry takes new records after the swap and reads them back.
    owner.cli(&["workspace", "create", "--empty", "--name", "after-cleanup"]);
    let (journal, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed");
    assert!(journal.last().unwrap().sequence > prepared_head);
}

fn integrity(path: &Path) -> String {
    read_only(path).query_row("PRAGMA integrity_check", [], |row| row.get(0)).unwrap()
}

#[test]
fn stored_output_is_removed_and_the_registry_swapped_at_the_next_start() {
    let dir = state_dir("swap");
    let session = "oc-swap";
    let prepared = prepare(&dir.0, session);

    let owner = stage(&dir.0, session, "stage");
    owner.stop();
    assert!(sidecar(&prepared.registry, ".output-cleanup").is_file(), "phase A staged a file");
    assert_eq!(
        live_output_rows(&prepared.registry),
        SEEDED_LIVE as i64,
        "phase A leaves the registry as it was"
    );

    let owner =
        Owner::start(&dir.0, session, "swap", &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0")]);
    let line = owner.wait_for_log("output cleanup: swapped the registry");
    assert!(line.contains("pruned ranges"), "{line}");
    assert_eq!(integrity(&prepared.registry), "ok");
    assert_cleaned(&owner, &prepared);
    owner.stop();

    // The start after the swap opens the new registry and drops the old file.
    let owner = Owner::start(&dir.0, session, "after-swap", &[]);
    let previous = sidecar(&prepared.registry, ".pre-output-cleanup");
    let deadline = Instant::now() + Duration::from_secs(30);
    while previous.exists() {
        assert!(Instant::now() < deadline, "the previous registry was not removed");
        std::thread::sleep(Duration::from_millis(50));
    }
    let (_, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed");
    assert!(!owner.log_text().contains("output cleanup: staging"), "the cleanup runs once");
    owner.stop();
}

#[test]
fn a_killed_cleanup_leaves_the_registry_usable_and_resumes() {
    let dir = state_dir("kill");
    let session = "oc-kill";
    let prepared = prepare(&dir.0, session);
    let staging = sidecar(&prepared.registry, ".output-cleanup");

    // One staged segment per 500 ms, so the kill lands inside Phase A.
    let owner = Owner::start(
        &dir.0,
        session,
        "stage-killed",
        &[
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0"),
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_PAUSE_MS", "500"),
        ],
    );
    let deadline = Instant::now() + Duration::from_secs(60);
    let staged = loop {
        let staged = staging.is_file().then(|| {
            Connection::open_with_flags(&staging, OpenFlags::SQLITE_OPEN_READ_ONLY).ok().and_then(
                |db| {
                    db.query_row(
                        "SELECT CAST(value AS INTEGER) FROM output_cleanup_state
                         WHERE key = 'staged_segments'",
                        [],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()
                    .ok()
                    .flatten()
                },
            )
        });
        if let Some(Some(staged)) = staged
            && staged >= 1
        {
            break staged;
        }
        assert!(Instant::now() < deadline, "phase A staged nothing: {}", owner.log_text());
        std::thread::sleep(Duration::from_millis(20));
    };
    owner.kill();
    assert!(!owner_log_contains(&dir.0, "stage-killed", "phase A complete"), "killed mid-way");
    assert!(staged >= 1);

    // The original registry was never written by the cleanup.
    assert_eq!(integrity(&prepared.registry), "ok");
    assert_eq!(live_output_rows(&prepared.registry), SEEDED_LIVE as i64);
    let owner = Owner::start(&dir.0, session, "after-kill", &[]);
    assert_eq!(workspaces(&owner), prepared.workspaces, "the registry serves after the kill");
    owner.stop();

    // The next cleanup resumes from the staged segments.
    let owner = stage(&dir.0, session, "resume");
    owner.wait_for_log("output cleanup: resuming after sequence");
    owner.stop();
    let owner = Owner::start(
        &dir.0,
        session,
        "swap-after-resume",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0")],
    );
    owner.wait_for_log("output cleanup: swapped the registry");
    assert_cleaned(&owner, &prepared);
    owner.stop();
}

fn owner_log_contains(dir: &Path, label: &str, needle: &str) -> bool {
    fs::read_to_string(dir.join(format!("{label}.log"))).unwrap_or_default().contains(needle)
}
