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
    send_line(&harness.socket, surface, "seq -f 'f3-line-%g' 1 400");
    send_line(&harness.socket, surface, "printf 'f3-%s\\n' done");
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

/// The last directory line the shell's probe printed.
fn read_cwd(socket: &Path, surface: u64) -> String {
    let screen = wait_for_screen(socket, surface, "f3-cwd=/");
    screen
        .lines()
        .rev()
        .find(|line| line.starts_with("f3-cwd=/"))
        .map(|line| line.trim_end().to_string())
        .unwrap_or_else(|| panic!("the shell printed no directory: {screen}"))
}

/// The respawned shell keeps the directory as the path string it was given:
/// a directory reached through a symlink is not shown as its real path.
#[test]
fn kill_all_respawned_shell_keeps_its_directory_path_string() {
    let _exclusive = exclusive_process_test();
    let mut harness = production_harness("kill-all-cwd");
    let (real, link) = symlinked_directory(&harness);
    let (terminal_id, incarnation, surface) = start_shell_in(&harness, "cwd", &link);
    let probe = "printf 'f3-cwd=%s\\n' \"$PWD\"";
    let wanted = format!("f3-cwd={}", link.display());
    send_line(&harness.socket, surface, probe);
    assert_eq!(
        read_cwd(&harness.socket, surface),
        wanted,
        "the shell started in {} reports its real path {}",
        link.display(),
        real.display()
    );

    kill_everything_and_restart(&mut harness);
    let surface = respawned_surface(&harness, &terminal_id, &incarnation);
    wait_for_screen(&harness.socket, surface, RESPAWN_MARKER);
    // The restored screen holds the old probe's line: clear it first.
    send_line(&harness.socket, surface, "clear");
    std::thread::sleep(Duration::from_millis(300));
    send_line(&harness.socket, surface, probe);
    assert_eq!(
        read_cwd(&harness.socket, surface),
        wanted,
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

/// Measurement, not a check (it runs only with `CMUX_KILL_ALL_HEAVY_SECS`
/// set, the window in seconds): the daemon's disk writes
/// under the HEAVY load of the reopen films, 12 panes of a full-screen TUI
/// that repaints 40 rows with new content at about 60 Hz. Prints
/// `kill-all-heavy: {...}` with the logical write bytes per pane per second
/// and the state folder size. Run it at the base and at the fix for the
/// before/after.
#[test]
fn kill_all_heavy_load_disk_writes_per_pane() {
    const PANES: usize = 12;
    let Some(window) = std::env::var("CMUX_KILL_ALL_HEAVY_SECS")
        .ok()
        .and_then(|value| value.parse().ok())
        .map(Duration::from_secs)
    else {
        return;
    };
    let _exclusive = exclusive_process_test();
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
