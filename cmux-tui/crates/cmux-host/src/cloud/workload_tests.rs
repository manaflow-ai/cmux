use super::*;

fn proc(pid: u32, comm: &str, ticks: u64) -> ProcStat {
    ProcStat { pid, comm: comm.to_owned(), start: 1_000 + u64::from(pid), ticks, kthread: false }
}

fn snap(mono_ms: u64, procs: Vec<ProcStat>) -> Snapshot {
    Snapshot { mono_ms, clk_tck: 100, procs, listeners: Vec::new(), timers: Vec::new() }
}

#[test]
fn stat_reads_comm_with_spaces_and_parens_ticks_and_kernel_threads() {
    // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt
    // utime stime cutime cstime prio nice threads itreal starttime ...
    let text = "42 (a (b) c) S 1 42 42 0 -1 4194560 10 0 0 0 7 3 20 10 20 0 1 0 5555 0 0";
    let p = parse_stat(42, text).unwrap();
    assert_eq!(p.comm, "a (b) c");
    assert_eq!(p.ticks, 40, "utime + stime + reaped children's");
    assert_eq!(p.start, 5555);
    assert!(!p.kthread);
    let kthread = "2 (kthreadd) S 0 0 0 0 -1 2129984 0 0 0 0 0 0 0 0 20 0 1 0 1 0 0";
    assert!(parse_stat(2, kthread).unwrap().kthread);
    assert!(parse_stat(3, "3 (x) S").is_none(), "a short line does not read");
}

#[test]
fn listeners_are_listen_state_sockets_by_port() {
    let tcp = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1 0\n\
   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 222 1 0\n\
   2: 0100007F:0BB8 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 333 1 0\n";
    assert_eq!(
        parse_listeners(tcp),
        vec![(3000, 111), (22, 222)],
        "an established socket is not one"
    );
}

#[test]
fn crontab_jobs_skip_comments_blanks_and_assignments() {
    assert!(!crontab_has_jobs("# m h dom mon dow command\n\nSHELL=/bin/sh\nMAILTO=\"\"\n"));
    assert!(crontab_has_jobs("SHELL=/bin/sh\n*/5 * * * * /home/cmux/backup.sh\n"));
    assert!(crontab_has_jobs("@reboot cd /srv && ./run\n"));
}

#[test]
fn the_first_probe_is_unknown_and_cpu_above_two_percent_is_busy() {
    let mut t = Tracker::default();
    assert!(
        t.observe(&snap(0, vec![proc(10, "node", 0)]), 1).is_none(),
        "CPU use needs two probes"
    );
    // 30 s at 100 ticks/s: 2% is 60 ticks. 61 is busy, 60 is not.
    let w = t.observe(&snap(30_000, vec![proc(10, "node", 61), proc(11, "cargo", 0)]), 2).unwrap();
    assert_eq!(w.busy_processes, ["node"]);
    assert_eq!(w.last_busy_at, Some(2));
    let w = t.observe(&snap(60_000, vec![proc(10, "node", 121)]), 3).unwrap();
    assert!(!w.busy(), "60 ticks in 30 s is 2%, not above it");
    assert_eq!(w.last_busy_at, Some(2), "the idle period starts at the last busy probe");
}

#[test]
fn a_clock_stepped_back_never_moves_the_last_busy_time_earlier() {
    let mut t = Tracker::default();
    t.observe(&snap(0, vec![proc(10, "node", 0)]), 1);
    t.observe(&snap(30_000, vec![proc(10, "node", 100)]), 5_000);
    let w = t.observe(&snap(60_000, vec![proc(10, "node", 200)]), 4_000).unwrap();
    assert_eq!(w.last_busy_at, Some(5_000));
}

#[test]
fn a_process_new_since_the_last_probe_counts_all_its_ticks_and_a_reused_pid_is_new() {
    let mut t = Tracker::default();
    t.observe(&snap(0, vec![proc(10, "sh", 500)]), 1);
    // pid 10 again, but a different process (another start time) with 100 ticks of its own.
    let reused = ProcStat { start: 9_999, ..proc(10, "rustc", 100) };
    let w = t.observe(&snap(30_000, vec![reused, proc(12, "cc1", 100)]), 2).unwrap();
    assert_eq!(w.busy_processes, ["cc1", "rustc"]);
}

