//! REOPEN-F3 (STATUS 4421, dogfood f350103): a kill -9 of the app, the
//! daemon and every terminal host, then a reopen. Each respawned terminal
//! showed only the "session restored" line and a new prompt: its last screen
//! (400 numbered lines) and its 363-row scrollback were gone, and its
//! directory read /private/tmp instead of /tmp.
//!
//! Lawrence's rule (cmux-ad 2026-11-02 01:30Z): when the terminal hosts die,
//! the stored output restores the text exactly, then one clear "session
//! ended" line, and the new shell starts in the same path string (no
//! symlinks resolved).
//!
//! These tests run the daemon with the production snapshot interval (no
//! `CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS`): the store wrote a terminal's
//! snapshot at most every 30 s, so a kill a few seconds after the output found
//! no stored screen at all.

use super::pty_custody::{kill_shell_then_host, send_line};
use super::*;

/// The line a respawn writes below the previous screen (a shell's or a
/// command's form).
const RESPAWN_MARKER: &str = "session restored (previous process ended";

/// A daemon in the default `snapshot` mode with the production intervals.
fn production_harness(name: &str) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.extra_env.push(("CMUX_TUI_TERMINAL_PERSISTENCE".into(), "snapshot".into()));
    harness.restart();
    harness
}

/// A plain interactive `sh` in a new workspace, started in `cwd`:
/// (public terminal id, incarnation, surface).
fn start_shell_in(harness: &RecoveryHarness, name: &str, cwd: &Path) -> (String, String, u64) {
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
            "cwd":cwd.to_str().unwrap(),
            "cols":120,
            "rows":40,
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

/// Every line of `surface`'s scrollback and screen, right-trimmed, without
/// the blank rows below the last text.
fn transcript(harness: &RecoveryHarness, surface: u64) -> Vec<String> {
    let copied = request(
        &harness.socket,
        serde_json::json!({"cmd":"copy","surface":surface,"mode":"scrollback"}),
    );
    let text = copied["text"].as_str().unwrap_or_else(|| panic!("no scrollback text: {copied}"));
    let mut lines = text.lines().map(|line| line.trim_end().to_string()).collect::<Vec<_>>();
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines
}

/// The kill of REOPEN-F3: the daemon stops first (it reads nothing more),
/// then the shell and its host die, then the daemon; a new daemon starts.
fn kill_everything_and_restart(harness: &mut RecoveryHarness) {
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.signal_daemon(libc::SIGSTOP);
    kill_shell_then_host(&record_path, &record);
    harness.sigkill();
    harness.restart();
}

/// `<dir>/real` and `<dir>/link -> real`: a directory reached through a
/// symlink, as /tmp is on macOS (-> /private/tmp).
fn symlinked_directory(harness: &RecoveryHarness) -> (PathBuf, PathBuf) {
    let real = harness.dir.join("real");
    let link = harness.dir.join("link");
    fs::create_dir_all(&real).unwrap();
    std::os::unix::fs::symlink(&real, &link).unwrap();
    (real, link)
}

#[test]
fn kill_all_restores_the_exact_screen_and_scrollback_then_the_session_line() {
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("kill-all-exact");
    let home = harness.dir.clone();
    let (terminal_id, incarnation, surface) = start_shell_in(&harness, "exact", &home);
    // 400 numbered lines in a 40-row terminal: the screen and 360 rows of
    // scrollback, as in the film.
    // One command line: a second line typed ahead is echoed and run at a
    // shell-dependent place (dash prints its prompt before the output).
    send_line(&harness.socket, surface, "seq -f 'f3-line-%g' 1 400; printf 'f3-%s\\n' done");
    wait_for_screen(&harness.socket, surface, "f3-done\n");
    // A few seconds, far less than the 30 s snapshot interval: the screen
    // is settled, as it was when the film killed everything.
    std::thread::sleep(Duration::from_secs(2));
    let before = transcript(&harness, surface);
    assert!(
        before.iter().any(|line| line == "f3-line-1")
            && before.iter().any(|line| line == "f3-done"),
        "the set-up did not print its lines: {before:#?}"
    );

    kill_everything_and_restart(&mut harness);
    let surface = respawned_surface(&harness, &terminal_id, &incarnation);
    wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
    let after = transcript(&harness, surface);

    let restored = after.get(..before.len()).unwrap_or(&after);
    assert_eq!(
        restored,
        before.as_slice(),
        "the respawned terminal does not start with the exact text it had before the kill \
         ({} lines before, {} after)",
        before.len(),
        after.len()
    );
    let next = after.get(before.len()).cloned().unwrap_or_default();
    assert!(
        next.contains(RESPAWN_MARKER),
        "the line after the restored text is not the session line: {next:?} (after: {after:#?})"
    );
}

/// A terminal that prints until the kill (a build log, a TUI) keeps
/// everything but the last moments: the store's loss window is bounded in
/// time, it does not wait for the output to stop.
#[test]
fn kill_all_while_output_streams_restores_every_line_but_the_last_moment() {
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("kill-all-stream");
    let home = harness.dir.clone();
    let (terminal_id, incarnation, surface) = start_shell_in(&harness, "stream", &home);
    send_line(
        &harness.socket,
        surface,
        "i=0; while [ $i -lt 100000 ]; do i=$((i+1)); echo f3-stream-$i; sleep 0.01; done",
    );
    wait_for_screen(&harness.socket, surface, "f3-stream-1\n");
    let started = Instant::now();
    std::thread::sleep(Duration::from_secs(3));
    let last_seen = |lines: &[String]| {
        lines
            .iter()
            .filter_map(|line| line.strip_prefix("f3-stream-")?.parse::<u64>().ok())
            .max()
            .unwrap_or(0)
    };
    let seen = last_seen(&transcript(&harness, surface));
    let elapsed = started.elapsed();
    assert!(seen > 20, "the loop printed too little to judge: {seen} lines");

    kill_everything_and_restart(&mut harness);
    let surface = respawned_surface(&harness, &terminal_id, &incarnation);
    wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
    let after = transcript(&harness, surface);

    // Every stored line is there in order, from the first, with no gap; the
    // last one may be cut where the kill fell.
    let numbers = after
        .iter()
        .filter_map(|line| line.strip_prefix("f3-stream-")?.parse::<u64>().ok())
        .collect::<Vec<_>>();
    let whole = numbers.len().saturating_sub(1);
    for (index, number) in numbers.iter().take(whole).enumerate() {
        assert_eq!(
            *number,
            index as u64 + 1,
            "the restored lines have a gap or are out of order at line {index}: {numbers:?}"
        );
    }
    let restored = numbers.get(whole.saturating_sub(1)).copied().unwrap_or(0);
    // Lines printed in the last 0.5 s before the read may be lost (the
    // writer's 100 ms window plus a loaded runner), never more.
    let per_second = seen as f64 / elapsed.as_secs_f64().max(0.1);
    let allowed = (per_second * 0.5).ceil() as u64 + 2;
    assert!(
        restored + allowed >= seen,
        "after the kill only {restored} of the {seen} lines seen before it came back \
         (at most {allowed} may be lost): {after:#?}"
    );
    assert!(
        after.last().is_some_and(|_| after.iter().any(|line| line.contains(RESPAWN_MARKER))),
        "no session line after the restored text: {after:#?}"
    );
}

/// The directory line the probe with `label` printed.
fn read_cwd(socket: &Path, surface: u64, label: &str) -> String {
    let prefix = format!("{label}=");
    let screen = wait_for_screen(socket, surface, &prefix);
    screen
        .lines()
        .rev()
        .find(|line| line.starts_with(&prefix))
        .map(|line| line.trim_end().to_string())
        .unwrap_or_else(|| panic!("the shell printed no {label} line: {screen}"))
}

/// A probe that prints `$PWD` after `label=`; the label is split in the
/// typed command, so only the shell's output matches it.
/// The shell compares its `$PWD` with `expected` itself and prints `same`,
/// else its `$PWD`: a long path would wrap across screen rows, a short
/// answer never does.
fn cwd_probe(label: &str, expected: &Path) -> String {
    let (head, rest) = label.split_at(2);
    format!(
        "if [ \"$PWD\" = '{}' ]; then printf '{head}''{rest}=%s\\n' same; \
         else printf '{head}''{rest}=%s\\n' \"$PWD\"; fi",
        expected.display()
    )
}

/// The respawned shell keeps the directory as the path string it was given:
/// a directory reached through a symlink is not shown as its real path.
#[test]
fn kill_all_respawned_shell_keeps_its_directory_path_string() {
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("kill-all-cwd");
    let (real, link) = symlinked_directory(&harness);
    let (terminal_id, incarnation, surface) = start_shell_in(&harness, "cwd", &link);
    send_line(&harness.socket, surface, &cwd_probe("f3-cwd-before", &link));
    assert_eq!(
        read_cwd(&harness.socket, surface, "f3-cwd-before"),
        "f3-cwd-before=same",
        "the shell started in {} reports its real path {}",
        link.display(),
        real.display()
    );

    kill_everything_and_restart(&mut harness);
    let surface = respawned_surface(&harness, &terminal_id, &incarnation);
    wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
    // Its own label: the restored screen holds the first probe's line.
    send_line(&harness.socket, surface, &cwd_probe("f3-cwd-after", &link));
    assert_eq!(
        read_cwd(&harness.socket, surface, "f3-cwd-after"),
        "f3-cwd-after=same",
        "the respawned shell reports the real path {} instead of {}",
        real.display(),
        link.display()
    );
}

/// Bytes `pid` handed to write(2) and friends: macOS `ri_logical_writes`
/// (proc_pid_rusage), Linux `wchar` (/proc). `None` elsewhere.
fn logical_writes(pid: u32) -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        let mut info = std::mem::MaybeUninit::<libc::rusage_info_v4>::zeroed();
        // SAFETY: the buffer is a rusage_info_v4, the flavor asks for v4.
        let status = unsafe {
            libc::proc_pid_rusage(
                pid as libc::c_int,
                libc::RUSAGE_INFO_V4,
                info.as_mut_ptr().cast::<libc::c_void>().cast(),
            )
        };
        if status != 0 {
            return None;
        }
        // SAFETY: proc_pid_rusage filled it.
        Some(unsafe { info.assume_init() }.ri_logical_writes)
    }
    #[cfg(target_os = "linux")]
    {
        let io = fs::read_to_string(format!("/proc/{pid}/io")).ok()?;
        io.lines().find_map(|line| line.strip_prefix("wchar: "))?.trim().parse().ok()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = pid;
        None
    }
}

