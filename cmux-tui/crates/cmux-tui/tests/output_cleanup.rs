//! The one-time stored-output cleanup on the real owner binary. A registry
//! of an older build holds `terminal.output` rows, live and inside sealed
//! segments. An owner stages the sealed segments and builds a new registry
//! without the output in the background (Phase A); the next owner start
//! finishes it with the journal tail, renames it into place and keeps the
//! old file as `.pre-output-cleanup`, which the start after that removes.
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
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use rusqlite::{Connection, OpenFlags, params};
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;

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

/// The owner's stderr lines, kept in order; a waiter is woken on each line
/// and when the stream ends.
#[derive(Default)]
struct LogLines {
    lines: Mutex<(Vec<String>, bool)>,
    changed: Condvar,
}

impl LogLines {
    fn text(&self) -> String {
        self.lines.lock().unwrap().0.join("\n")
    }

    /// The first line that contains `needle`, waiting for it up to `timeout`.
    fn wait_for(&self, needle: &str, timeout: Duration) -> Option<String> {
        let deadline = Instant::now() + timeout;
        let mut guard = self.lines.lock().unwrap();
        loop {
            if let Some(line) = guard.0.iter().find(|line| line.contains(needle)) {
                return Some(line.clone());
            }
            let now = Instant::now();
            if guard.1 || now >= deadline {
                return None;
            }
            guard = self.changed.wait_timeout(guard, deadline - now).unwrap().0;
        }
    }
}

struct Owner {
    child: Child,
    dir: PathBuf,
    session: String,
    log: Arc<LogLines>,
}

impl Owner {
    /// Starts an owner and waits for the line it prints once its control
    /// socket serves.
    fn start(dir: &Path, session: &str, label: &str, env: &[(&str, &str)]) -> Self {
        let socket = dir.join("mux.sock");
        let _ = fs::remove_file(&socket);
        let mut command = command(dir);
        command
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", NEVER)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        for (key, value) in env {
            command.env(key, value);
        }
        let mut child = command.spawn().unwrap();
        let log = Arc::new(LogLines::default());
        let stderr = child.stderr.take().unwrap();
        let reader_log = log.clone();
        let mut file = File::create(dir.join(format!("{label}.log"))).unwrap();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                let _ = writeln!(file, "{line}");
                reader_log.lines.lock().unwrap().0.push(line);
                reader_log.changed.notify_all();
            }
            reader_log.lines.lock().unwrap().1 = true;
            reader_log.changed.notify_all();
        });
        let owner = Self { child, dir: dir.to_path_buf(), session: session.into(), log };
        assert!(
            owner.log.wait_for("control socket at", Duration::from_secs(120)).is_some(),
            "the owner never served: {}",
            owner.log.text()
        );
        owner
    }

    fn socket(&self) -> PathBuf {
        self.dir.join("mux.sock")
    }

    fn log_text(&self) -> String {
        self.log.text()
    }

    /// Waits for a stderr line that contains `needle`.
    fn wait_for_log(&self, needle: &str) -> String {
        self.log
            .wait_for(needle, Duration::from_secs(120))
            .unwrap_or_else(|| panic!("no log line with {needle:?}: {}", self.log_text()))
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

    /// `server stop`, then waits for the process to exit (blocking, bounded).
    /// A plain stop: the tests read and reopen the saved state after it (a
    /// stop with `--end-terminals` removes it). These owners run no terminal.
    fn stop(mut self) {
        for _ in 0..3 {
            let _ = command(&self.dir)
                .args(["server", "stop", "--session", &self.session, "--socket"])
                .arg(self.socket())
                .output();
            if self.child.wait_timeout(Duration::from_secs(20)).unwrap().is_some() {
                return;
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        panic!("the owner of {} did not stop: {}", self.session, self.log_text());
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
    let mut request = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":key,
        "operation":operation,
        "params":params,
    });
    // Only mutations take an idempotency key.
    if !operation.ends_with(".preview") {
        request["idempotency_key"] = serde_json::json!(key);
    }
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
/// Seals the journal through a new checkpoint; returns the checkpoint id.
fn seal_through_checkpoint(owner: &Owner, label: &str) -> String {
    let socket = owner.socket();
    let scope = serde_json::json!({"machine":"current","session":"current"});
    let checkpoint = resource_request(
        &socket,
        "session.journal.checkpoint.create",
        scope.clone(),
        &format!("{label}-checkpoint"),
    );
    let target = decimal(&checkpoint["value"]["source_sequence"]);
    let checkpoint_id = checkpoint["value"]["checkpoint_id"].as_str().unwrap().to_string();
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
            return checkpoint_id;
        }
    }
    panic!("sealing never reached sequence {target}");
}

