//! KEPT RESTORE: after End Sessions, Keep Layout (an app relaunch, an update
//! in place) a frontend restarts every kept tab at its next connect
//! (`restart-tab`, `tab-restart-kept-layout-v1`). Every kept terminal must be
//! alive again with no action by the person.
//!
//! With a session of the person's size (170 kept agent terminals) the
//! restarts all started in the same 30 ms, each on its own thread. macOS then
//! refused some PTY master opens for a moment (far below
//! `kern.tty.ptmx_max`), the daemon recorded `restart_failed` and never tried
//! again: 8 to 16 of 170 terminals stayed dead until the person used Restart
//! Shell Here on each one.

use super::*;

/// The kept tabs of the count tests: 20, or `CMUX_TUI_TEST_KEPT_TABS` (170 is
/// the person's session).
fn kept_tab_count() -> usize {
    std::env::var("CMUX_TUI_TEST_KEPT_TABS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|count| *count > 0)
        .unwrap_or(20)
}

fn all_tabs(harness: &RecoveryHarness) -> Vec<serde_json::Value> {
    let tree = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .cloned()
        .collect()
}

/// `count` terminals, each in its own workspace `<prefix>-<index>`. Returns
/// the terminal ids in creation order.
fn create_workspaces(harness: &RecoveryHarness, prefix: &str, count: usize) -> Vec<String> {
    (0..count)
        .map(|index| {
            run_cat_workspace(&harness.socket, 100 + index, &format!("{prefix}-{index}")).0
        })
        .collect()
}

/// End Sessions, Keep Layout. The daemon and every terminal host are gone
/// when this returns.
fn end_sessions_keep_layout(harness: &mut RecoveryHarness) {
    let identify = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "identify"}));
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "end_terminals": true,
            "keep_layout": true,
        }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after shutdown");
        std::thread::sleep(Duration::from_millis(10));
    }
    let root = harness.host_root();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    while !(load_terminal_host_records(&root).unwrap().is_empty()
        && load_terminal_host_exit_records(&root).unwrap().is_empty())
    {
        assert!(Instant::now() < deadline, "End Sessions left terminal host records");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// What the app does at its connect (`relaunchKeptTabs`): one `restart-tab`
/// per kept tab, 8 in flight. Every request must be accepted.
fn restart_kept_tabs(harness: &RecoveryHarness, kept: &[serde_json::Value]) {
    const IN_FLIGHT: usize = 8;
    let next = AtomicUsize::new(0);
    let socket = harness.socket.as_path();
    std::thread::scope(|scope| {
        for _ in 0..IN_FLIGHT {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::AcqRel);
                    let Some(tab) = kept.get(index) else { break };
                    let surface = tab["tab_resource_id"].clone();
                    let restarted = request_response(
                        socket,
                        serde_json::json!({"id": 1, "cmd": "restart-tab", "surface": surface}),
                    );
                    assert_eq!(restarted["ok"], true, "restart-tab was refused: {restarted}");
                }
            });
        }
    });
}

