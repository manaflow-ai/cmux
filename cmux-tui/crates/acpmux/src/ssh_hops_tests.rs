//! Hops as `sleep` stand-ins: what a hop's exit gives back, the cap, and what a sweep may end.

#![cfg(unix)]

use super::*;
use std::time::Instant;

fn sleeper() -> tokio::process::Command {
    let mut command = tokio::process::Command::new("sleep");
    command.arg("600").kill_on_drop(true);
    command
}

fn records(ledger: &Path) -> Vec<Record> {
    let Ok(entries) = std::fs::read_dir(ledger) else { return Vec::new() };
    entries
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".json"))
        .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
        .collect()
}

/// Until `done` holds, at most 5 s.
async fn until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "{what}: not within 5 s");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn runs(pid: u32) -> bool {
    crate::owner_exit::process_start(pid).is_some()
}

/// A closed route leaves no child behind: the hop's drop ends its ssh, and its exit takes its
/// record and its host's slot back.
#[tokio::test]
async fn a_closed_hop_leaves_no_child_record_or_slot() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_dir(dir.path());
    let host = "hops-closed";
    let child = spawn(|| sleeper().spawn(), host, Some(&ledger)).unwrap();
    let pid = child.id().unwrap();
    let held = records(&ledger);
    assert_eq!(held.len(), 1, "{held:?}");
    assert_eq!(
        (held[0].pid, held[0].owner, held[0].host.as_str()),
        (pid, std::process::id(), host)
    );
    assert!(held[0].start.is_some() && held[0].owner_start.is_some(), "{held:?}");
    assert_eq!(open_to(host), 1);
    // This daemon's own live hop is never a sweep's.
    assert_eq!(reap_recorded(&ledger), Reaped { kept: 1, ..Reaped::default() });
    assert!(runs(pid));

    drop(child);
    // The exit event fires on the hop's exit (a zombie until the runtime reaps it).
    until("its record goes", || records(&ledger).is_empty()).await;
    until("its slot comes back", || open_to(host) == 0).await;
}

/// A host has at most `MAX_PER_HOST` hops open; one more is refused with why, and a slot comes
/// back once a hop exits. Another host is not affected.
#[tokio::test]
async fn one_host_has_at_most_its_cap_of_hops() {
    let host = "hops-capped";
    let mut held: Vec<_> =
        (0..MAX_PER_HOST).map(|_| spawn(|| sleeper().spawn(), host, None).unwrap()).collect();
    let refused = spawn(|| sleeper().spawn(), host, None).unwrap_err();
    assert!(refused.to_string().contains("the most one host may have"), "{refused}");
    assert_eq!(open_to(host), MAX_PER_HOST);
    let other = spawn(|| sleeper().spawn(), "hops-capped-other", None).unwrap();

    drop(held.remove(0));
    until("the ended hop's slot comes back", || open_to(host) < MAX_PER_HOST).await;
    let again = spawn(|| sleeper().spawn(), host, None).unwrap();
    drop((held, again, other));
    until("every slot comes back", || open_to(host) == 0).await;
}

/// A sweep ends a hop whose daemon is gone (it went without dropping it: reparented, as on a
/// take-over), but only a process that still runs at the record's pid with its start time. A
/// live owner's hop and a reused pid are left alone; every dead owner's record goes.
#[tokio::test]
async fn a_sweep_ends_only_the_hops_a_gone_daemon_recorded() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_dir(dir.path());
    crate::home_fs::private_dir(&ledger).unwrap();
    // A daemon that went: a process that ran and exited.
    let mut gone = std::process::Command::new("true").spawn().unwrap();
    let gone_pid = gone.id();
    let gone_start = crate::owner_exit::process_start(gone_pid);
    gone.wait().unwrap();
    // A daemon that still runs.
    let mut alive = std::process::Command::new("sleep").arg("600").spawn().unwrap();
    let alive_pid = alive.id();

    let mut left = std::process::Command::new("sleep").arg("600").spawn().unwrap();
    let mut reused = std::process::Command::new("sleep").arg("600").spawn().unwrap();
    let mut kept = std::process::Command::new("sleep").arg("600").spawn().unwrap();
    let record = |owner: u32, owner_start, pid: u32, start| Record {
        owner,
        owner_start,
        pid,
        start,
        host: "hops-swept".into(),
        opened: now_secs(),
    };
    let start = |pid| crate::owner_exit::process_start(pid);
    let rows = [
        // The gone daemon's hop, still running: ended.
        record(gone_pid, gone_start.or(Some(1)), left.id(), start(left.id())),
        // The gone daemon's record of a pid another process holds now: not signalled.
        record(gone_pid, gone_start.or(Some(1)), reused.id(), start(reused.id()).map(|s| s + 1)),
        // A gone daemon's hop that already exited.
        record(gone_pid, gone_start.or(Some(1)), gone_pid, gone_start),
        // A live daemon's hop: kept.
        record(alive_pid, start(alive_pid), kept.id(), start(kept.id())),
    ];
    for row in &rows {
        write_record(&ledger, row).unwrap();
    }

    let reaped = reap_recorded(&ledger);
    assert_eq!(reaped, Reaped { ended: 1, gone: 2, kept: 1 });
    let status = left.wait().unwrap();
    assert!(!status.success(), "the left hop was ended: {status:?}");
    assert!(reused.try_wait().unwrap().is_none(), "a reused pid is never signalled");
    assert!(kept.try_wait().unwrap().is_none(), "a live daemon's hop is never signalled");
    let after = records(&ledger);
    assert_eq!(after.len(), 1, "{after:?}");
    assert_eq!(after[0].pid, kept.id());

    for mut c in [reused, kept, alive] {
        let _ = c.kill();
        let _ = c.wait();
    }
}

/// The sweep reads at most `MAX_RECORDS`, drops records it cannot read, and a torn temp file
/// only once it is old: a start costs the same whatever was left.
#[test]
fn a_sweep_removes_unreadable_records() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_dir(dir.path());
    crate::home_fs::private_dir(&ledger).unwrap();
    std::fs::write(ledger.join("1-1.json"), b"not json").unwrap();
    std::fs::write(ledger.join(".2-2.json.tmp"), b"{").unwrap();
    assert_eq!(reap_recorded(&ledger), Reaped::default());
    assert!(!ledger.join("1-1.json").exists());
    assert!(ledger.join(".2-2.json.tmp").exists(), "a fresh temp file may be a write in flight");
}