struct Prepared {
    registry: PathBuf,
    workspaces: BTreeSet<(String, String)>,
    journal: Vec<Seen>,
    bytes: u64,
    checkpoint: String,
}

/// A registry of an older build: workspaces, sealed segments that mix output
/// with other records, and live output rows after them.
fn prepare(dir: &Path, session: &str) -> Prepared {
    prepare_with_tail(dir, session, 0)
}

/// `tail_output` output rows are seeded last, so the journal ends in output.
fn prepare_with_tail(dir: &Path, session: &str, tail_output: usize) -> Prepared {
    let owner = Owner::start(dir, session, "prepare-1", &[]);
    owner.cli(&["workspace", "create", "--empty", "--name", "before-output"]);
    owner.stop();
    let registry = registry_path(dir);
    seed_output(&registry, SEEDED_SEALED, "sealed");

    let owner = Owner::start(dir, session, "prepare-2", &[]);
    owner.cli(&["workspace", "create", "--empty", "--name", "between-output"]);
    let checkpoint = seal_through_checkpoint(&owner, "prepare");
    owner.stop();
    seed_output(&registry, SEEDED_LIVE, "live");

    let owner = Owner::start(dir, session, "prepare-3", &[]);
    owner.cli(&["workspace", "create", "--empty", "--name", "after-output"]);
    // A closed workspace leaves a rowid gap that a copy must keep.
    owner.cli(&["workspace", "create", "--empty", "--name", "closed-later"]);
    owner.cli(&["workspace", "create", "--empty", "--name", "last"]);
    let closed = workspaces(&owner)
        .into_iter()
        .find(|(_, name)| name == "closed-later")
        .map(|(id, _)| id)
        .unwrap();
    owner.cli(&["workspace", &closed, "close"]);
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
    if tail_output > 0 {
        seed_output(&registry, tail_output, "tail");
    }
    let bytes = fs::metadata(&registry).unwrap().len()
        + fs::metadata(sidecar(&registry, "-wal")).map(|metadata| metadata.len()).unwrap_or(0);
    Prepared { registry, workspaces, journal, bytes, checkpoint }
}

/// Phase A and the background build finished and wrote the staging file.
fn stage(dir: &Path, session: &str, label: &str) -> Owner {
    stage_with(dir, session, label, &[])
}

fn stage_with(dir: &Path, session: &str, label: &str, env: &[(&str, &str)]) -> Owner {
    let mut env = env.to_vec();
    env.push(("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0"));
    let owner = Owner::start(dir, session, label, &env);
    let line = owner.wait_for_log("output cleanup: built the new registry in the background");
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
    // The index rows of every kept record equal the old registry's.
    let previous = sidecar(registry, ".pre-output-cleanup");
    db.execute("ATTACH DATABASE ?1 AS old", [previous.to_str().unwrap()]).unwrap();
    for (table, columns) in [
        ("journal_subject_index", "sequence, kind, id"),
        (
            "journal_event_index",
            "event_id, sequence, causation_depth, causation_id, causal_hook_id, \
             resource_revision, previous_resource_revision",
        ),
    ] {
        let differing = count(
            &db,
            &format!(
                "SELECT COUNT(*) FROM (
                   SELECT {columns} FROM main.{table}
                   EXCEPT SELECT {columns} FROM old.{table}
                   UNION ALL
                   SELECT {columns} FROM old.{table}
                   WHERE sequence IN (SELECT sequence FROM main.journal_event_index)
                   EXCEPT SELECT {columns} FROM main.{table})"
            ),
        );
        assert_eq!(differing, 0, "{table} rows of the kept records changed");
    }
    assert!(
        count(
            &db,
            "SELECT COUNT(*) FROM main.journal_event_index WHERE causation_id IS NOT NULL OR resource_revision IS NOT NULL"
        ) > 0,
        "the fixture has caused or resource records"
    );
    db.execute_batch("DETACH DATABASE old").unwrap();
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

