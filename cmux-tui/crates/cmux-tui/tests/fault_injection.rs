//! Fault injection for the session daemon: an owner killed with SIGKILL in
//! the middle of its restore or right after a burst of writes, an owner
//! frozen with SIGSTOP, commits on a slow disk, and a start after an agent
//! roster reducer version bump. Each test starts a real headless owner on a
//! registry of its own and checks that the next owner serves the same state:
//! no row lost, nothing moved to `registry-recovery/`.
//!
//! Debug seams (debug builds only): `CMUX_TUI_TEST_RESTORE_DELAY_MS` holds
//! the restore after the registry opened, `CMUX_TUI_TEST_REGISTRY_COMMIT_DELAY_MS`
//! makes every registry commit that much slower inside `COMMIT`.
//!
//! Numbers (time to listen and to be ready, startup laps) go to stderr:
//! `cargo test -p cmux-tui --test fault_injection -- --nocapture`.

#![cfg(unix)]

mod fault_support;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cmux_tui_core::synth_registry::{SynthOptions, generate};
use fault_support::{
    FaultDir, NO_MAINTENANCE, Owner, create_workspace, journal_rows, lap_ms, last_startup,
    registry_sizes, request, roster_meta, thread_stacks,
};
use serde_json::{Value, json};

const READY_BOUND: Duration = Duration::from_secs(45);

fn report(test: &str, owner_ready: Duration, dir: &FaultDir, session: &str) {
    let (registry, wal) = registry_sizes(dir, session);
    let startup = last_startup(dir, session).unwrap_or(Value::Null);
    eprintln!(
        "fault: {test}: ready in {:.0} ms (startup total {} ms, restore.snapshot {} ms), \
         registry {registry} B, wal {wal} B",
        owner_ready.as_secs_f64() * 1000.0,
        startup["total_ms"],
        lap_ms(&startup, "restore.snapshot"),
    );
}

/// A registry with sealed and live journal rows, workspaces and agent
/// events, written by the synthetic generator.
fn populated(dir: &FaultDir, session: &str, bump: bool) -> Value {
    generate(
        &dir.state_root(),
        &SynthOptions {
            session: session.into(),
            session_puts: 1_500,
            agent_events: 120,
            workspaces: 4,
            seal: true,
            roster_version_bump: bump,
            batch_rows: 400,
            ..SynthOptions::default()
        },
    )
    .unwrap()
    .to_json()
}

/// An owner killed while it restores (after its registry opened, before it
/// read the saved session) leaves the registry whole: the next owner is
/// ready with the same workspaces and every journal row, and nothing was
/// moved to `registry-recovery/`.
#[test]
fn injected_fault_sigkill_during_restore_keeps_every_row() {
    let dir = FaultDir::new("restore-kill");
    let session = "fi-restore-kill";
    populated(&dir, session, false);
    let (live_before, sealed_before) = journal_rows(&dir, session);
    assert!(!live_before.is_empty() && !sealed_before.is_empty());

    let mut owner =
        Owner::spawn(&dir, session, &[("CMUX_TUI_TEST_RESTORE_DELAY_MS", "6000"), NO_MAINTENANCE]);
    owner.wait_listening(READY_BOUND);
    // Restoring: the socket is bound, and a request waits for the restore.
    std::thread::sleep(Duration::from_millis(500));
    owner.assert_alive("restoring");
    assert!(
        request(&dir.socket(), json!({"cmd": "identify"}), Duration::from_millis(300)).is_none(),
        "the owner answered before its restore ended: not killed mid-restore"
    );
    owner.kill9();

    let mut owner = Owner::spawn(&dir, session, &[NO_MAINTENANCE]);
    let ready = owner.wait_ready(READY_BOUND);
    report("restart after a kill mid-restore", ready, &dir, session);
    let names = owner.workspace_names();
    for index in 0..4 {
        assert!(names.contains(&format!("synth {index}")), "{names:?}");
    }
    let (live_after, sealed_after) = journal_rows(&dir, session);
    let lost = live_before.difference(&live_after).count();
    assert_eq!(lost, 0, "{lost} journal rows lost");
    assert_eq!(sealed_after[..sealed_before.len()], sealed_before[..]);
    owner.stop();
    assert!(dir.recovered(session).is_empty(), "{:?}", dir.recovered(session));
}