#[test]
fn system_processes_and_kernel_threads_never_count() {
    let mut t = Tracker::default();
    let busy = |pid, comm: &str| proc(pid, comm, 10_000);
    t.observe(&snap(0, vec![]), 1);
    let mut kworker = busy(5, "kworker/0:1");
    kworker.kthread = true;
    let procs = vec![
        busy(1, "systemd"),
        busy(2, "systemd-journal"),
        busy(3, "sshd"),
        busy(4, "cmux-host"),
        kworker,
        busy(6, "acpmux"),
        busy(7, "cmux-tui"),
        busy(8, "__terminal-host"),
        busy(9, "cron"),
        busy(10, "Xtigervnc"),
    ];
    let w = t.observe(&snap(30_000, procs), 2).unwrap();
    assert!(!w.busy(), "{w:?}");
    assert_eq!(w.last_busy_at, None);
}

#[test]
fn a_user_listener_or_an_unowned_one_counts_a_system_one_does_not() {
    let mut t = Tracker::default();
    let mut s = snap(0, vec![]);
    t.observe(&s, 1);
    s.mono_ms = 30_000;
    s.listeners = vec![
        (22, Some("sshd".into())),
        (6080, Some("websockify".into())),
        (3000, Some("node".into())),
        (5432, None),
        (3000, Some("node".into())),
    ];
    let w = t.observe(&s, 2).unwrap();
    assert_eq!(w.listening_ports, [3000, 5432]);
    assert!(w.busy());
}

#[test]
fn user_timers_count_and_the_systems_do_not() {
    let mut t = Tracker::default();
    let mut s = snap(0, vec![]);
    t.observe(&s, 1);
    s.mono_ms = 30_000;
    s.timers = [
        "systemd:apt-daily.timer",
        "systemd:cmux-machine-health.timer",
        "cron.d:e2scrub_all",
        "cron:cmux",
        "cron.d:nightly-backup",
        "at:a00001019abc",
        "transient:run-u42.timer",
        "user:sync.timer",
        "systemd:deploy.timer",
    ]
    .map(String::from)
    .to_vec();
    let w = t.observe(&s, 2).unwrap();
    assert_eq!(
        w.timers,
        [
            "at:a00001019abc",
            "cron.d:nightly-backup",
            "cron:cmux",
            "systemd:deploy.timer",
            "transient:run-u42.timer",
            "user:sync.timer"
        ]
    );
}

#[test]
fn the_report_block_has_counts_and_at_most_eight_names() {
    let w = Workload {
        busy_processes: (0..10).map(|i| format!("p{i}")).collect(),
        listening_ports: vec![3000],
        timers: vec![],
        last_busy_at: Some(7),
    };
    let j = w.to_json();
    assert_eq!(j["busy_processes"], 10);
    assert_eq!(j["process_names"].as_array().unwrap().len(), NAMES_MAX);
    assert_eq!(j["listening_ports"], 1);
    assert_eq!(j["ports"], json!([3000]));
    assert_eq!(j["timers"], 0);
    assert_eq!(j["last_busy_at"], 7);
}

#[test]
fn the_key_ignores_which_processes_while_busy_and_holds_the_quiet_time() {
    let a = Workload {
        busy_processes: vec!["node".into()],
        last_busy_at: Some(1),
        ..Workload::default()
    };
    let b = Workload {
        busy_processes: vec!["cargo".into()],
        last_busy_at: Some(2),
        ..Workload::default()
    };
    assert_eq!(a.key(), b.key(), "busy either way: no new report");
    let quiet = Workload { last_busy_at: Some(2), ..Workload::default() };
    assert_ne!(quiet.key(), b.key());
    let later = Workload { last_busy_at: Some(3), ..Workload::default() };
    assert_ne!(quiet.key(), later.key(), "a new quiet period is a new report");
}