/// Measurement, not a check (ignored: `cargo test --test terminal_host_recovery
/// kill_all_heavy -- --ignored --nocapture`): the daemon's disk writes
/// under the HEAVY load of the reopen films, 12 panes of a full-screen TUI
/// that repaints 40 rows with new content at about 60 Hz. Prints
/// `kill-all-heavy: {...}` with the logical write bytes per pane per second
/// and the state folder size. Run it at the base and at the fix for the
/// before/after.
#[test]
#[ignore = "measurement: run it with --ignored"]
fn kill_all_heavy_load_disk_writes_per_pane() {
    const PANES: usize = 12;
    const WINDOW: Duration = Duration::from_secs(20);
    let _exclusive = exclusive_process_test();
    let window = WINDOW;
    let harness = production_harness("kill-all-heavy");
    let frame = "i=0; while :; do i=$((i+1)); printf '\\033[?2026h\\033[H'; j=0; \
                 while [ $j -lt 40 ]; do printf 'row %02d frame %08d build step output text\\033[K\\r\\n' $j $i; \
                 j=$((j+1)); done; printf '\\033[?2026l'; sleep 0.016; done";
    for index in 0..PANES {
        request(
            &harness.socket,
            serde_json::json!({
                "id":index,"cmd":"run","argv":["/bin/sh","-c",frame],
                "new_workspace":true,"cols":120,"rows":40,
            }),
        );
    }
    wait_for_host_records(&harness.host_root(), PANES);
    std::thread::sleep(Duration::from_secs(3));
    let pid = harness.child.as_ref().unwrap().id();
    let before = logical_writes(pid);
    let started = Instant::now();
    std::thread::sleep(window);
    let after = logical_writes(pid);
    let seconds = started.elapsed().as_secs_f64();
    let folder = walk_files(&harness.state)
        .iter()
        .filter_map(|path| fs::metadata(path).ok())
        .map(|metadata| metadata.len())
        .sum::<u64>();
    let written = before.zip(after).map(|(before, after)| after.saturating_sub(before));
    eprintln!(
        "kill-all-heavy: {}",
        serde_json::json!({
            "panes": PANES,
            "seconds": seconds,
            "daemon_logical_write_bytes": written,
            "bytes_per_pane_per_second": written.map(|bytes| bytes as f64 / PANES as f64 / seconds),
            "state_folder_bytes": folder,
        })
    );
}

