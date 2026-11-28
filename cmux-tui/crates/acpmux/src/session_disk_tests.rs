use super::*;

const GB: u64 = 1 << 30;

fn sample(scope: &str, written: u64, top: Option<i32>, own: Option<i32>) -> Sample {
    Sample {
        scope: scope.to_owned(),
        session: Some("s1".to_owned()),
        written,
        top_pgid: top,
        protected: own.into_iter().collect(),
        ..Sample::default()
    }
}

#[test]
fn kept_bytes_is_written_less_cancelled() {
    let io = "rchar: 10\nwchar: 99\nsyscr: 1\nsyscw: 1\nread_bytes: 4096\nwrite_bytes: 20480\n\
              cancelled_write_bytes: 4096\n";
    assert_eq!(kept_bytes(io), 16384);
    assert_eq!(kept_bytes("write_bytes: 5\ncancelled_write_bytes: 9\n"), 0);
    assert_eq!(kept_bytes(""), 0);
}

#[test]
fn under_budget_or_budget_off_is_ok() {
    let s = sample("a.scope", 5 * GB, Some(9), Some(2));
    assert_eq!(decide(State::Ok, &s, 8 * GB, 0, 10 * GB), (State::Ok, None));
    assert_eq!(decide(State::Over, &s, 8 * GB, 0, 10 * GB), (State::Ok, None));
    let big = sample("a.scope", 50 * GB, Some(9), Some(2));
    assert_eq!(decide(State::Ok, &big, 0, 0, 10 * GB), (State::Ok, None));
}

#[test]
fn over_budget_with_room_is_warned_once() {
    let s = sample("a.scope", 9 * GB, Some(9), Some(2));
    assert_eq!(decide(State::Ok, &s, 8 * GB, 30 * GB, 10 * GB), (State::Over, Some(Action::Warn)));
    assert_eq!(decide(State::Over, &s, 8 * GB, 30 * GB, 10 * GB), (State::Over, None));
}

#[test]
fn over_budget_with_the_disk_low_stops_the_top_writer_not_the_leader() {
    let s = sample("a.scope", 9 * GB, Some(9), Some(2));
    assert_eq!(
        decide(State::Ok, &s, 8 * GB, GB, 10 * GB),
        (State::Stopped(9), Some(Action::Stop(9)))
    );
    // Already warned: still stopped once the disk runs low.
    assert_eq!(
        decide(State::Over, &s, 8 * GB, GB, 10 * GB),
        (State::Stopped(9), Some(Action::Stop(9)))
    );
    // The writer is the scope's own leader: warned once, never stopped.
    let leader = sample("a.scope", 9 * GB, Some(2), Some(2));
    assert_eq!(
        decide(State::Ok, &leader, 8 * GB, GB, 10 * GB),
        (State::Over, Some(Action::WarnUnstoppable))
    );
    assert_eq!(decide(State::Over, &leader, 8 * GB, GB, 10 * GB), (State::Over, None));
    // No writer known, or group 1: never signalled.
    for top in [None, Some(1), Some(0)] {
        let s = sample("a.scope", 9 * GB, top, Some(2));
        assert_eq!(decide(State::Ok, &s, 8 * GB, GB, 10 * GB).0, State::Over);
    }
}

#[test]
fn a_stopped_group_resumes_at_twice_the_floor_or_when_the_budget_goes_off() {
    let s = sample("a.scope", 9 * GB, Some(9), Some(2));
    let stopped = State::Stopped(9);
    // Between the floor and twice it: stays stopped (no flapping).
    assert_eq!(decide(stopped, &s, 8 * GB, 15 * GB, 10 * GB), (stopped, None));
    assert_eq!(
        decide(stopped, &s, 8 * GB, 20 * GB, 10 * GB),
        (State::Over, Some(Action::Resume(9)))
    );
    let small = sample("a.scope", GB, Some(9), Some(2));
    assert_eq!(
        decide(stopped, &small, 8 * GB, 20 * GB, 10 * GB),
        (State::Ok, Some(Action::Resume(9)))
    );
    assert_eq!(decide(stopped, &s, 0, 0, 10 * GB), (State::Ok, Some(Action::Resume(9))));
}