/// Every write the owner acknowledged survives a SIGKILL right after it.
#[test]
fn injected_fault_sigkill_after_a_burst_keeps_every_acknowledged_write() {
    let dir = FaultDir::new("burst-kill");
    let session = "fi-burst-kill";
    let owner = Owner::start(&dir, session, &[NO_MAINTENANCE], READY_BOUND);
    let names = (0..24).map(|index| format!("burst {index}")).collect::<Vec<_>>();
    for name in &names {
        create_workspace(&dir.socket(), name);
    }
    let (live_before, _) = journal_rows(&dir, session);
    owner.kill9();

    let mut owner = Owner::spawn(&dir, session, &[NO_MAINTENANCE]);
    let ready = owner.wait_ready(READY_BOUND);
    report("restart after a kill after a burst", ready, &dir, session);
    let restored = owner.workspace_names();
    let missing = names.iter().filter(|name| !restored.contains(name)).collect::<Vec<_>>();
    assert!(missing.is_empty(), "acknowledged workspaces lost: {missing:?}");
    let (live_after, _) = journal_rows(&dir, session);
    assert_eq!(live_before.difference(&live_after).count(), 0);
    owner.stop();
    assert!(dir.recovered(session).is_empty());
}

/// A frozen owner keeps its socket but never answers; `server ensure
/// --replace-unresponsive` (the app's "Restart cmux-tui") replaces it within
/// its bound, and the new owner serves the same workspaces.
/// (replace_unresponsive_owner.rs covers the replace itself; this adds the
/// bound and the state.)
#[test]
fn injected_fault_a_frozen_owner_is_replaced_with_its_state() {
    let dir = FaultDir::new("frozen");
    let session = "fi-frozen";
    let owner = Owner::start(&dir, session, &[], READY_BOUND);
    for index in 0..3 {
        create_workspace(&dir.socket(), &format!("kept {index}"));
    }
    let old = owner.pid();
    owner.signal(libc::SIGSTOP);

    let started = Instant::now();
    let replaced = dir.server(session, "ensure", &["--replace-unresponsive"]);
    let took = started.elapsed();
    let stdout = String::from_utf8_lossy(&replaced.stdout);
    eprintln!("fault: a frozen owner was replaced in {} ms", took.as_millis());
    assert!(replaced.status.success(), "{stdout} {}", String::from_utf8_lossy(&replaced.stderr));
    let value: Value =
        serde_json::from_str(stdout.lines().rfind(|line| line.starts_with('{')).unwrap()).unwrap();
    assert_eq!(value["status"], "replaced", "{value}");
    assert_eq!(value["replaced_pid"], old, "{value}");
    assert!(took < Duration::from_secs(30), "the replace took {took:?}");
    // The frozen owner is this test's child: it is gone once it can be reaped.
    let mut owner = owner;
    let reaped = Instant::now() + Duration::from_secs(5);
    while owner.child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < reaped, "the frozen owner {old} still runs");
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(owner);

    // The new owner was started by `ensure`, not by this test.
    let names = request(&dir.socket(), json!({"cmd": "list-workspaces"}), Duration::from_secs(30))
        .unwrap()["data"]["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["name"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    let stopped = dir.server(session, "stop", &["--end-terminals"]);
    assert!(stopped.status.success(), "{}", String::from_utf8_lossy(&stopped.stderr));
    for index in 0..3 {
        assert!(names.contains(&format!("kept {index}")), "{names:?}");
    }
    assert!(dir.recovered(session).is_empty());
}

/// While every registry commit takes 2.5 s (a slow disk), `identify` and a
/// read (`list-workspaces`) still answer within 2 s: no request that does
/// not write waits for a commit.
///
/// Known red at 7af9d379567 (feat-cmux-next 92671556d50 and these seams;
/// macOS, aws-m4pro-3): identify waited 4.9-5.0 s and list-workspaces up to
/// 5.0 s, two commits. `workspace.create` (empty) holds the mux state lock
/// (`lock_state_pinned` in `resource_create_empty_workspace_selected`) across
/// both of its registry commits (`prepare_resource_creation_for`, then
/// `commit_resource_creation_patch`), and identify reads `workspace_revision`
/// under that lock, as list-workspaces reads the tree.
#[test]
#[ignore = "known: workspace.create commits twice while it holds the mux state lock, so identify \
            and list-workspaces wait for both commits; fixed by committing request writes outside \
            the state lock (writer-batch intents, cx-ags0 PR7)"]