/// The tail file of `harness`'s only terminal: its size, 0 when absent.
fn tail_file_bytes(harness: &RecoveryHarness) -> u64 {
    walk_files(&harness.state)
        .into_iter()
        .filter(|path| path.extension().is_some_and(|extension| extension == "tail"))
        .filter_map(|path| fs::metadata(path).ok())
        .map(|metadata| metadata.len())
        .sum()
}

/// A screen that cannot be replayed (an unterminated Kitty upload larger
/// than the snapshot's replay budget) must not stop the tail: when the
/// tail asks for its compaction and the snapshot fails, its bytes still go
/// to the tail (review of #31643 at 77a38ad8a31: the pass skipped the tail
/// and kept every later byte in memory, unbounded).
#[test]
fn an_unreplayable_screen_does_not_stop_the_tail() {
    let _exclusive = exclusive_process_test();
    let harness = production_harness("unreplayable-tail");
    let home = harness.dir.clone();
    let (_terminal_id, _incarnation, surface) = start_shell_in(&harness, "unreplayable", &home);
    send_line(&harness.socket, surface, "printf 'before-upload\\n'");
    wait_for_screen(&harness.socket, surface, "before-upload\n");
    std::thread::sleep(Duration::from_secs(1));
    // An upload that never ends: every later byte is inside it, and the
    // replay cannot hold it. Over 1 MiB: the tail asks for its snapshot.
    send_line(
        &harness.socket,
        surface,
        "printf '\\033_Ga=t,f=100,m=1;'; head -c 1500000 /dev/urandom | base64 | tr -d '\\n'",
    );
    std::thread::sleep(Duration::from_secs(2));
    let before = tail_file_bytes(&harness);
    send_line(&harness.socket, surface, "head -c 1500000 /dev/urandom | base64 | tr -d '\\n'");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let now = tail_file_bytes(&harness);
        if now > before + 1_000_000 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the tail stopped at {before} bytes ({now} now) once its snapshot could not be taken"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Failure-mode table, "resize storm": a terminal whose size changes every
/// 100 ms (a divider drag) is not snapshotted on every pass; its snapshot
/// waits until the size settles.
#[test]
fn a_resize_storm_writes_one_snapshot_after_the_size_settles() {
    let _exclusive = exclusive_process_test();
    let harness = production_harness("resize-storm");
    let home = harness.dir.clone();
    let (_terminal_id, _incarnation, surface) = start_shell_in(&harness, "storm", &home);
    // A program that prints nothing on a resize (a shell such as bash
    // redraws its prompt on SIGWINCH, dash does not): the resize alone must
    // bring the snapshot at the new size.
    send_line(&harness.socket, surface, "printf 'storm-ready\\n'; exec cat");
    wait_for_screen(&harness.socket, surface, "storm-ready\n");
    std::thread::sleep(Duration::from_secs(1));
    let snapshot = || {
        walk_files(&harness.state)
            .into_iter()
            .find(|path| path.extension().is_some_and(|extension| extension == "snap"))
            .and_then(|path| fs::metadata(path).ok()?.modified().ok())
    };
    let mut writes = 0;
    let mut last = snapshot();
    for step in 0..20_u16 {
        request(
            &harness.socket,
            serde_json::json!({"id": 100 + u64::from(step), "cmd": "resize-surface", "surface": surface,
                               "cols": 80 + step, "rows": 30}),
        );
        std::thread::sleep(Duration::from_millis(100));
        let now = snapshot();
        if now != last {
            writes += 1;
            last = now;
        }
    }
    assert!(writes <= 2, "{writes} snapshots during a 2 s resize storm");
    // The terminal is idle now: its snapshot at the last size still comes,
    // once the size has held (review round 5 of #31643: an idle terminal's
    // snapshot was never asked for again).
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    loop {
        let cols = walk_files(&harness.state)
            .into_iter()
            .find(|path| path.extension().is_some_and(|extension| extension == "snap"))
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| {
                let rest = bytes.strip_prefix(b"CMUXSNAP1\n")?;
                let line = rest.split(|byte| *byte == b'\n').next()?;
                serde_json::from_slice::<serde_json::Value>(line).ok()?["cols"].as_u64()
            });
        if cols == Some(99) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "no snapshot at the settled size (99 columns) after the storm: {cols:?}"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// A host reconnect inside a running daemon (its admin tap overflowed while
/// the daemon was stopped) replaces the daemon's screen with the host's:
/// bytes the host wrote meanwhile never went through the output store. A kill
/// of everything right after the reconnect must still restore them (the
/// tail must not continue across that gap; review of #31643: the reconnect
/// did not tell the output store, so the restore lacked the gap's output
/// until the next coalesced checkpoint, up to 30 s).
#[test]
fn kill_all_right_after_a_host_reconnect_restores_the_output_of_the_gap() {
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("kill-all-reconnect-gap");
    let home = harness.dir.clone();
    let (terminal_id, incarnation, surface) = start_shell_in(&harness, "gap", &home);
    let trigger = harness.dir.join("flood");
    send_line(&harness.socket, surface, "printf 'gap-%s\\n' before");
    wait_for_screen(&harness.socket, surface, "gap-before\n");
    // Over the host's 8 MiB queued-output budget for the daemon's tap: the
    // host closes the tap while the daemon is stopped, and the daemon
    // reconnects from the host's snapshot.
    send_line(
        &harness.socket,
        surface,
        &format!(
            "while [ ! -e '{}' ]; do sleep 0.05; done; head -c 12000000 /dev/zero; printf 'gap-%s\\n' during",
            trigger.display()
        ),
    );
    std::thread::sleep(Duration::from_secs(2));
    harness.signal_daemon(libc::SIGSTOP);
    fs::write(&trigger, b"").unwrap();
    std::thread::sleep(Duration::from_secs(4));
    harness.signal_daemon(libc::SIGCONT);
    let shown = wait_for_screen(&harness.socket, surface, "gap-during\n");
    assert!(shown.contains("gap-during"), "the reconnect never showed the gap's output: {shown}");
    // Well inside the checkpoint interval, after one writer pass.
    std::thread::sleep(Duration::from_millis(800));

    kill_everything_and_restart(&mut harness);
    let surface = respawned_surface(&harness, &terminal_id, &incarnation);
    let restored = wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
    assert!(
        restored.contains("gap-during"),
        "the output written while the daemon had no tap is not restored: {restored}"
    );
}

/// Measurement, not a check (ignored: `cargo test --test terminal_host_recovery
/// kill_all_restore_time_of_12_terminals -- --ignored --nocapture`): the time
/// from the new daemon's spawn to each respawned terminal's restored text,
/// for 12 terminals killed at once, each with about 600 KB of output in its
/// tail (a restore rebuilds snapshot plus tail per terminal). Prints
/// `kill-all-restore-time: {...}` (ms per terminal, sorted).
#[test]
#[ignore = "measurement: run it with --ignored"]
fn kill_all_restore_time_of_12_terminals() {
    const TERMINALS: usize = 12;
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("kill-all-restore-time");
    let home = harness.dir.clone();
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let (terminal_id, incarnation, surface) =
            start_shell_in(&harness, &format!("time{index}"), &home);
        terminals.push((terminal_id, incarnation, surface));
    }
    // The first snapshot of each (a new generation) is written first; the
    // output after it is in the tail.
    std::thread::sleep(Duration::from_secs(1));
    for (index, (_, _, surface)) in terminals.iter().enumerate() {
        send_line(&harness.socket, *surface, &format!("seq -f 't{index}-%g' 1 90000"));
    }
    for (index, (_, _, surface)) in terminals.iter().enumerate() {
        wait_for_screen(&harness.socket, *surface, &format!("t{index}-90000\n"));
    }
    std::thread::sleep(Duration::from_secs(1));
    let records = wait_for_host_records(&harness.host_root(), TERMINALS);
    harness.signal_daemon(libc::SIGSTOP);
    for (record_path, record) in &records {
        kill_shell_then_host(record_path, record);
    }
    harness.sigkill();
    let spawned = Instant::now();
    harness.restart();
    let mut restored_ms = Vec::new();
    for (index, (terminal_id, incarnation, _)) in terminals.iter().enumerate() {
        let surface = respawned_surface(&harness, terminal_id, incarnation);
        let screen = wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
        assert!(screen.contains(&format!("t{index}-90000")), "terminal {index} lost its text");
        restored_ms.push(spawned.elapsed().as_millis());
    }
    restored_ms.sort_unstable();
    eprintln!(
        "kill-all-restore-time: {}",
        serde_json::json!({"terminals": TERMINALS, "restored_ms": restored_ms})
    );
}

/// Chrome's rule after a kill of everything: the terminals the person sees
/// are restored first, and the respawns of hidden ones do not compete with
/// them. A respawn replays a multi-MB seed twice (daemon mirror and host);
/// all of them used to start at once, so the visible terminals waited behind
/// the hidden ones for the CPU (STATUS 5931: 34-370 ms for 24 terminals).
///
/// 24 shells in 24 workspaces, the middle one selected, a kill of the
/// daemon and every host, then a restart with each respawn held 1 s inside
/// its turn (the existing CMUX_TUI_TEST_RESPAWN_DELAY_MS seam) and 4 slots:
/// the visible terminal is in the first wave, and no wave has more than 4.
#[test]
fn a_kill_all_respawns_the_visible_workspace_first_in_bounded_waves() {
    const TERMINALS: usize = 24;
    const SLOTS: usize = 4;
    const HOLD_MS: u64 = 1_000;
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("respawn-order");
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 100 + index, "cmd": "run", "argv": ["/bin/cat"],
                "new_workspace": true, "name": format!("order-{index}")}),
        );
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    let records = wait_for_host_records(&harness.host_root(), TERMINALS);
    let visible_index = TERMINALS / 2;
    request(
        &harness.socket,
        serde_json::json!({"id": 300, "cmd": "select-workspace", "index": visible_index}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 301, "cmd": "list-workspaces"}));
    let visible_name = tree["workspaces"][visible_index]["name"].as_str().unwrap().to_string();
    let visible =
        terminals[visible_name.trim_start_matches("order-").parse::<usize>().unwrap()].clone();
    // The selection reaches the registry before the kill.
    std::thread::sleep(Duration::from_millis(500));

    harness.signal_daemon(libc::SIGSTOP);
    for (record_path, record) in &records {
        kill_shell_then_host(record_path, record);
    }
    harness.sigkill();
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_DELAY_MS".into(), HOLD_MS.to_string()));
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_SLOTS".into(), SLOTS.to_string()));
    harness.restart();

    // When each terminal respawned, from the loss log (one line per respawn).
    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    let respawned_at = loop {
        let at = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|event| event["event"] == "terminal_respawned")
            .filter_map(|event| {
                Some((event["terminal_id"].as_str()?.to_string(), event["at_ms"].as_u64()?))
            })
            .collect::<std::collections::HashMap<_, _>>();
        if terminals.iter().all(|terminal| at.contains_key(terminal)) {
            break at;
        }
        assert!(Instant::now() < deadline, "only {} of {TERMINALS} terminals respawned", at.len());
        std::thread::sleep(Duration::from_millis(100));
    };
    let first = respawned_at.values().copied().min().unwrap();
    let first_wave = respawned_at
        .iter()
        .filter(|(_, at)| **at < first + HOLD_MS / 2)
        .map(|(terminal, _)| terminal.clone())
        .collect::<Vec<_>>();
    assert!(
        first_wave.contains(&visible),
        "the visible workspace's terminal was not in the first wave ({} of {TERMINALS})",
        first_wave.len()
    );
    assert!(
        first_wave.len() <= SLOTS,
        "{} terminals respawned at once; the gate allows {SLOTS}",
        first_wave.len()
    );
}