#[test]
fn the_watch_acts_per_scope_and_forgets_gone_ones() {
    let mut w = Watch { budget: 8 * GB, free: 30 * GB, floor: 10 * GB, ..Watch::default() };
    w.sessions.insert("gone.scope".into(), Known::default());
    let acts = w.apply(vec![
        sample("big.scope", 9 * GB, Some(9), Some(2)),
        sample("small.scope", GB, Some(7), Some(3)),
    ]);
    assert_eq!(acts.len(), 1);
    assert_eq!((acts[0].0.scope.as_str(), acts[0].1), ("big.scope", Action::Warn));
    assert!(!w.sessions.contains_key("gone.scope"));
    // The next tick, nothing new to say.
    assert!(w.apply(vec![sample("big.scope", 9 * GB, Some(9), Some(2))]).is_empty());
    assert_eq!(w.ticks, 2);
    // The disk runs low: stopped.
    w.free = GB;
    let acts = w.apply(vec![sample("big.scope", 10 * GB, Some(9), Some(2))]);
    assert_eq!(acts[0].1, Action::Stop(9));
    let v = w.json(true);
    assert_eq!(v["enabled"], true);
    assert_eq!(v["scopes"], 1);
    assert_eq!(v["use"][0]["state"], "stopped");
    assert_eq!(v["use"][0]["stoppedPgid"], 9);
    assert_eq!(v["use"][0]["diskBytes"], 10 * GB);
    // The disk is low: measured every LOW_TICK.
    assert_eq!(v["tickSeconds"], LOW_TICK.as_secs());
    assert_eq!(next_tick(30 * GB, 10 * GB), TICK);
    assert_eq!(next_tick(19 * GB, 10 * GB), LOW_TICK);
}

#[test]
fn a_chat_is_warned_once_for_all_its_scopes_until_its_use_doubles() {
    let mut w = Watch { budget: 8 * GB, free: 30 * GB, floor: 10 * GB, ..Watch::default() };
    assert_eq!(w.apply(vec![sample("run-a.scope", 9 * GB, Some(9), Some(2))]).len(), 1);
    // The next build is a new scope of the same chat: nothing new to say.
    assert!(w.apply(vec![sample("run-b.scope", 12 * GB, Some(9), Some(2))]).is_empty());
    // Twice what it was told: told again.
    let acts = w.apply(vec![sample("run-c.scope", 18 * GB, Some(9), Some(2))]);
    assert_eq!(acts.len(), 1);
    assert_eq!(acts[0].1, Action::Warn);
    // Another chat is told on its own.
    let mut other = sample("run-d.scope", 9 * GB, Some(9), Some(2));
    other.session = Some("s2".to_owned());
    assert_eq!(w.apply(vec![other]).len(), 1);
    // A stop still goes out to a chat already warned.
    w.free = GB;
    let acts = w.apply(vec![sample("run-e.scope", 9 * GB, Some(9), Some(2))]);
    assert_eq!(acts[0].1, Action::Stop(9));
}

#[test]
fn status_lists_the_top_scopes_and_every_one_over() {
    let mut w = Watch { budget: 100, free: u64::MAX, floor: 0, ..Watch::default() };
    let mut samples: Vec<Sample> =
        (0..20).map(|i| sample(&format!("s{i:02}.scope"), 50 + i, None, None)).collect();
    // Over by its temporary directory alone.
    samples.push(sample("tiny.scope", 0, None, None));
    samples.last_mut().unwrap().tmp = 101;
    w.apply(samples);
    let v = w.json(true);
    let rows = v["use"].as_array().unwrap();
    assert_eq!(rows.len(), LISTED);
    assert_eq!(rows[0]["scope"], "tiny.scope");
    assert_eq!(rows[0]["state"], "over");
    assert_eq!(rows[1]["scope"], "s19.scope");

    // A stopped scope whose use fell is still listed past the top eight.
    w.states.insert("tiny.scope".into(), State::Stopped(5));
    (w.free, w.floor) = (0, 10);
    let mut samples: Vec<Sample> =
        (0..20).map(|i| sample(&format!("s{i:02}.scope"), 50 + i, None, None)).collect();
    samples.push(sample("tiny.scope", 0, None, None));
    w.apply(samples);
    let v = w.json(true);
    let rows = v["use"].as_array().unwrap();
    assert_eq!(rows.len(), LISTED + 1);
    assert_eq!(rows[LISTED]["scope"], "tiny.scope");
    assert_eq!(rows[LISTED]["state"], "stopped");
}

#[test]
fn the_manager_dir_ends_at_the_user_manager() {
    assert_eq!(
        manager_dir("0::/user.slice/user-1003.slice/user@1003.service/app.slice/acpmux.service\n")
            .as_deref(),
        Some("/sys/fs/cgroup/user.slice/user-1003.slice/user@1003.service")
    );
    assert_eq!(manager_dir("0::/system.slice/acpmux.service\n"), None);
    assert_eq!(manager_dir("1:name=systemd:/x\n"), None);
}