/// Every table outside the rebuilt journal tables has the same rows, rowids
/// included, in the new registry (`new`, a copy taken right after the swap)
/// as in the registry it replaced (`old`). Meta differs only in the keys the
/// cleanup writes.
fn assert_structural_tables_equal(new: &Path, old: &Path) {
    const REBUILT: [&str; 6] = [
        "session_journal",
        "journal_segments",
        "journal_segment_kinds",
        "journal_subject_index",
        "journal_event_index",
        "journal_pruned_ranges",
    ];
    const CLEANUP_META: &str = "'output_cleanup_v1', 'output_cleanup_v2', \
         'journal_segment_kinds_backfill', 'output_cleanup_full_starts', 'output_cleanup_swap'";
    let db = read_only(new);
    db.execute("ATTACH DATABASE ?1 AS old", [old.to_str().unwrap()]).unwrap();
    let tables: Vec<(String, String)> = db
        .prepare(
            "SELECT name, sql FROM old.sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'",
        )
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut compared = 0;
    let mut differing = Vec::new();
    for (table, sql) in &tables {
        if REBUILT.contains(&table.as_str()) {
            continue;
        }
        let columns = if sql.to_ascii_uppercase().contains("WITHOUT ROWID") {
            "*"
        } else {
            "rowid AS row_id, *"
        };
        let filter = if table == "meta" {
            format!("WHERE key NOT IN ({CLEANUP_META})")
        } else {
            String::new()
        };
        let rows = |left: &str, right: &str| {
            count(
                &db,
                &format!(
                    "SELECT COUNT(*) FROM (SELECT {columns} FROM {left}.\"{table}\" {filter}
                     EXCEPT SELECT {columns} FROM {right}.\"{table}\" {filter})"
                ),
            )
        };
        let (missing, added) = (rows("old", "main"), rows("main", "old"));
        if missing != 0 || added != 0 {
            differing.push(format!("{table}: {missing} rows missing, {added} rows added"));
        }
        compared += 1;
    }
    assert!(compared > 20, "only {compared} tables compared");
    assert!(differing.is_empty(), "structural tables changed in the swap: {differing:?}");
    db.execute_batch("DETACH DATABASE old").unwrap();
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

    let snapshot = dir.0.join("swapped-copy.sqlite3");
    let owner = Owner::start(
        &dir.0,
        session,
        "swap",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_SNAPSHOT", snapshot.to_str().unwrap())],
    );
    let line = owner.wait_for_log("output cleanup: swapped the registry");
    assert!(line.contains("pruned ranges"), "{line}");
    // The background build packed the journal; this start staged only the
    // records after its last catch-up.
    let number_before = |marker: &str| -> u64 {
        line.split(marker)
            .next()
            .and_then(|before| before.rsplit(' ').next())
            .and_then(|count| count.parse().ok())
            .unwrap_or_else(|| panic!("no count before {marker:?} in {line:?}"))
    };
    let kept = number_before(" records kept");
    let tail = number_before(" records staged at this start");
    assert!(tail < kept && tail <= 64, "the start staged a tail of {tail} of {kept}: {line}");
    let previous = sidecar(&prepared.registry, ".pre-output-cleanup");
    assert_structural_tables_equal(&snapshot, &previous);
    assert_eq!(integrity(&prepared.registry), "ok");
    assert_cleaned(&owner, &prepared);
    owner.stop();
    assert!(previous.is_file(), "the previous registry stays through the swap launch");

    // The start after a full start on the new registry removes the old file.
    let owner = Owner::start(&dir.0, session, "after-swap", &[]);
    owner.wait_for_log("output cleanup: removed the previous registry");
    assert!(!previous.exists());
    let (_, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed");
    assert!(!owner.log_text().contains("output cleanup: staging"), "the cleanup runs once");
    owner.stop();
}

#[test]
fn a_swapped_registry_that_cannot_serve_is_rolled_back() {
    let dir = state_dir("rollback");
    let session = "oc-rollback";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();

    // The owner build fails after the swap (debug hook): the original goes
    // back under the session locks and the owner serves it.
    let owner = Owner::start(
        &dir.0,
        session,
        "swap-fails",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_FAIL_LOAD", "1")],
    );
    owner.wait_for_log("output cleanup: swapped the registry");
    owner.wait_for_log("restoring the previous registry");
    assert_eq!(workspaces(&owner), prepared.workspaces, "the original registry serves");
    let (journal, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed");
    assert_eq!(
        journal.iter().filter(|record| record.kind == "terminal.output").count(),
        SEEDED_SEALED + SEEDED_LIVE,
        "the original journal is back, output included"
    );
    owner.stop();
    assert!(!sidecar(&prepared.registry, ".pre-output-cleanup").exists());
    assert!(sidecar(&prepared.registry, ".output-cleanup-failed").is_file());
    assert_eq!(integrity(&prepared.registry), "ok");

    // This build does not try again.
    let owner = Owner::start(
        &dir.0,
        session,
        "after-rollback",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0")],
    );
    owner.wait_for_log("output cleanup: skipped; an earlier attempt failed");
    owner.stop();
}

/// The original registry serves again, with its output, and this build does
/// not try the cleanup again.
fn assert_rolled_back(dir: &Path, session: &str, owner: Owner, prepared: &Prepared) {
    owner.wait_for_log("restoring the previous registry");
    assert_eq!(workspaces(&owner), prepared.workspaces, "the original registry serves");
    let (journal, reason) = read_journal(&owner.socket());
    assert_eq!(reason, "completed");
    assert_eq!(
        journal.iter().filter(|record| record.kind == "terminal.output").count(),
        SEEDED_SEALED + SEEDED_LIVE,
        "the original journal is back, output included"
    );
    owner.stop();
    assert!(!sidecar(&prepared.registry, ".pre-output-cleanup").exists());
    assert!(sidecar(&prepared.registry, ".output-cleanup-failed").is_file());
    assert_eq!(integrity(&prepared.registry), "ok");
    let owner = Owner::start(
        dir,
        session,
        "after-rollback-check",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0")],
    );
    owner.wait_for_log("output cleanup: skipped; an earlier attempt failed");
    owner.stop();
}

#[test]
fn a_swapped_registry_that_does_not_open_is_rolled_back() {
    let dir = state_dir("open-fails");
    let session = "oc-open-fails";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();
    // The first open of the swapped registry fails (debug hook).
    let owner = Owner::start(
        &dir.0,
        session,
        "open-fails",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_FAIL_OPEN", "1")],
    );
    owner.wait_for_log("output cleanup: swapped the registry");
    assert_rolled_back(&dir.0, session, owner, &prepared);
}

#[test]
fn a_swap_start_that_never_finished_rolls_back_at_a_later_failed_start() {
    let dir = state_dir("unfinished");
    let session = "oc-unfinished";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();
    let owner = Owner::start(&dir.0, session, "swap", &[]);
    owner.wait_for_log("output cleanup: swapped the registry");
    owner.stop();
    // As if the swap start was killed during restore: no full start counted.
    Connection::open(&prepared.registry)
        .unwrap()
        .execute("UPDATE meta SET value = '0' WHERE key = 'output_cleanup_full_starts'", [])
        .unwrap();
    // A later start whose owner build fails still puts the original back.
    let owner = Owner::start(
        &dir.0,
        session,
        "later-fails",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_FAIL_LOAD", "1")],
    );
    assert!(!owner.log_text().contains("swapped the registry"), "no second swap");
    assert_rolled_back(&dir.0, session, owner, &prepared);
}

#[test]
fn an_owner_refuses_to_start_beside_a_backup_it_cannot_put_back() {
    let dir = state_dir("no-restore");
    let session = "oc-no-restore";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();
    let owner = Owner::start(&dir.0, session, "swap", &[]);
    owner.wait_for_log("output cleanup: swapped the registry");
    owner.stop();
    let registry = &prepared.registry;
    let previous = sidecar(registry, ".pre-output-cleanup");
    let backup = fs::read(&previous).unwrap();

    // As a swap interrupted after it moved the registry aside: only the
    // backup is left, beside the shared-memory file of the new registry. It
    // must be moved aside first, and a file where the recovery directory
    // goes makes that fail, so the backup cannot be put back. (A WAL with
    // data would be refused by the orphaned-journal check on its own.)
    fs::remove_file(registry).unwrap();
    let _ = fs::remove_file(sidecar(registry, "-wal"));
    fs::write(sidecar(registry, "-shm"), b"index of the new registry").unwrap();
    let blocker = registry.parent().unwrap().join("registry-recovery");
    fs::write(&blocker, b"not a directory").unwrap();

    let socket = dir.0.join("mux.sock");
    let _ = fs::remove_file(&socket);
    let mut child = command(&dir.0)
        .args(["--headless", "--session", session, "--socket"])
        .arg(&socket)
        .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", NEVER)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let Some(status) = child.wait_timeout(Duration::from_secs(60)).unwrap() else {
        let _ = child.kill();
        let _ = child.wait();
        panic!("the owner served beside the backup instead of refusing");
    };
    let mut stderr = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut stderr).unwrap();
    assert!(!status.success(), "the owner must refuse: {stderr}");
    assert!(stderr.contains(".pre-output-cleanup"), "the error names the backup: {stderr}");
    assert!(!registry.exists(), "no empty registry was created: {stderr}");
    assert_eq!(fs::read(&previous).unwrap(), backup, "the backup stays as it was");

    // With the obstacle gone, the next start puts the backup back and serves.
    fs::remove_file(&blocker).unwrap();
    let owner = Owner::start(&dir.0, session, "restored", &[]);
    owner.wait_for_log("restored the registry after an interrupted swap");
    assert_eq!(workspaces(&owner), prepared.workspaces, "the session is back");
    owner.stop();
}

