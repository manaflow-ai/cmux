//! Terminal output lives in the daemon's output store, never in the session
//! journal (port of feat #22937). `CMUX_TUI_TERMINAL_PERSISTENCE` selects
//! `memory` (nothing on disk) or `snapshot` (the default: one compressed
//! screen per terminal, written only when it changed).
//!
//! An agent TUI that waits for input redraws its cursor about 40 times a
//! second. Each redraw was one `terminal.output` journal row with a synced
//! commit: about 25 MB/s of disk writes from three idle agents. Output that
//! never stops also kept the journal head moving, so a checkpoint could not
//! find a stable cut, and one flooding terminal filled the shared terminal
//! lane and dropped the output of every other terminal. These tests run the
//! real daemon and check, at its files and its socket:
//! - idle redrawing terminals change no file in the state folder, and the
//!   journal holds no output;
//! - a checkpoint succeeds while a terminal floods output;
//! - a terminal that prints while another one floods (with the journal
//!   writer held) keeps its output.
//!
//! `CMUX_OUTPUT_STORE_IDLE_SECS` sets the idle window (default 10 s).

use super::*;

/// The frame an idle agent TUI repeats (from a NIGHTLY journal): a
/// synchronized update that moves and shows the cursor.
const REDRAW_SCRIPT: &str = "while :; do printf '\\033[?2026h\\033[39m\\033[49m\\033[0m\\033[20;3H\\033[?25h\\033[?2026l'; sleep 0.025; done";
const IDLE_TERMINALS: usize = 3;
const SNAPSHOT_INTERVAL_MS: &str = "300";
/// Output that does not stop: 256 KiB blocks with no pause.
const FLOOD_SCRIPT: &str =
    "while :; do /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\0' x; done";
/// The journal's terminal lane holds 1024 chunks (journal_ingress.rs).
const TERMINAL_LANE_CHUNKS: u64 = 1024;

fn idle_window() -> Duration {
    Duration::from_secs(
        std::env::var("CMUX_OUTPUT_STORE_IDLE_SECS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(10),
    )
}

fn harness(name: &str, mode: &str) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.extra_env.push(("CMUX_TUI_TERMINAL_PERSISTENCE".into(), mode.into()));
    harness
        .extra_env
        .push(("CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS".into(), SNAPSHOT_INTERVAL_MS.into()));
    harness.restart();
    harness
}

/// Every file below `root` with its length and modification time.
fn file_states(root: &Path) -> Vec<(PathBuf, u64, SystemTime)> {
    let mut states = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else { continue };
            if metadata.is_dir() {
                pending.push(path);
            } else if metadata.is_file() {
                states.push((path, metadata.len(), metadata.modified().unwrap()));
            }
        }
    }
    states.sort();
    states
}

fn files_named(root: &Path, extension: &str) -> Vec<PathBuf> {
    file_states(root)
        .into_iter()
        .map(|(path, _, _)| path)
        .filter(|path| path.extension().is_some_and(|value| value == extension))
        .collect()
}