/// N kept tabs, and K of the N launches fail one time for a cause that can
/// pass (what a refused PTY master open is): N terminals are alive at the
/// end, counted from the daemon, with one `restart-tab` per tab and nothing
/// else. The K terminals stayed dead (`restart_failed`).
#[test]
fn every_kept_terminal_is_alive_after_a_restore_whose_launches_failed_one_time() {
    let _exclusive = exclusive_process_test();
    let count = kept_tab_count();
    let failures = (count / 10).max(2);
    let mut harness = RecoveryHarness::start("kept-restore-count");
    create_workspaces(&harness, "kept", count);
    end_sessions_keep_layout(&mut harness);
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_LAUNCH_ERRORS".into(), failures.to_string()));
    harness.restart();
    let kept = all_tabs(&harness);
    assert_eq!(kept.len(), count, "the restart did not keep every tab");
    for tab in &kept {
        assert_eq!(tab["dead"], true, "a kept tab came back live: {tab}");
        assert!(tab["relaunch"].is_object(), "a kept tab has no relaunch record: {tab}");
    }

    restart_kept_tabs(&harness, &kept);

    // The daemon tries a failed launch again by itself (the supervisor's
    // schedule: at once, then after 2 s, 10 s, 30 s and 60 s); one failure
    // per terminal needs the first of them.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    loop {
        let tabs = all_tabs(&harness);
        let alive = tabs
            .iter()
            .filter(|tab| tab["dead"] == false && tab["terminal_state"] == "running")
            .count();
        if alive == count {
            assert_eq!(tabs.len(), count, "a restart added or removed a tab");
            break;
        }
        if Instant::now() >= deadline {
            let dead = tabs.iter().filter(|tab| tab["dead"] == true).collect::<Vec<_>>();
            panic!(
                "{alive} of {count} kept terminals are alive after {failures} launches failed \
                 one time; {} stay dead, the first: {}",
                dead.len(),
                dead.first().map(|tab| tab["end"].to_string()).unwrap_or_default()
            );
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    // Each restarted tab is an ordinary terminal tab again.
    for tab in all_tabs(&harness) {
        assert!(tab["relaunch"].is_null(), "a restarted tab stays kept: {tab}");
    }
}

/// The restarts of a restore take turns: at most one per respawn slot at a
/// time, and the terminal of the workspace the person sees goes first. They
/// all started at once, so the person's terminal competed with every hidden
/// one for the CPU and the PTY opens.
///
/// 12 kept tabs in 12 workspaces, the middle one selected, a restart with 2
/// slots and each launch held 1 s in its turn: the first wave has at most 2
/// terminals and the selected workspace's is one of them.
#[test]
fn the_restarts_of_a_restore_take_turns_and_the_shown_workspace_goes_first() {
    const TABS: usize = 12;
    const SLOTS: usize = 2;
    const HOLD_MS: u64 = 1_000;
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("kept-restore-turns");
    let shown_index = TABS / 2;
    let terminals = create_workspaces(&harness, "turn", TABS);
    request(
        &harness.socket,
        serde_json::json!({"id": 300, "cmd": "select-workspace", "index": shown_index}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 301, "cmd": "list-workspaces"}));
    let shown_name = tree["workspaces"][shown_index]["name"].as_str().unwrap().to_string();
    let shown = terminals[shown_name.trim_start_matches("turn-").parse::<usize>().unwrap()].clone();
    // The selection reaches the registry before the handoff.
    std::thread::sleep(Duration::from_millis(500));
    end_sessions_keep_layout(&mut harness);

    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_DELAY_MS".into(), HOLD_MS.to_string()));
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_SLOTS".into(), SLOTS.to_string()));
    harness.restart();
    let tree = request(&harness.socket, serde_json::json!({"id": 302, "cmd": "list-workspaces"}));
    assert_eq!(
        tree["workspaces"][shown_index]["active"], true,
        "the restart did not keep the selected workspace: {tree}"
    );
    let kept = all_tabs(&harness);
    assert_eq!(kept.len(), TABS, "the restart did not keep every tab");
    restart_kept_tabs(&harness, &kept);

    // When each terminal restarted, from the loss log (one line per restart).
    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    let restarted_at = loop {
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
        assert!(Instant::now() < deadline, "only {} of {TABS} terminals restarted", at.len());
        std::thread::sleep(Duration::from_millis(100));
    };
    let first = restarted_at.values().copied().min().unwrap();
    let first_wave = restarted_at
        .iter()
        .filter(|(_, at)| **at < first + HOLD_MS / 2)
        .map(|(terminal, _)| terminal.clone())
        .collect::<Vec<_>>();
    assert!(
        first_wave.len() <= SLOTS,
        "{} of {TABS} kept terminals restarted at the same moment; the respawn gate allows {SLOTS}",
        first_wave.len()
    );
    // The app asks in tree order, so the first slots may be taken when the
    // shown tab's request arrives: it takes the next free slot, before the
    // hidden ones in line (wave 1 or 2 of 6).
    let mut order = restarted_at.iter().collect::<Vec<_>>();
    order.sort_by_key(|(_, at)| **at);
    let place = order.iter().position(|(terminal, _)| **terminal == shown).unwrap();
    assert!(
        place < 2 * SLOTS,
        "the shown workspace's terminal restarted as number {} of {TABS}: it waited behind \
         hidden terminals, not for the next free slot",
        place + 1
    );
}