/// A swap that an owner got through a full start on is confirmed: the
/// backup it kept is older than the session. When the registry is later
/// quarantined (unreadable), the backup goes to the same recovery directory.
/// Left in place, the start after the quarantine took the missing registry
/// for an interrupted swap and served the backup: the session from before
/// the swap, with everything done since silently undone.
#[test]
fn a_quarantined_registry_never_brings_back_the_backup_of_a_confirmed_swap() {
    let dir = state_dir("quarantine");
    let session = "oc-quarantine";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();
    let owner = Owner::start(&dir.0, session, "swap", &[]);
    owner.wait_for_log("output cleanup: swapped the registry");
    owner.cli(&["workspace", "create", "--empty", "--name", "after-swap"]);
    owner.stop();
    let registry = &prepared.registry;
    let previous = sidecar(registry, ".pre-output-cleanup");
    assert!(previous.is_file(), "the backup stays until the next start");

    // The registry is damaged before that next start.
    let _ = fs::remove_file(sidecar(registry, "-wal"));
    let _ = fs::remove_file(sidecar(registry, "-shm"));
    fs::write(registry, vec![0x5a_u8; 8192]).unwrap();
    let socket = dir.0.join("mux.sock");
    let _ = fs::remove_file(&socket);
    let mut child = command(&dir.0)
        .args(["--headless", "--session", session, "--socket"])
        .arg(&socket)
        .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", NEVER)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let Some(status) = child.wait_timeout(Duration::from_secs(60)).unwrap() else {
        let _ = child.kill();
        let _ = child.wait();
        panic!("the owner served a registry it cannot read");
    };
    let mut stderr = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut stderr).unwrap();
    assert!(!status.success(), "the owner must refuse: {stderr}");
    assert!(stderr.contains("registry-recovery"), "{stderr}");

    let owner = Owner::start(&dir.0, session, "after-quarantine", &[]);
    let log = owner.log_text();
    let served = workspaces(&owner);
    owner.stop();
    assert!(
        !log.contains("restored the registry after an interrupted swap"),
        "the backup of a confirmed swap was served: {log}"
    );
    assert!(
        served.iter().all(|(_, name)| name != "before-output" && name != "last"),
        "the session from before the swap came back: {served:?}"
    );
    assert!(!previous.exists(), "the backup left the registry's place");
    let kept_backup = fs::read_dir(registry.parent().unwrap().join("registry-recovery"))
        .unwrap()
        .map(|batch| batch.unwrap().path())
        .any(|batch| batch.join(previous.file_name().unwrap()).is_file());
    assert!(kept_backup, "the backup is kept beside the quarantined registry");
}

