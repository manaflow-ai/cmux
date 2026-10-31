//! Terminal output lives in the output store, never in the session journal
//! (cmux-tui-core output_store.rs), with `terminal.persistence.mode`:
//! `memory` (nothing on disk), `snapshot` (default: one compressed screen
//! per terminal, written only when it changed) or `full` (also every byte in
//! compressed segment files).
//!
//! An agent TUI that waits for input redraws its cursor about 40 times a
//! second. Each redraw used to be one `terminal.output` journal row with a
//! synced commit: about 25 MB/s of disk writes from three idle agents, and a
//! 41.6 GB registry. These tests run the real daemon and check, at its files
//! and its socket:
//! - idle redrawing terminals change no file in the state folder in any mode
//!   but the registry, and the registry only by the terminal's `last_output`
//!   time (`terminal.progress`, at most once per 5 s per printing terminal,
//!   terminal_activity.rs); the journal holds no output;
//! - after the daemon and its terminal hosts are killed (a reboot), the
//!   respawned terminal shows its earlier screen in `snapshot` and `full`,
//!   and nothing of it in `memory`, which leaves no output file on disk.
//!
//! `CMUX_OUTPUT_STORE_IDLE_SECS` sets the idle window (default 10 s); a
//! measurement run uses 60 and `--nocapture` for the numbers.

use super::pty_custody::{kill_shell_then_host, send_line};
use super::*;

/// The frame an idle agent TUI repeats (from a NIGHTLY journal): a
/// synchronized update that moves and shows the cursor.
const REDRAW_SCRIPT: &str = "while :; do printf '\\033[?2026h\\033[39m\\033[49m\\033[0m\\033[20;3H\\033[?25h\\033[?2026l'; sleep 0.025; done";
const IDLE_TERMINALS: usize = 3;
const SNAPSHOT_INTERVAL_MS: &str = "300";

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

/// (bytes written by write calls, CPU time) of `pid` (Linux; `None` elsewhere).
fn process_io(pid: u32) -> Option<(u64, Duration)> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    let io = fs::read_to_string(format!("/proc/{pid}/io")).ok()?;
    let wchar = io.lines().find_map(|line| line.strip_prefix("wchar: "))?.trim().parse().ok()?;
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields = stat.rsplit(')').next()?.split_whitespace().collect::<Vec<_>>();
    let ticks: u64 = fields.get(11)?.parse::<u64>().ok()? + fields.get(12)?.parse::<u64>().ok()?;
    // SAFETY: sysconf has no preconditions.
    let hertz = u64::try_from(unsafe { libc::sysconf(libc::_SC_CLK_TCK) }).ok()?.max(1);
    Some((wchar, Duration::from_millis(ticks * 1000 / hertz)))
}

/// The journal's row count per kind.
fn journal_kinds(state: &Path) -> std::collections::BTreeMap<String, i64> {
    let connection = rusqlite::Connection::open_with_flags(
        registry_path(state),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mut statement =
        connection.prepare("SELECT kind, count(*) FROM session_journal GROUP BY kind").unwrap();
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// Whether `path` is the registry database or its WAL or shared-memory file.
fn is_registry_file(path: &Path) -> bool {
    path.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
        name.strip_prefix("workspace-registry.sqlite3")
            .is_some_and(|rest| rest.is_empty() || rest == "-wal" || rest == "-shm")
    })
}