/// A workspace the person selects while the respawns of a kill of everything
/// still wait in line is the one they now see: its terminal goes first, not
/// after the waves ahead of it, as the start's adoption gate already does for
/// a terminal a request waits on.
///
/// 8 shells in 8 workspaces, the middle one selected, a kill of everything,
/// then a restart with 1 slot and each respawn held 1 s in its turn: the
/// visible terminal holds the only slot. Another workspace is selected at
/// once; its terminal waits only for that turn (a turn of a shown terminal,
/// which the slot bounds), so it respawns about two holds after the
/// selection (the slot's current hold, then its own; under 4 here, for slow
/// runners), not after the 7 waves ahead of it.
#[test]
fn a_workspace_selected_during_the_respawn_waves_respawns_without_waiting_a_wave() {
    const TERMINALS: usize = 8;
    const HOLD_MS: u64 = 1_000;
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("respawn-jump");
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 100 + index, "cmd": "run", "argv": ["/bin/cat"],
                "new_workspace": true, "name": format!("jump-{index}")}),
        );
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    let records = wait_for_host_records(&harness.host_root(), TERMINALS);
    let visible_index = TERMINALS / 2;
    request(
        &harness.socket,
        serde_json::json!({"id": 300, "cmd": "select-workspace", "index": visible_index}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 301, "cmd": "list-workspaces"}));
    let terminal_at = |index: usize| {
        let name = tree["workspaces"][index]["name"].as_str().unwrap();
        terminals[name.trim_start_matches("jump-").parse::<usize>().unwrap()].clone()
    };
    let target_index = 0;
    let target = terminal_at(target_index);
    assert_ne!(target, terminal_at(visible_index));
    std::thread::sleep(Duration::from_millis(500));

    harness.signal_daemon(libc::SIGSTOP);
    for (record_path, record) in &records {
        kill_shell_then_host(record_path, record);
    }
    harness.sigkill();
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_DELAY_MS".into(), HOLD_MS.to_string()));
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_SLOTS".into(), "1".into()));
    harness.restart();
    let selected = request(
        &harness.socket,
        serde_json::json!({"id": 302, "cmd": "select-workspace", "index": target_index}),
    );
    let selected_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;

    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    let respawned_ms = loop {
        let at = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|event| event["event"] == "terminal_respawned")
            .find(|event| event["terminal_id"] == target.as_str())
            .and_then(|event| event["at_ms"].as_u64());
        if let Some(at) = at {
            break at;
        }
        assert!(Instant::now() < deadline, "the selected terminal never respawned: {selected}");
        std::thread::sleep(Duration::from_millis(50));
    };
    let waited = respawned_ms.saturating_sub(selected_ms);
    assert!(
        waited < 4 * HOLD_MS,
        "the selected workspace's terminal respawned {waited} ms after its selection; \
         one hold is {HOLD_MS} ms, so it waited for more than the next slot"
    );
}