#[test]
fn a_restore_preview_reads_across_a_pruned_tail() {
    let dir = state_dir("tail");
    let session = "oc-tail";
    let prepared = prepare_with_tail(&dir.0, session, 40);
    stage(&dir.0, session, "stage").stop();
    let snapshot = dir.0.join("swapped-copy.sqlite3");
    let owner = Owner::start(
        &dir.0,
        session,
        "swap",
        &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_SNAPSHOT", snapshot.to_str().unwrap())],
    );
    owner.wait_for_log("output cleanup: swapped the registry");
    // The swapped journal ends in a pruned range.
    let swapped = read_only(&snapshot);
    assert_eq!(
        count(&swapped, "SELECT MAX(end_sequence) FROM journal_pruned_ranges"),
        count(&swapped, "SELECT MAX(end_sequence) FROM journal_segments"),
        "the fixture's journal ends in removed output"
    );
    let preview = resource_request(
        &owner.socket(),
        "session.journal.restore.preview",
        serde_json::json!({"machine":"current","session":"current","checkpoint":prepared.checkpoint}),
        "tail-preview",
    );
    assert!(preview.is_object(), "restore preview: {preview}");
    owner.stop();
}

#[test]
fn a_killed_cleanup_leaves_the_registry_usable_and_resumes() {
    let dir = state_dir("kill");
    let session = "oc-kill";
    let prepared = prepare(&dir.0, session);

    // One staged segment per 500 ms, so the kill lands inside Phase A.
    let owner = Owner::start(
        &dir.0,
        session,
        "stage-killed",
        &[
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0"),
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_PAUSE_MS", "500"),
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_PROGRESS_MS", "0"),
        ],
    );
    owner.wait_for_log("output cleanup: staged 1 of");
    assert!(!owner.log_text().contains("phase A complete"), "the kill lands in Phase A");
    owner.kill();

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
    let owner = Owner::start(&dir.0, session, "swap-after-resume", &[]);
    owner.wait_for_log("output cleanup: swapped the registry");
    assert_cleaned(&owner, &prepared);
    owner.stop();
}