fn registry_path(state: &Path) -> PathBuf {
    file_states(state)
        .into_iter()
        .map(|(path, _, _)| path)
        .find(|path| path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3"))
        .expect("the daemon has no registry")
}

/// Journal rows that carry terminal output (kind or content).
fn journal_output_rows(state: &Path) -> i64 {
    let connection = rusqlite::Connection::open_with_flags(
        registry_path(state),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    connection
        .query_row(
            "SELECT count(*) FROM session_journal
             WHERE kind = 'terminal.output' OR content IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap()
}

fn idle_terminals_write_nothing(mode: &str) {
    let harness = harness(&format!("output-idle-{mode}"), mode);
    for index in 0..IDLE_TERMINALS {
        request(
            &harness.socket,
            serde_json::json!({
                "id":index,"cmd":"run","argv":["/bin/sh","-c",REDRAW_SCRIPT],
                "new_workspace":true,"cols":120,"rows":40,
            }),
        );
    }
    wait_for_host_records(&harness.host_root(), IDLE_TERMINALS);
    // First frames, the first snapshots and the startup commits settle.
    std::thread::sleep(Duration::from_secs(3));
    let before = file_states(&harness.state);
    std::thread::sleep(idle_window());
    let after = file_states(&harness.state);
    let changed = after
        .iter()
        .filter(|state| !before.contains(state))
        .map(|(path, len, _)| format!("{} ({len} bytes)", path.display()))
        .collect::<Vec<_>>();
    assert!(
        changed.is_empty(),
        "idle redrawing terminals changed files in {mode} mode: {changed:#?}"
    );
    assert_eq!(journal_output_rows(&harness.state), 0, "the journal holds terminal output");
    if mode == "memory" {
        let stored = files_named(&harness.state, "snap");
        assert!(stored.is_empty(), "memory mode wrote output files: {stored:?}");
    }
}

#[test]
fn idle_redrawing_terminals_write_nothing_in_memory_mode() {
    idle_terminals_write_nothing("memory");
}

#[test]
fn idle_redrawing_terminals_write_nothing_in_snapshot_mode() {
    idle_terminals_write_nothing("snapshot");
}

/// #39865 open item 2 (run 3): with output in the journal, a terminal that
/// never stops printing moves the journal head during every capture
/// attempt, and `session.journal.checkpoint.create` fails with "session
/// changed during checkpoint capture". Output is not in the journal, so the
/// cut is stable while the terminal prints.
#[test]
fn checkpoint_succeeds_while_a_terminal_floods_output() {
    let harness = RecoveryHarness::start("output-store-flood-checkpoint");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/sh","-c",FLOOD_SCRIPT],
            "new_workspace":true,"cols":120,"rows":40,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    // The flood runs before the first checkpoint.
    assert!(
        wait_for_screen(&harness.socket, surface, "xxxxxxxx").contains("xxxxxxxx"),
        "the flooding terminal printed nothing"
    );
    for attempt in 0..3 {
        let key = format!("output-store-flood-checkpoint-{attempt}");
        let checkpoint = request_response(
            &harness.socket,
            serde_json::json!({
                "protocol":"cmux.protocol/2",
                "type":"request",
                "id":key,
                "operation":"session.journal.checkpoint.create",
                "params":{"machine":"current","session":"current"},
                "idempotency_key":key,
            }),
        );
        assert_eq!(
            checkpoint["ok"], true,
            "checkpoint {attempt} failed while a terminal flooded output: {checkpoint}"
        );
    }
    close_terminal_surface(&harness.socket, surface, 2);
}

/// #39865 open item 3 (fairness): the journal's terminal lane is shared.
/// With the journal writer held (a slow disk), one flooding terminal filled
/// it, and a second terminal that printed one line then lost that line: the
/// line went to a gap, and `terminal.output_read` never had it. Output is
/// kept per terminal in the output store, so the flood cannot take the
/// other terminal's output.
#[test]
fn flooding_terminal_does_not_drop_another_terminals_output() {
    let harness = RecoveryHarness::start_with_terminal_journal_hold("output-store-fair");
    let pid = std::process::id();
    // Both terminals wait for one input line, so neither prints before the
    // test is ready.
    let flood = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run",
            "argv":["/bin/sh","-c",format!(
                "read line; /usr/bin/head -c 100663296 /dev/zero | /usr/bin/tr '\\0' x; \
                 printf '\\n%s-%s\\n' flood done-{pid}; exec sleep 600"
            )],
            "new_workspace":true,"cols":120,"rows":40,
        }),
    );
    let quiet = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"run",
            "argv":["/bin/sh","-c","read line; printf '%s-%s\\n' quiet \"$line\"; exec sleep 600"],
            "new_workspace":true,"cols":120,"rows":40,
        }),
    );
    let flood_surface = flood["surface"].as_u64().unwrap();
    let quiet_surface = quiet["surface"].as_u64().unwrap();
    let flood_terminal = terminal_resource_id(&harness.socket, flood_surface, 3);
    let quiet_terminal = terminal_resource_id(&harness.socket, quiet_surface, 4);

    let started = terminal_input_request(
        &harness.socket,
        "output-store-fair-flood",
        "terminal.input.write",
        serde_json::json!({"text":"go\n"}),
        &flood_terminal,
    );
    assert_eq!(started["ok"], true, "starting the flood failed: {started}");
    // The flood is past the journal's terminal lane when the lane is full
    // (output in the journal) or the flood has ended (output in the store).
    let flood_done = format!("flood-done-{pid}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(120));
    loop {
        let stats = request(&harness.socket, serde_json::json!({"id":5,"cmd":"server-stats"}));
        let queued = stats["journal_writer"]["terminal_queued"].as_u64().unwrap_or(0);
        if queued >= TERMINAL_LANE_CHUNKS {
            break;
        }
        let screen = request(
            &harness.socket,
            serde_json::json!({"cmd":"read-screen","surface":flood_surface}),
        )["text"]
            .as_str()
            .unwrap()
            .to_string();
        if screen.contains(&flood_done) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the flood neither filled the terminal lane nor ended: {stats}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // The input line is not echoed under `sh -c`; only the printf prints
    // the marker.
    let marker = format!("quiet-marker-{pid}");
    let typed = terminal_input_request(
        &harness.socket,
        "output-store-fair-quiet",
        "terminal.input.write",
        serde_json::json!({"text":format!("marker-{pid}\n")}),
        &quiet_terminal,
    );
    assert_eq!(typed["ok"], true, "typing into the quiet terminal failed: {typed}");
    assert!(
        wait_for_screen(&harness.socket, quiet_surface, &marker).contains(&marker),
        "the quiet terminal did not print its marker"
    );

    harness.release_terminal_journal();
    let read = output_read(&harness.socket, "output-store-fair-read", &quiet_terminal, None, None);
    assert!(
        read["text"].as_str().unwrap().contains(&marker),
        "a flooding terminal dropped another terminal's output: {read}"
    );
    close_terminal_surface(&harness.socket, flood_surface, 6);
    close_terminal_surface(&harness.socket, quiet_surface, 7);
}