/// A terminal of the workspace the person sees that dies while hidden
/// respawns still wait in line takes its ticket while shown: it must still
/// go first, not after the hidden ones (review of #32288).
///
/// 8 shells in 8 workspaces, the target's selected. Every host but the
/// target's is killed with the daemon; the restart adopts the target and
/// queues 7 hidden respawns behind 1 slot, each held 1 s. Then the target's
/// host is killed: its respawn does not wait for the hidden queue or for
/// the hidden turn that holds the slot, so it comes about one hold later
/// (its own; the bound is 4 here, for slow runners).
#[test]
fn a_shown_terminal_lost_behind_a_respawn_backlog_respawns_without_waiting_for_it() {
    const TERMINALS: usize = 8;
    const HOLD_MS: u64 = 1_000;
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("respawn-backlog");
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 100 + index, "cmd": "run", "argv": ["/bin/cat"],
                "new_workspace": true, "name": format!("backlog-{index}")}),
        );
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    let records = wait_for_host_records(&harness.host_root(), TERMINALS);
    let target_index = TERMINALS / 2;
    request(
        &harness.socket,
        serde_json::json!({"id": 300, "cmd": "select-workspace", "index": target_index}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 301, "cmd": "list-workspaces"}));
    let target_name = tree["workspaces"][target_index]["name"].as_str().unwrap().to_string();
    let target =
        terminals[target_name.trim_start_matches("backlog-").parse::<usize>().unwrap()].clone();
    std::thread::sleep(Duration::from_millis(500));

    harness.signal_daemon(libc::SIGSTOP);
    let mut target_record = None;
    for (record_path, record) in &records {
        if record.terminal_id == target {
            target_record = Some((record_path.clone(), record.clone()));
        } else {
            kill_shell_then_host(record_path, record);
        }
    }
    let (target_path, target_host) = target_record.expect("the target has a host record");
    harness.sigkill();
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_DELAY_MS".into(), HOLD_MS.to_string()));
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_SLOTS".into(), "1".into()));
    harness.restart();
    // The target's surviving host is adopted: it runs again.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":target}),
        );
        if resolved["surface"].as_u64().is_some() && resolved["lifecycle"] == "running" {
            break;
        }
        assert!(Instant::now() < deadline, "the target was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
    let killed_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;
    kill_shell_then_host(&target_path, &target_host);

    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    let respawned_ms = loop {
        let at = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|event| event["event"] == "terminal_respawned")
            .find(|event| event["terminal_id"] == target.as_str())
            .and_then(|event| event["at_ms"].as_u64());
        if let Some(at) = at {
            break at;
        }
        assert!(Instant::now() < deadline, "the shown terminal never respawned");
        std::thread::sleep(Duration::from_millis(50));
    };
    let waited = respawned_ms.saturating_sub(killed_ms);
    assert!(
        waited < 4 * HOLD_MS,
        "the shown terminal respawned {waited} ms after its host died; one hold is \
         {HOLD_MS} ms, so it waited behind the hidden respawns, not for the next slot"
    );
}

