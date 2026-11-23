//! A stand-in `ssh` with a shared master: `-L SPEC` adds SPEC to the master's file and stays up
//! (the forward outlives it there, as a mux client's does), `-O cancel -L SPEC` takes SPEC off.
//! Host `dies` asks for the forward and exits before it is up (the error path).

#![cfg(unix)]

use super::*;
use crate::ssh_forward::Forward;
use std::os::unix::fs::PermissionsExt as _;

struct Fake {
    _dir: tempfile::TempDir,
    ssh: PathBuf,
    master: PathBuf,
    ledger: PathBuf,
}

fn fake() -> Fake {
    let dir = tempfile::tempdir().unwrap();
    let master = dir.path().join("master");
    std::fs::write(&master, "").unwrap();
    let ssh = dir.path().join("ssh");
    let script = format!(
        r#"#!/bin/sh
M='{master}'
op=; spec=; host=
while [ $# -gt 0 ]; do
  case "$1" in
    -O) op=$2; shift 2;;
    -L) spec=$2; shift 2;;
    -o) shift 2;;
    --) host=$2; break;;
    *) shift;;
  esac
done
if [ "$op" = cancel ]; then
  grep -vxF "$spec" "$M" > "$M.n"; mv "$M.n" "$M"; exit 0
fi
echo "$spec" >> "$M"
[ "$host" = dies ] && exit 1
: > "${{spec%%:*}}"
echo $$ > "${{spec%%:*}}.pid"
while :; do sleep 1; done
"#,
        master = master.display()
    );
    std::fs::write(&ssh, script).unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let ledger = dir.path().join("ssh-forwards");
    Fake { ssh, master, ledger, _dir: dir }
}

fn on_master(fake: &Fake) -> Vec<String> {
    std::fs::read_to_string(&fake.master)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect()
}

fn records(fake: &Fake) -> usize {
    std::fs::read_dir(&fake.ledger)
        .map(|d| d.flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".json")).count())
        .unwrap_or(0)
}

/// Waits (bounded, 10 s) until no record is left: a drop ends its forward off the worker.
async fn settled(fake: &Fake) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while records(fake) > 0 && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn pid_gone(pid: u32) -> bool {
    !pid_runs(pid)
}

/// The ask: after 10 move/exit cycles no forward is left on the master, no record, no ssh.
/// Each cycle ends as a move does (`close`), as an error path does (dropped), or with an ssh
/// that asked for the forward and died before it was up.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ten_move_exit_cycles_leave_no_forward_on_the_master() {
    let fake = fake();
    for cycle in 0..10 {
        let host = if cycle % 5 == 4 { "dies" } else { "box" };
        let opened =
            Forward::open_with(fake.ssh.as_os_str(), &fake.ledger, host, "/far/acpmux.sock").await;
        match opened {
            Ok(fwd) => {
                assert_eq!(records(&fake), 1, "cycle {cycle}: the open forward is recorded");
                assert_eq!(on_master(&fake).len(), 1, "cycle {cycle}: the forward is up");
                let pid = fwd.ssh_pid().unwrap();
                if cycle % 2 == 0 {
                    fwd.close().await;
                } else {
                    drop(fwd);
                }
                settled(&fake).await;
                let deadline = std::time::Instant::now() + Duration::from_secs(5);
                while !pid_gone(pid) && std::time::Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                assert!(pid_gone(pid), "cycle {cycle}: its ssh {pid} still runs");
            }
            Err(e) => {
                assert_eq!(host, "dies", "cycle {cycle}: {e:#}");
                settled(&fake).await;
            }
        }
        assert_eq!(on_master(&fake), Vec::<String>::new(), "cycle {cycle}: left on the master");
        assert_eq!(records(&fake), 0, "cycle {cycle}: a record is left");
    }
}

fn record_for(owner: u32, local: &Path) -> Record {
    Record {
        owner,
        host: "box".into(),
        local: local.to_owned(),
        remote: "/far/acpmux.sock".into(),
        opened: SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs(),
    }
}

/// An owner killed before its drop ran: its ssh ends by itself (its stdin's pipe closed), and
/// the forward the master kept is cancelled at the next start, by its record.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_killed_owners_ssh_ends_and_its_forward_is_cancelled_at_start() {
    let fake = fake();
    let fwd = Forward::open_with(fake.ssh.as_os_str(), &fake.ledger, "box", "/far/acpmux.sock")
        .await
        .unwrap();
    let pid_file = PathBuf::from(format!("{}.pid", fwd.local.display()));
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let ssh_pid = loop {
        if let Some(pid) =
            std::fs::read_to_string(&pid_file).ok().and_then(|p| p.trim().parse::<u32>().ok())
        {
            break pid;
        }
        assert!(std::time::Instant::now() < deadline, "the stand-in ssh wrote no pid");
        tokio::time::sleep(Duration::from_millis(10)).await;
    };
    fwd.owner_dies();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while pid_runs(ssh_pid) && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(!pid_runs(ssh_pid), "the killed owner's ssh {ssh_pid} still runs");
    assert_eq!(on_master(&fake).len(), 1, "the master keeps the forward of a dead client");
    assert_eq!(records(&fake), 1);

    // Its owner's pid, as a dead process's: one that exited.
    let mut gone = std::process::Command::new("true").spawn().unwrap();
    let dead_owner = gone.id();
    gone.wait().unwrap();
    let file = std::fs::read_dir(&fake.ledger).unwrap().flatten().next().unwrap().path();
    let mut record: Record = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    record.owner = dead_owner;
    std::fs::write(&file, serde_json::to_vec(&record).unwrap()).unwrap();
    let reaped = reap_recorded(fake.ssh.as_os_str(), &fake.ledger);

    assert_eq!(reaped, Reaped { ended: 1, kept: 0 });
    assert_eq!(on_master(&fake), Vec::<String>::new(), "the forward is still on the master");
    assert_eq!(records(&fake), 0);
}

/// A forward whose owner still runs (a move in progress in another process) is left alone.
#[test]
fn a_live_owners_forward_is_left_alone() {
    let fake = fake();
    let dir = tempfile::tempdir().unwrap();
    let mut live = std::process::Command::new("sleep").arg("30").spawn().unwrap();
    let kept = record_for(live.id(), &dir.path().join("a.sock"));
    let _ = write_record(&fake.ledger, &kept).unwrap();
    let reaped = reap_recorded(fake.ssh.as_os_str(), &fake.ledger);
    assert_eq!(reaped, Reaped { ended: 0, kept: 1 });
    assert_eq!(records(&fake), 1);
    let _ = live.kill();
    let _ = live.wait();
}