fn idle_terminals_write_nothing(mode: &str) {
    let _exclusive = exclusive_process_test();
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
    let pid = harness.child.as_ref().unwrap().id();
    let journal_before = journal_kinds(&harness.state);
    let before = file_states(&harness.state);
    let io_before = process_io(pid);
    let window = idle_window();
    std::thread::sleep(window);
    let after = file_states(&harness.state);
    let io_after = process_io(pid);
    if let (Some((written_before, cpu_before)), Some((written_after, cpu_after))) =
        (io_before, io_after)
    {
        eprintln!(
            "output-store idle {mode}: {IDLE_TERMINALS} redrawing terminals for {}s: daemon \
             write() {} bytes ({:.1} B/s), CPU {} ms ({:.2}% of one core)",
            window.as_secs(),
            written_after - written_before,
            (written_after - written_before) as f64 / window.as_secs_f64(),
            (cpu_after - cpu_before).as_millis(),
            (cpu_after - cpu_before).as_secs_f64() * 100.0 / window.as_secs_f64(),
        );
    }
    // The registry may take the terminals' last_output time (1f4437e6f08, #24084: a printing
    // terminal pushes it at most once per 5 s): those commits, and nothing else.
    let journal_after = journal_kinds(&harness.state);
    let grown = journal_after
        .iter()
        .filter_map(|(kind, rows)| {
            let added = rows - journal_before.get(kind).copied().unwrap_or(0);
            (added != 0).then(|| (kind.clone(), added))
        })
        .collect::<std::collections::BTreeMap<_, _>>();
    let progress = grown.get("terminal.progress").copied().unwrap_or(0);
    let allowed =
        i64::try_from(IDLE_TERMINALS).unwrap() * (i64::try_from(window.as_secs()).unwrap() / 5 + 1);
    assert!(
        grown.keys().all(|kind| kind == "terminal.progress") && progress <= allowed,
        "idle redrawing terminals committed more than their last_output time in {mode} mode \
         ({allowed} terminal.progress rows at most): {grown:?}"
    );
    let changed = after
        .iter()
        .filter(|state| !before.contains(state))
        .filter(|(path, _, _)| !is_registry_file(path))
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

#[test]
fn idle_redrawing_terminals_write_nothing_in_full_mode() {
    idle_terminals_write_nothing("full");
}

/// The line a respawn writes below the previous screen.
const RESPAWN_MARKER: &str = "session restored (previous process ended)";

/// A plain `sh` in a new workspace: (public terminal id, incarnation, surface).
fn start_shell(harness: &RecoveryHarness, name: &str) -> (String, String, u64) {
    let workspace = create_empty_workspace(&harness.socket, &format!("{name}-workspace"), name);
    let run = resource_request(
        &harness.socket,
        &format!("{name}-run"),
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh"],
        }),
        Some(&format!("{name}-run")),
    );
    let terminal_id = run["value"]["terminal_id"].as_str().unwrap().to_string();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if let Some(surface) = resolved["surface"].as_u64() {
            let incarnation = resolved["terminal_incarnation"].as_str().unwrap().to_string();
            return (terminal_id, incarnation, surface);
        }
        assert!(Instant::now() < deadline, "the shell has no surface: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The surface of `terminal_id` once it runs an incarnation other than `old`.
fn respawned_surface(harness: &RecoveryHarness, terminal_id: &str, old: &str) -> u64 {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if !incarnation.is_empty()
            && incarnation != old
            && let Some(surface) = resolved["surface"].as_u64()
        {
            return surface;
        }
        assert!(Instant::now() < deadline, "the terminal was not respawned: {resolved}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Lines the restore tests print: more than the in-memory output tail
/// (64 KiB) holds, so the oldest are only in full mode's segment files.
const RESTORE_LINES: usize = 20_000;

struct Restored {
    /// `terminal.output_read` from offset 0 just before the crash.
    oldest_read: serde_json::Value,
    /// The respawned terminal's screen.
    screen: String,
    state: PathBuf,
    /// Kept alive: dropping it removes the state folder.
    _harness: RecoveryHarness,
}

/// Print [`RESTORE_LINES`] numbered lines and a marker, wait for the
/// writer, read the oldest output, then kill the daemon, the shell and its
/// host (a crash, then a reboot) and start a new daemon.
fn restore_after_reboot(mode: &str) -> Restored {
    let mut harness = harness(&format!("output-restore-{mode}"), mode);
    let (terminal_id, incarnation, surface) = start_shell(&harness, "restore");
    send_line(&harness.socket, surface, &format!("seq -f 'restore-line-%g' 1 {RESTORE_LINES}"));
    send_line(&harness.socket, surface, "printf 'restore-%s\\n' marker");
    wait_for_screen(&harness.socket, surface, "restore-marker\n");
    // The writer runs one interval after the last output.
    std::thread::sleep(Duration::from_millis(SNAPSHOT_INTERVAL_MS.parse::<u64>().unwrap() * 5));
    let oldest_read =
        output_read(&harness.socket, "restore-oldest", &terminal_id, Some("0"), Some(4096));
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.signal_daemon(libc::SIGSTOP);
    kill_shell_then_host(&record_path, &record);
    harness.sigkill();
    harness.restart();
    let surface = respawned_surface(&harness, &terminal_id, &incarnation);
    let screen = wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
    let state = harness.state.clone();
    Restored { oldest_read, screen, state, _harness: harness }
}

#[test]
fn snapshot_mode_restores_the_screen_after_a_crash_and_reboot() {
    let _exclusive = exclusive_process_test();
    let restored = restore_after_reboot("snapshot");
    assert!(
        restored.screen.contains("restore-marker"),
        "the screen was not restored: {}",
        restored.screen
    );
    // The in-memory tail holds only the newest output.
    assert_ne!(restored.oldest_read["start_offset"], "0", "{}", restored.oldest_read);
    assert!(!files_named(&restored.state, "snap").is_empty(), "snapshot mode wrote no snapshot");
    assert!(files_named(&restored.state, "seg").is_empty(), "snapshot mode wrote segments");
    assert_eq!(journal_output_rows(&restored.state), 0, "the journal holds terminal output");
}

#[test]
fn full_mode_keeps_every_byte_and_restores_the_screen_after_a_crash_and_reboot() {
    let _exclusive = exclusive_process_test();
    let restored = restore_after_reboot("full");
    assert!(
        restored.screen.contains("restore-marker"),
        "the screen was not restored: {}",
        restored.screen
    );
    // The oldest output comes back from the segment files.
    assert_eq!(restored.oldest_read["start_offset"], "0", "{}", restored.oldest_read);
    assert!(
        restored.oldest_read["text"].as_str().unwrap().contains("restore-line-1\n"),
        "full mode lost the oldest output: {}",
        restored.oldest_read
    );
    assert!(!files_named(&restored.state, "seg").is_empty(), "full mode wrote no segment file");
    assert_eq!(journal_output_rows(&restored.state), 0, "the journal holds terminal output");
}

#[test]
fn memory_mode_keeps_no_output_on_disk_and_loses_it_after_a_reboot() {
    let _exclusive = exclusive_process_test();
    let restored = restore_after_reboot("memory");
    assert!(
        !restored.screen.contains("restore-marker") && !restored.screen.contains("restore-line-"),
        "memory mode restored output from disk: {}",
        restored.screen
    );
    let stored =
        [files_named(&restored.state, "snap"), files_named(&restored.state, "seg")].concat();
    assert!(stored.is_empty(), "memory mode wrote output files: {stored:?}");
    assert_eq!(journal_output_rows(&restored.state), 0, "the journal holds terminal output");
}

/// History rows `surface` can scroll back to.
fn history_rows(harness: &RecoveryHarness, surface: u64) -> u64 {
    request(
        &harness.socket,
        serde_json::json!({"cmd":"read-scrollback","surface":surface,"start":0,"count":1}),
    )["total"]
        .as_u64()
        .unwrap()
}

/// Past `terminal.scrollback.maxTotalMemoryBytes` the terminals that printed
/// least recently give back scrollback first; the most recent keeps its own
/// Ghostty `scrollback-limit`.
#[test]
fn idle_terminals_give_back_scrollback_past_the_total_memory_budget() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("output-memory-budget");
    harness
        .extra_env
        .push(("CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS".into(), SNAPSHOT_INTERVAL_MS.into()));
    // 16 MiB for four terminals that each fill a 10 MB scrollback.
    harness
        .extra_env
        .push(("CMUX_TUI_TERMINAL_SCROLLBACK_MEMORY_BYTES".into(), (16 << 20).to_string()));
    harness.restart();
    let mut surfaces = Vec::new();
    for index in 0..4 {
        let done = format!("budget-done-{index}");
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id":index,"cmd":"run",
                "argv":["/bin/sh","-c",format!(
                    "seq -f 'budget line %g padded to look like a long build log line' 1 40000; \
                     echo {done}; exec sleep 600"
                )],
                "new_workspace":true,"cols":120,"rows":40,
            }),
        );
        let surface = created["surface"].as_u64().unwrap();
        wait_for_screen(&harness.socket, surface, &done);
        surfaces.push(surface);
    }
    let first_full = history_rows(&harness, surfaces[3]);
    // The writer's pass runs one interval after the last output.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let oldest = history_rows(&harness, surfaces[0]);
        let newest = history_rows(&harness, surfaces[3]);
        if oldest * 3 < newest {
            assert_eq!(newest, first_full, "the most recent terminal lost scrollback");
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the idle terminal kept {oldest} rows next to {newest} over the memory budget"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The total budget holds while terminals print, not one writer interval
/// later (P-AUSTIN B8, #27693, #27702). The budget pass used to run only on
/// the snapshot writer's timer (30 s), so a flood grew the daemon past the
/// budget for that whole interval: 16 terminals at 1 MB/s with a 1 GB
/// `scrollback-limit` took the daemon to 2.25 GB against the 256 MiB budget
/// before the pass cut it back (cmux20, 2026-10-30). The interval here is one
/// hour, so only the growth itself can start the pass.
#[test]
fn the_total_memory_budget_holds_while_terminals_print_not_one_interval_later() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("output-memory-budget-growth");
    harness
        .extra_env
        .push(("CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS".into(), (3_600_000).to_string()));
    // 16 MiB for four terminals that each fill a 10 MB scrollback.
    harness
        .extra_env
        .push(("CMUX_TUI_TERMINAL_SCROLLBACK_MEMORY_BYTES".into(), (16 << 20).to_string()));
    harness.restart();
    let mut surfaces = Vec::new();
    for index in 0..4 {
        let done = format!("growth-done-{index}");
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id":index,"cmd":"run",
                "argv":["/bin/sh","-c",format!(
                    "seq -f 'budget line %g padded to look like a long build log line' 1 40000; \
                     echo {done}; exec sleep 600"
                )],
                "new_workspace":true,"cols":120,"rows":40,
            }),
        );
        let surface = created["surface"].as_u64().unwrap();
        wait_for_screen(&harness.socket, surface, &done);
        surfaces.push(surface);
    }
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let oldest = history_rows(&harness, surfaces[0]);
        let newest = history_rows(&harness, surfaces[3]);
        if oldest * 3 < newest {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "four full terminals kept {oldest} and {newest} rows over the 16 MiB budget: \
             the budget waited for the writer's interval instead of the growth"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}