#[cfg(unix)]
#[test]
fn the_reader_finds_processes_listener_owners_and_timers_under_a_root() {
    use std::fs;
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let r = root.path();
    let stat = |pid: u32, comm: &str| {
        let dir = r.join(format!("proc/{pid}/fd"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            r.join(format!("proc/{pid}/stat")),
            format!("{pid} ({comm}) S 1 1 1 0 -1 4194560 0 0 0 0 5 5 0 0 20 0 1 0 77 0 0"),
        )
        .unwrap();
        dir
    };
    stat(1, "systemd");
    symlink("socket:[222]", stat(100, "sshd").join("3")).unwrap();
    symlink("socket:[111]", stat(200, "node").join("19")).unwrap();
    symlink("/dev/pts/0", stat(200, "node").join("0")).unwrap();
    fs::create_dir_all(r.join("proc/net")).unwrap();
    fs::write(
        r.join("proc/net/tcp"),
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1 0\n\
   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 222 1 0\n\
   2: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 333 1 0\n",
    )
    .unwrap();
    fs::create_dir_all(r.join("var/spool/cron/crontabs")).unwrap();
    fs::write(r.join("var/spool/cron/crontabs/cmux"), "*/5 * * * * true\n").unwrap();
    fs::write(r.join("var/spool/cron/crontabs/root"), "# nothing\n").unwrap();
    fs::create_dir_all(r.join("etc/systemd/system/timers.target.wants")).unwrap();
    fs::write(r.join("etc/systemd/system/cmux-machine-health.timer"), "").unwrap();
    symlink(
        "/lib/systemd/system/apt-daily.timer",
        r.join("etc/systemd/system/timers.target.wants/apt-daily.timer"),
    )
    .unwrap();
    symlink("/dev/null", r.join("etc/systemd/system/masked.timer")).unwrap();
    fs::create_dir_all(r.join("home/cmux/.config/systemd/user")).unwrap();
    fs::write(r.join("home/cmux/.config/systemd/user/sync.timer"), "").unwrap();
    fs::create_dir_all(r.join("run/user/1000/systemd/transient")).unwrap();
    fs::write(r.join("run/user/1000/systemd/transient/run-r9.timer"), "").unwrap();
    fs::create_dir_all(r.join("var/spool/cron/atjobs")).unwrap();
    fs::write(r.join("var/spool/cron/atjobs/.SEQ"), "1").unwrap();
    fs::write(r.join("var/spool/cron/atjobs/a0000101"), "").unwrap();

    let s = read_snapshot(r, 5).unwrap();
    assert_eq!(s.procs.len(), 3);
    let mut listeners = s.listeners.clone();
    listeners.sort();
    assert_eq!(
        listeners,
        [(22, Some("sshd".to_owned())), (3000, Some("node".to_owned())), (8080, None)]
    );
    assert_eq!(
        s.timers,
        [
            "at:a0000101",
            "cron:cmux",
            "systemd:apt-daily.timer",
            "systemd:cmux-machine-health.timer",
            "transient:run-r9.timer",
            "user:sync.timer"
        ]
    );
    let mut t = Tracker::default();
    t.observe(&s, 1);
    let w = t.observe(&Snapshot { mono_ms: 30_005, ..s }, 2).unwrap();
    assert_eq!(w.listening_ports, [3000, 8080]);
    assert_eq!(w.timers, ["at:a0000101", "cron:cmux", "transient:run-r9.timer", "user:sync.timer"]);
    assert!(w.busy_processes.is_empty());

    assert!(read_snapshot(&r.join("nowhere"), 5).is_none(), "no /proc: unknown");

    // A missing IPv6 table is no listener; a table that exists but does not read is unknown.
    assert!(!r.join("proc/net/tcp6").exists());
    fs::create_dir_all(r.join("proc/net/tcp6")).unwrap();
    assert!(read_snapshot(r, 5).is_none(), "an unreadable listener table: unknown");
    fs::remove_dir(r.join("proc/net/tcp6")).unwrap();
    // IPv4's table is required: without it a listener could hide.
    let tcp = fs::read_to_string(r.join("proc/net/tcp")).unwrap();
    fs::rename(r.join("proc/net/tcp"), r.join("proc/net/tcp6")).unwrap();
    assert!(read_snapshot(r, 5).is_none(), "no IPv4 table: unknown");
    fs::remove_file(r.join("proc/net/tcp6")).unwrap();
    fs::write(r.join("proc/net/tcp"), tcp).unwrap();
    // A process whose stat exists but does not read is unknown, not gone.
    fs::create_dir_all(r.join("proc/300/stat")).unwrap();
    assert!(read_snapshot(r, 5).is_none(), "an unreadable process: unknown");
}
