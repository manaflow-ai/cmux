//! PTY LEAK (VIDEO EXTRA, STATUS 7938, 2026-11-03): 50 terminal tabs opened in one workspace took
//! the daemon's process tree from 4 to 208 `/dev/ptmx` handles, and after all 50 tabs and then the
//! workspace were closed it still held 208. A machine has `kern.tty.ptmx_max` PTYs (511 on macOS),
//! so a long session that opens and closes tabs runs out, and every new tab is refused with "PTY
//! capacity exhausted".
//!
//! The rule: once a closed tab's terminal is past the reap grace, the daemon's process tree (the
//! daemon and every terminal host it started) holds no PTY of it.

use super::*;

/// Every process of the daemon's tree: the daemon and the terminal hosts whose `--owner` names it.
fn tree_pids(daemon: u32) -> Vec<u32> {
    let output = Command::new("ps").args(["-e", "-o", "pid=,args="]).output().expect("run ps");
    let mut pids = vec![daemon];
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let line = line.trim();
        let Some((pid, args)) = line.split_once(char::is_whitespace) else { continue };
        let Ok(pid) = pid.parse::<u32>() else { continue };
        let owned = args.split_whitespace().skip_while(|arg| *arg != "--owner").nth(1);
        if owned
            .and_then(|owner| owner.rsplit_once('@'))
            .is_some_and(|(_, at)| at == daemon.to_string())
        {
            pids.push(pid);
        }
    }
    pids
}

/// `/dev/ptmx` handles (PTY masters) each process of the daemon's tree holds, by pid.
fn ptmx_handles(daemon: u32) -> std::collections::BTreeMap<u32, usize> {
    let pids = tree_pids(daemon);
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let output = Command::new("lsof")
        .args(["-nP", "-a", "-p", &list, "-F", "pn"])
        .output()
        .expect("run lsof");
    let mut held = std::collections::BTreeMap::new();
    let mut pid = 0;
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if let Some(value) = line.strip_prefix('p') {
            pid = value.parse().unwrap_or(0);
        } else if let Some(name) = line.strip_prefix('n')
            && name.ends_with("ptmx")
        {
            *held.entry(pid).or_insert(0) += 1;
        }
    }
    held
}

fn total(held: &std::collections::BTreeMap<u32, usize>) -> usize {
    held.values().sum()
}

/// Waits until the tree holds at most `want` PTY handles; returns the last count by pid.
fn wait_for_handles_at_most(
    daemon: u32,
    want: usize,
    within: Duration,
) -> std::collections::BTreeMap<u32, usize> {
    let deadline = Instant::now() + within;
    loop {
        let held = ptmx_handles(daemon);
        if total(&held) <= want || Instant::now() >= deadline {
            return held;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[test]
fn closed_tabs_give_back_their_ptys_once_past_the_reap_grace() {
    let _exclusive = exclusive_process_test();
    const TABS: usize = 12;
    const GRACE_SECS: u64 = 2;
    let harness = RecoveryHarness::start_with_args(
        "pty-release",
        &["--terminal-reap-grace-seconds", &GRACE_SECS.to_string()],
    );
    let daemon = harness.child.as_ref().unwrap().id();
    let (anchor, _) = run_cat_workspace(&harness.socket, 1, "anchor");
    wait_for_host_records(&harness.host_root(), 1);
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": anchor}),
    );
    let anchor_surface = resolved["surface"].as_u64().unwrap();
    let tree = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
    let pane = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .find(|pane| {
            pane["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|tab| tab["surface"].as_u64() == Some(anchor_surface))
        })
        .and_then(|pane| pane["id"].as_u64())
        .expect("anchor pane");
    // The anchor's own handles stay: the count to come back to.
    let with_anchor = wait_for_handles_at_most(daemon, usize::MAX, Duration::ZERO);

    let mut surfaces = Vec::with_capacity(TABS);
    for index in 0..TABS {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 10 + index, "cmd": "new-tab", "pane": pane, "cols": 80, "rows": 24}),
        );
        surfaces.push(created["surface"].as_u64().expect("new tab surface"));
    }
    wait_for_host_records(&harness.host_root(), TABS + 1);
    let open = ptmx_handles(daemon);
    eprintln!("ptmx handles: anchor {with_anchor:?}, with {TABS} tabs {open:?}");
    assert!(total(&open) > total(&with_anchor), "the new tabs took no PTY: {open:?}");

    for (index, surface) in surfaces.iter().enumerate() {
        let closed = request_response(
            &harness.socket,
            serde_json::json!({"id": 100 + index, "cmd": "close-surface", "surface": surface}),
        );
        assert_eq!(closed["ok"], true, "{closed}");
    }
    let after = wait_for_handles_at_most(
        daemon,
        total(&with_anchor),
        test_timeout(Duration::from_secs(GRACE_SECS + 20)),
    );
    eprintln!("ptmx handles {}s past the reap grace: {after:?}", 20);
    assert!(
        total(&after) <= total(&with_anchor),
        "{TABS} closed tabs still hold PTYs past the reap grace: {after:?} (with the anchor alone \
         {with_anchor:?}, with every tab {open:?})"
    );
}