#[test]
fn dir_size_stops_at_its_entry_bound() {
    let dir = tempfile::tempdir().unwrap();
    for i in 0..5 {
        std::fs::write(dir.path().join(format!("f{i}")), vec![7u8; 8192]).unwrap();
    }
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    std::fs::write(dir.path().join("sub/g"), vec![7u8; 8192]).unwrap();
    let (bytes, partial) = dir_size(dir.path(), 100);
    assert!(!partial);
    assert!(bytes >= 6 * 8192, "{bytes}");
    let (_, partial) = dir_size(dir.path(), 3);
    assert!(partial);
    assert_eq!(dir_size(&dir.path().join("missing"), 100), (0, false));
}

#[cfg(target_os = "linux")]
#[test]
fn this_process_reads_back() {
    let io = std::fs::read_to_string("/proc/self/io").unwrap_or_default();
    let _ = kept_bytes(&io);
    // SAFETY: getpgrp has no preconditions.
    let pgid = unsafe { libc::getpgrp() };
    // Never our own group.
    assert!(!signal_group(pgid, 0));
    assert!(!signal_group(1, 0));
}

#[test]
fn the_ledger_lists_stopped_groups_and_an_empty_one_removes_it() {
    let home = tempfile::tempdir().unwrap();
    let mut w = Watch { budget: 8 * GB, free: 1, floor: 10 * GB, ..Watch::default() };
    w.apply(vec![
        sample("a.scope", 9 * GB, Some(9), Some(2)),
        sample("b.scope", GB, Some(7), None),
    ]);
    let stopped = w.stopped();
    assert_eq!(stopped, vec![StoppedGroup { scope: "a.scope".to_owned(), pgid: 9 }]);
    write_ledger(home.path(), &stopped).unwrap();
    assert_eq!(read_ledger(home.path()), stopped);
    write_ledger(home.path(), &[]).unwrap();
    assert!(!home.path().join(LEDGER).exists());
    assert!(read_ledger(home.path()).is_empty());
    write_ledger(home.path(), &[]).unwrap();
}

/// A daemon restart resumes the groups the last one stopped (SIGCONT), and only those still in
/// their scope: a stopped group the ledger does not list, or lists under another scope, stays
/// stopped.
#[cfg(target_os = "linux")]
#[test]
fn a_restart_resumes_the_groups_the_last_daemon_left_stopped() {
    use std::os::unix::process::CommandExt;
    let state = |pid: u32| {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
        stat.rsplit_once(") ").unwrap().1.chars().next().unwrap()
    };
    let wait_state = |pid: u32, want: char| {
        for _ in 0..200 {
            if state(pid) == want {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    };
    let spawn = || std::process::Command::new("sleep").arg("60").process_group(0).spawn().unwrap();
    let (mut ours, mut moved, mut own) = (spawn(), spawn(), spawn());
    for c in [&ours, &moved, &own] {
        assert!(signal_group(c.id() as i32, libc::SIGSTOP));
        assert!(wait_state(c.id(), 'T'), "{} stopped", c.id());
    }
    // A fake user manager: two scopes in the sessions slice.
    let manager = tempfile::tempdir().unwrap();
    let slice = manager.path().join(crate::session_scope::SESSIONS_SLICE);
    for (scope, pids) in [("a.scope", vec![ours.id(), own.id()]), ("b.scope", vec![moved.id()])] {
        std::fs::create_dir_all(slice.join(scope)).unwrap();
        let procs: String = pids.iter().map(|p| format!("{p}\n")).collect();
        std::fs::write(slice.join(scope).join("cgroup.procs"), procs).unwrap();
    }
    let home = tempfile::tempdir().unwrap();
    let ledger = vec![
        StoppedGroup { scope: "a.scope".to_owned(), pgid: ours.id() as i32 },
        // Listed under a scope it is not in (its id reused elsewhere): not ours to resume.
        StoppedGroup { scope: "a.scope".to_owned(), pgid: moved.id() as i32 },
        StoppedGroup { scope: "gone.scope".to_owned(), pgid: 4_000_000 },
    ];
    write_ledger(home.path(), &ledger).unwrap();

    let resumed = resume_left_stopped(home.path(), manager.path().to_str().unwrap(), |g| {
        signal_group(g, libc::SIGCONT)
    });

    assert_eq!(resumed, vec![ledger[0].clone()]);
    assert!(wait_state(ours.id(), 'S'), "the listed group runs again");
    assert_eq!(state(moved.id()), 'T', "a group outside its listed scope stays stopped");
    assert_eq!(state(own.id()), 'T', "a group the ledger does not list stays stopped");
    assert!(read_ledger(home.path()).is_empty(), "the ledger is emptied");
    // A second start resumes nothing.
    assert!(
        resume_left_stopped(home.path(), manager.path().to_str().unwrap(), |_| true).is_empty()
    );
    for c in [&mut ours, &mut moved, &mut own] {
        let _ = c.kill();
        let _ = c.wait();
    }
}