/// A restarted terminal that has a command for its new prompt (the resume
/// command a person set, or its agent's resume) waits for that prompt, up to
/// 10 s, then for the prompt to settle. That wait ran inside the terminal's
/// turn in the respawn gate, so the next terminal in line started only when
/// the prompt of the one before had come: the agent terminals of a restored
/// session came back a few at a time (14 to 17 of 170 alive after 5 s, all of
/// them only after 2 minutes).
///
/// 3 kept tabs, each with a resume command, a shell that writes for 12 s and
/// shows no prompt (the longest wait), and 1 slot: the 3 terminals restart
/// with no prompt wait between them.
#[test]
fn the_wait_for_a_restarted_terminals_prompt_holds_no_turn() {
    use std::os::unix::fs::PermissionsExt;

    const TABS: usize = 3;
    // Below one prompt wait (10 s), far above 3 launches on a loaded host.
    const ALL_RESTARTED_WITHIN_MS: u64 = 8_000;
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("kept-restore-prompt-wait");
    let terminals = create_workspaces(&harness, "wait", TABS);
    for terminal in &terminals {
        let set = request(
            &harness.socket,
            serde_json::json!({
                "cmd": "terminal-resume-command",
                "terminal_id": terminal,
                "command": "echo kept",
            }),
        );
        assert_eq!(set["command"], "echo kept", "{set}");
    }
    end_sessions_keep_layout(&mut harness);

    // The new shell of each restart: output with no gap as long as a quiet
    // prompt for 12 s, and never a prompt.
    let shell = harness.dir.join("no-prompt-shell");
    fs::write(
        &shell,
        "#!/bin/sh\necho no-prompt-shell\ni=0\n\
         while [ $i -lt 120 ]; do printf .; sleep 0.1; i=$((i+1)); done\nexec /bin/cat\n",
    )
    .unwrap();
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o755)).unwrap();
    harness.extra_env.push(("SHELL".into(), shell.to_string_lossy().into_owned()));
    harness.extra_env.push(("CMUX_TUI_TEST_RESPAWN_SLOTS".into(), "1".into()));
    harness.restart();
    let kept = all_tabs(&harness);
    assert_eq!(kept.len(), TABS, "the restart did not keep every tab");
    restart_kept_tabs(&harness, &kept);

    // When each terminal restarted, from the loss log (one line per restart).
    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(90));
    let restarted = loop {
        let lines = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|event| event["event"] == "terminal_respawned")
            .collect::<Vec<_>>();
        if terminals
            .iter()
            .all(|terminal| lines.iter().any(|line| line["terminal_id"] == terminal.as_str()))
        {
            break lines;
        }
        assert!(Instant::now() < deadline, "only {} of {TABS} terminals restarted", lines.len());
        std::thread::sleep(Duration::from_millis(100));
    };
    for line in &restarted {
        // Each restart has a prompt to wait for: the case under test.
        assert_eq!(line["prefilled"], "resume", "a restart had nothing to type: {line}");
    }
    let at = restarted.iter().filter_map(|line| line["at_ms"].as_u64()).collect::<Vec<_>>();
    assert_eq!(at.len(), TABS, "a restart line has no time: {restarted:?}");
    let spread = at.iter().max().unwrap() - at.iter().min().unwrap();
    // The shell with no prompt ran in a restarted terminal: with another
    // shell the prompt comes at once and the test proves nothing.
    let surface = all_tabs(&harness)[0]["surface"].as_u64().expect("a restarted tab's surface");
    let text = wait_for_screen(&harness.socket, surface, "no-prompt-shell");
    assert!(text.contains("no-prompt-shell"), "the shell with no prompt did not run: {text}");
    assert!(
        spread < ALL_RESTARTED_WITHIN_MS,
        "{TABS} kept terminals took {spread} ms to restart with 1 respawn slot: each one waited \
         for the prompt of the terminal before it"
    );
}