fn injected_fault_reads_answer_while_registry_commits_are_slow() {
    const COMMIT_DELAY_MS: &str = "2500";
    let dir = FaultDir::new("slow-commit");
    let session = "fi-slow-commit";
    let owner = Owner::start(
        &dir,
        session,
        &[("CMUX_TUI_TEST_REGISTRY_COMMIT_DELAY_MS", COMMIT_DELAY_MS), NO_MAINTENANCE],
        Duration::from_secs(90),
    );
    report("start with slow commits", owner.started.elapsed(), &dir, session);
    let writing = Arc::new(AtomicBool::new(true));
    let writer = {
        let writing = writing.clone();
        let socket = dir.socket();
        std::thread::spawn(move || {
            let mut written = 0;
            while writing.load(Ordering::Relaxed) {
                create_workspace(&socket, &format!("slow {written}"));
                written += 1;
            }
            written
        })
    };
    // Let the first slow commit begin.
    std::thread::sleep(Duration::from_millis(300));
    let mut slowest = (Duration::ZERO, Duration::ZERO);
    let mut sampled = false;
    let until = Instant::now() + Duration::from_secs(8);
    while Instant::now() < until {
        for (command, slot) in [("identify", 0), ("list-workspaces", 1)] {
            let started = Instant::now();
            let probe = {
                let socket = dir.socket();
                std::thread::spawn(move || {
                    request(&socket, json!({"cmd": command}), Duration::from_secs(10))
                })
            };
            // A read that waits: where the owner's threads are, once per test.
            while !probe.is_finished() {
                if started.elapsed() > Duration::from_millis(1500) && !sampled {
                    sampled = true;
                    eprintln!(
                        "fault: {command} waits; owner threads:\n{}",
                        thread_stacks(owner.pid())
                    );
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let reply = probe.join().unwrap();
            let took = started.elapsed();
            assert_eq!(
                reply.as_ref().map(|reply| reply["ok"] == true),
                Some(true),
                "{command}: {reply:?}"
            );
            if slot == 0 {
                slowest.0 = slowest.0.max(took);
            } else {
                slowest.1 = slowest.1.max(took);
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    writing.store(false, Ordering::Relaxed);
    let written = writer.join().unwrap();
    eprintln!(
        "fault: slow commits ({COMMIT_DELAY_MS} ms each, {written} writes): slowest identify {} ms, \
         slowest list-workspaces {} ms",
        slowest.0.as_millis(),
        slowest.1.as_millis()
    );
    assert!(written >= 2, "the writer made {written} slow commits");
    assert!(slowest.0 < Duration::from_secs(2), "identify waited {:?}", slowest.0);
    assert!(slowest.1 < Duration::from_secs(2), "list-workspaces waited {:?}", slowest.1);
    owner.stop();
}

/// A roster snapshot written by an older reducer version is discarded: the
/// owner re-folds the journal (sealed segments and live rows), becomes
/// ready, and saves a snapshot of the current version equal to the fold of
/// the same records.
#[test]
fn injected_fault_a_roster_version_bump_refolds_and_starts() {
    let dir = FaultDir::new("roster-bump");
    let session = "fi-roster-bump";
    let generated = populated(&dir, session, true);
    let current = generated["roster_current_version"].as_u64().unwrap();
    let (version, _, folded) = roster_meta(&dir, session).unwrap();
    assert_eq!(version, current - 1);

    let mut owner = Owner::spawn(&dir, session, &[NO_MAINTENANCE]);
    let ready = owner.wait_ready(READY_BOUND);
    report("start after a roster version bump", ready, &dir, session);
    let (version, cursor, refolded) = roster_meta(&dir, session).unwrap();
    owner.stop();
    assert_eq!(version, current, "the owner did not save the re-folded roster");
    assert!(cursor >= generated["journal_head"].as_u64().unwrap());
    assert!(!folded["entries"].as_object().unwrap().is_empty());
    assert_eq!(refolded["entries"], folded["entries"]);
    assert!(dir.recovered(session).is_empty());
}