/// A start whose swap would block on a long journal tail defers it and
/// serves the old registry; its cleanup thread packs the tail, and the next
/// start swaps.
#[test]
fn a_long_tail_after_the_build_defers_the_swap_until_the_thread_caught_up() {
    let dir = state_dir("deferred-tail");
    let session = "oc-tail";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();
    seed_output(&prepared.registry, 64, "after-build");

    let owner = Owner::start(
        &dir.0,
        session,
        "deferred",
        &[
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_TAIL_LIMIT", "16"),
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0"),
            ("CMUX_TUI_TEST_OUTPUT_CLEANUP_CATCH_UP_MS", "100"),
        ],
    );
    let line = owner.wait_for_log("output cleanup: swap deferred to a later start");
    let tail: u64 = line
        .split("later start: ")
        .nth(1)
        .and_then(|rest| rest.split(' ').next())
        .and_then(|count| count.parse().ok())
        .unwrap_or_else(|| panic!("no tail length in {line:?}"));
    assert!(tail >= 64, "the tail holds the rows seeded after the build: {line}");
    assert!(!sidecar(&prepared.registry, ".pre-output-cleanup").exists(), "nothing was swapped");
    assert_eq!(workspaces(&owner), prepared.workspaces, "the old registry serves");
    owner.wait_for_log("output cleanup: caught up through sequence");
    owner.stop();

    let owner =
        Owner::start(&dir.0, session, "swap", &[("CMUX_TUI_TEST_OUTPUT_CLEANUP_TAIL_LIMIT", "16")]);
    owner.wait_for_log("output cleanup: swapped the registry");
    assert_cleaned(&owner, &prepared);
    owner.stop();
}