/// A case of the quit-then-reboot matrix: a terminal's name, the commands
/// typed into it (each waits for its marker on the screen) and whether the
/// terminal is resized between them.
struct QuitCase {
    name: &'static str,
    steps: &'static [(&'static str, &'static str)],
    resize_before_last: bool,
}

const QUIT_CASES: &[QuitCase] = &[
    // Output after the generation's first snapshot: at quit only the tail
    // holds it (the 30 s interval has not passed).
    QuitCase {
        name: "tail",
        steps: &[("seq -f 'tail-line-%g' 1 400; printf 'tail-%s\\n' done", "tail-done\n")],
        resize_before_last: false,
    },
    // A full-screen program on the alternate screen at quit.
    QuitCase {
        name: "alt",
        steps: &[
            ("seq -f 'alt-before-%g' 1 60; printf 'alt-%s\\n' before", "alt-before\n"),
            (
                "printf '\\033[?1049h\\033[2J\\033[H'; seq -f 'alt-line-%g' 1 20; \
                 printf 'alt-%s\\n' shown; read x",
                // The last row of the alternate screen: no line feed after it
                // (`read x` waits on that row).
                "alt-shown",
            ),
        ],
        resize_before_last: false,
    },
    // A terminal at a new size: the tail cannot carry it, the quit writes a
    // snapshot.
    QuitCase {
        name: "resized",
        steps: &[
            ("seq -f 'size-line-%g' 1 100; printf 'size-%s\\n' one", "size-one\n"),
            ("seq -f 'resized-line-%g' 1 50; printf 'size-%s\\n' two", "size-two\n"),
        ],
        resize_before_last: true,
    },
    // The primary screen with the states a replay restores: a title, bracketed
    // paste and mouse modes on, a saved cursor and a scroll region.
    QuitCase {
        name: "modes",
        steps: &[(
            "printf '\\033]0;quit-title\\007\\033[?2004h\\033[?1000h\\0337\\033[5;20r'; \
             seq -f 'modes-line-%g' 1 40; printf '\\0338modes-%s' done",
            "modes-done",
        )],
        resize_before_last: false,
    },
    // About 18 MB: past the tail's cap (1 MiB), its flood cap (16 MiB) and
    // what one terminal keeps unwritten (8 MiB).
    QuitCase {
        name: "flood",
        steps: &[(
            "seq -f 'flood-%09g-abcdefghijklmnopqrstuvwxyzabcdefghij' 1 300000; \
             printf 'flood-%s\\n' done",
            "flood-done\n",
        )],
        resize_before_last: false,
    },
];