/// A kill in the middle of the background build loses no packed segment:
/// the next owner resumes at the step and segment it reached.
#[test]
fn a_build_killed_midway_resumes_where_it_stopped() {
    let dir = state_dir("build-kill");
    let session = "oc-build-kill";
    let prepared = prepare(&dir.0, session);
    let small = [
        ("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_RECORDS", "2"),
        ("CMUX_TUI_TEST_OUTPUT_CLEANUP_PROGRESS_MS", "0"),
    ];
    let mut paused = small.to_vec();
    paused.push(("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", "0"));
    paused.push(("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_PAUSE_MS", "300"));
    let owner = Owner::start(&dir.0, session, "build-killed", &paused);
    owner.wait_for_log("output cleanup: packed 3 segments through sequence");
    assert!(!owner.log_text().contains("built the new registry"), "the kill lands in the build");
    owner.kill();
    assert_eq!(integrity(&prepared.registry), "ok");

    let owner = stage_with(&dir.0, session, "resume", &small);
    let line = owner.wait_for_log("output cleanup: resuming the background build at step pack");
    let packed: u64 = line
        .split('(')
        .nth(1)
        .and_then(|rest| rest.split(' ').next())
        .and_then(|count| count.parse().ok())
        .unwrap_or_else(|| panic!("no packed count in {line:?}"));
    assert!(packed >= 3, "the resumed build keeps the packed segments: {line}");
    let log = owner.log_text();
    assert!(!log.contains("output cleanup: staging "), "phase A is not staged again: {log}");
    assert!(
        !log.contains("building the new registry in the background"),
        "the build does not start over: {log}"
    );
    owner.stop();

    let owner = Owner::start(&dir.0, session, "swap", &[]);
    owner.wait_for_log("output cleanup: swapped the registry");
    assert_cleaned(&owner, &prepared);
    owner.stop();
}

/// A start killed after the swap committed and before the rename keeps the
/// built registry: the next start checks it again and renames it.
#[test]
fn a_swap_killed_before_its_rename_is_finished_by_the_next_start() {
    let dir = state_dir("rename-kill");
    let session = "oc-rename-kill";
    let prepared = prepare(&dir.0, session);
    stage(&dir.0, session, "stage").stop();

    let socket = dir.0.join("mux.sock");
    let log = File::create(dir.0.join("exit-before-rename.log")).unwrap();
    let mut child = command(&dir.0)
        .args(["--headless", "--session", session, "--socket"])
        .arg(&socket)
        .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", NEVER)
        .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_EXIT_BEFORE_RENAME", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log)
        .spawn()
        .unwrap();
    let status = child.wait_timeout(Duration::from_secs(120)).unwrap().expect("the start exits");
    assert!(!status.success());
    let text = fs::read_to_string(dir.0.join("exit-before-rename.log")).unwrap();
    assert!(text.contains("test: exiting after the swap committed"), "{text}");
    let staged = sidecar(&prepared.registry, ".output-cleanup");
    assert!(staged.is_file(), "the committed registry stays");
    assert_eq!(
        count(
            &read_only(&staged),
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'output_cleanup_state'"
        ),
        0,
        "the build state went with the commit"
    );
    assert_eq!(live_output_rows(&prepared.registry), SEEDED_LIVE as i64, "not swapped yet");

    let owner = Owner::start(&dir.0, session, "finish", &[]);
    owner.wait_for_log("output cleanup: finishing a swap an earlier start committed");
    owner.wait_for_log("output cleanup: swapped the registry");
    assert_cleaned(&owner, &prepared);
    owner.stop();
}