/// One terminal of the matrix: its case, its transcript at quit, and the
/// lines each reader restored, in reader order.
struct MatrixRow {
    case: &'static str,
    at_quit: Vec<String>,
    restored: Vec<Vec<String>>,
}

/// Copy the regular files and folders below `from` to `to`.
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            copy_tree(&entry.path(), &target);
        } else if kind.is_file() {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// The restored part of a respawned transcript: the lines above the
/// session line.
fn restored_lines(after: &[String]) -> Vec<String> {
    let end = after.iter().position(|line| line.contains(RESPAWN_MARKER)).unwrap_or(after.len());
    after[..end].to_vec()
}

/// Stop the daemon and kill every terminal host it runs (a reboot).
fn reboot(harness: &mut RecoveryHarness, hosts: usize) {
    let records = wait_for_host_records(&harness.host_root(), hosts);
    harness.signal_daemon(libc::SIGSTOP);
    for (record_path, record) in &records {
        kill_shell_then_host(record_path, record);
    }
    harness.sigkill();
}

/// `writer` (None: this build) runs [`QUIT_CASES`], stops on SIGTERM (an
/// update or a logout) and the shells and hosts die (a reboot). Then each
/// build of `readers` starts on the same stored bytes (the state folder is
/// copied back between them) and gives each terminal's restored transcript.
/// Returns (case, the writer's transcript at quit, each reader's restored
/// lines).
fn quit_then_reboot_matrix(
    name: &str,
    writer: Option<PathBuf>,
    readers: &[Option<PathBuf>],
) -> Vec<MatrixRow> {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.extra_env.push(("CMUX_TUI_TERMINAL_PERSISTENCE".into(), "snapshot".into()));
    eprintln!("QUIT-MATRIX start writer {writer:?}");
    harness.binary = writer;
    harness.restart();
    let home = harness.dir.clone();
    let mut terminals = Vec::new();
    for case in QUIT_CASES {
        let (terminal_id, incarnation, surface) = start_shell_in(&harness, case.name, &home);
        for (index, (line, marker)) in case.steps.iter().enumerate() {
            if case.resize_before_last && index + 1 == case.steps.len() {
                request(
                    &harness.socket,
                    serde_json::json!({"cmd":"resize-surface","surface":surface,"cols":90,"rows":30}),
                );
                std::thread::sleep(Duration::from_millis(500));
            }
            send_line(&harness.socket, surface, line);
            let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
            loop {
                let screen = request(
                    &harness.socket,
                    serde_json::json!({"cmd":"read-screen","surface":surface}),
                )["text"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string();
                if screen.contains(marker) {
                    break;
                }
                assert!(Instant::now() < deadline, "{}: no {marker:?}: {screen}", case.name);
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        terminals.push((case.name, terminal_id, incarnation, surface));
    }
    // Far less than the 30 s snapshot interval; past the tail's flush.
    std::thread::sleep(Duration::from_secs(2));
    let before = terminals
        .iter()
        .map(|(_, _, _, surface)| transcript(&harness, *surface))
        .collect::<Vec<_>>();
    let records = wait_for_host_records(&harness.host_root(), terminals.len());
    harness.terminate();
    for (record_path, record) in &records {
        kill_shell_then_host(record_path, record);
    }
    let saved = harness.dir.join("state-at-quit");
    copy_tree(&harness.state, &saved);

    let mut restored = vec![Vec::new(); terminals.len()];
    for (round, reader) in readers.iter().enumerate() {
        if round > 0 {
            reboot(&mut harness, terminals.len());
            fs::remove_dir_all(&harness.state).unwrap();
            copy_tree(&saved, &harness.state);
        }
        eprintln!("QUIT-MATRIX start reader {round} {reader:?}");
        harness.binary = reader.clone();
        harness.restart();
        for (index, (_, terminal_id, incarnation, _)) in terminals.iter().enumerate() {
            let surface = respawned_surface(&harness, terminal_id, incarnation);
            wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
            restored[index].push(restored_lines(&transcript(&harness, surface)));
        }
    }
    reboot(&mut harness, terminals.len());
    terminals
        .iter()
        .zip(before)
        .zip(restored)
        .map(|((&(case, _, _, _), at_quit), restored)| MatrixRow { case, at_quit, restored })
        .collect()
}

/// Lines and bytes of `expected` that `actual` lacks or changed.
fn lost(expected: &[String], actual: &[String]) -> (usize, usize) {
    let lines = expected.iter().zip(actual).filter(|(e, a)| e != a).count()
        + expected.len().saturating_sub(actual.len());
    let bytes = |lines: &[String]| lines.iter().map(|line| line.len() + 1).sum::<usize>();
    (lines, bytes(expected).saturating_sub(bytes(actual)))
}

/// Assert that every reader restored the same text as the first one, and
/// print one row per case: the reader, then same or lost lines/bytes.
fn assert_readers_agree(direction: &str, labels: &[&str], rows: &[MatrixRow]) {
    let mut differences = Vec::new();
    for MatrixRow { case, at_quit, restored } in rows {
        let reference = &restored[0];
        for (label, lines) in labels.iter().zip(restored) {
            let (lines_lost, bytes_lost) = lost(reference, lines);
            let (vs_quit_lines, _) = lost(at_quit, lines);
            let verdict = if lines == reference {
                "same".to_string()
            } else {
                format!("lost {lines_lost} lines / {bytes_lost} bytes")
            };
            eprintln!(
                "QUIT-MATRIX {direction} case={case} reader={label} lines={} {verdict} \
                 (vs the screen at quit: {vs_quit_lines} lines differ)",
                lines.len()
            );
            if lines != reference {
                differences.push(format!("{case} {label}: {verdict}"));
            }
        }
    }
    assert!(
        differences.is_empty(),
        "{direction}: the readers restored different text: {differences:?}"
    );
}

fn previous_build() -> PathBuf {
    let previous = PathBuf::from(
        std::env::var("CMUX_TUI_PREVIOUS_BIN").expect("CMUX_TUI_PREVIOUS_BIN is required"),
    );
    assert_ne!(
        fs::canonicalize(&previous).unwrap(),
        fs::canonicalize(bin()).unwrap(),
        "the previous build must be a different binary"
    );
    previous
}

/// An update rolled back after a reboot: this build quits, and the earlier
/// build restores exactly what this build would.
#[test]
#[ignore = "needs CMUX_TUI_PREVIOUS_BIN, a cmux-tui binary from an earlier build"]
fn a_previous_build_restores_what_this_build_stores_at_quit() {
    let _exclusive = exclusive_process_test();
    let rows =
        quit_then_reboot_matrix("quit-matrix-rollback", None, &[None, Some(previous_build())]);
    assert_readers_agree("this-quits", &["this", "previous"], &rows);
}

/// An update after a reboot: the earlier build quits, and this build restores
/// exactly what the earlier build would.
#[test]
#[ignore = "needs CMUX_TUI_PREVIOUS_BIN, a cmux-tui binary from an earlier build"]
fn this_build_restores_what_a_previous_build_stores_at_quit() {
    let _exclusive = exclusive_process_test();
    let previous = previous_build();
    let rows = quit_then_reboot_matrix(
        "quit-matrix-update",
        Some(previous.clone()),
        &[Some(previous), None],
    );
    assert_readers_agree("previous-quits", &["previous", "this"], &rows);
}
