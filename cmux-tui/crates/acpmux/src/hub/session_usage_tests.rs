//! The pure parts of `session_usage.rs`: the fold, the CPU delta, the average, the
//! `/proc/PID/stat` parser and the per-sample accounting.

use super::*;

fn p(pid: u32, cpu_ns: u64, rss_bytes: u64) -> Proc {
    Proc { pid, cpu_ns, rss_bytes }
}

#[test]
fn fold_sums_cpu_and_memory() {
    let cases: &[(&[Proc], (u64, u64))] = &[
        (&[], (0, 0)),
        (&[p(1, 5, 10)], (5, 10)),
        (&[p(1, 5, 10), p(2, 7, 20)], (12, 30)),
        (&[p(1, u64::MAX, 1), p(2, 1, 1)], (u64::MAX, 2)),
    ];
    for (procs, want) in cases {
        assert_eq!(fold(procs), *want);
    }
}

#[test]
fn cores_is_the_delta_over_the_window_never_negative() {
    let s = Duration::from_secs;
    let cases = [
        (0, 3_000_000_000, s(3), 1.0),
        (1_000_000_000, 7_000_000_000, s(3), 2.0),
        (5_000_000_000, 1_000_000_000, s(3), 0.0),
        (0, 1_000_000_000, Duration::ZERO, 0.0),
    ];
    for (before, now, dt, want) in cases {
        assert!((cores(before, now, dt) - want).abs() < 1e-9, "{before} {now} {dt:?}");
    }
}

#[test]
fn ewma_moves_by_the_elapsed_share_of_tau() {
    let tau = Duration::from_secs(300);
    assert_eq!(ewma(None, 2.0, Duration::from_secs(3), tau), 2.0);
    let one_tau = ewma(Some(0.0), 1.0, tau, tau);
    assert!((one_tau - (1.0 - (-1.0f64).exp())).abs() < 1e-9);
    let short = ewma(Some(1.0), 3.0, Duration::from_secs(3), tau);
    assert!(short > 1.0 && short < 1.05, "{short}");
    assert_eq!(ewma(Some(1.0), 3.0, Duration::ZERO, tau), 1.0);
    assert_eq!(ewma(Some(1.0), 3.0, Duration::from_secs(3), Duration::ZERO), 3.0);
}

#[test]
fn parse_stat_reads_cpu_with_reaped_children_and_rss() {
    // Fields after the name: state ppid pgrp session tty tpgid flags minflt cminflt majflt
    // cmajflt utime stime cutime cstime priority nice threads itreal starttime vsize rss
    let fields = |line: &str| line.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    let got = parse_stat(
        42,
        &fields("S 7 42 42 0 -1 0 0 0 0 0 10 5 3 2 20 0 4 0 100 1000 250 rest"),
        10_000_000,
        4096,
    );
    assert_eq!(got, Some(p(42, 20 * 10_000_000, 250 * 4096)));
    assert_eq!(parse_stat(1, &fields(""), 1, 1), None);
    // A short record (a zombie's) reads what it has.
    assert_eq!(parse_stat(3, &fields("Z 1"), 1, 1), Some(p(3, 0, 0)));
}

fn roots(id: &str, pids: &[u32]) -> Roots {
    Roots { id: id.into(), active: true, pids: pids.to_vec() }
}

#[test]
fn advance_counts_known_roots_and_baselines_new_ones() {
    let t0 = Instant::now();
    let dt = Duration::from_secs(3);
    let s = |secs: u64| secs * 1_000_000_000;
    // First sample: baselines only, no cores yet.
    let first = advance(
        State::default(),
        vec![(roots("a", &[10]), vec![(10, s(100), 1_000)]), (roots("b", &[20]), vec![])],
        t0,
        None,
    );
    assert_eq!(first.last.sessions.len(), 1, "a session with nothing read is left out");
    assert_eq!(first.last.sessions[0].load.cpu_cores, 0.0);
    assert_eq!(first.last.rss_bytes, 1_000);
    // 3 s later: root 10 used 6 s of CPU (2 cores); a new background task's root 11 is only a
    // baseline, its 50 s of CPU from before are not this window's.
    let second = advance(
        first,
        vec![(roots("a", &[10, 11]), vec![(10, s(106), 1_000), (11, s(50), 500)])],
        t0 + dt,
        Some(dt),
    );
    let a = &second.last.sessions[0];
    assert_eq!(a.id, "a");
    assert!((a.load.cpu_cores - 2.0).abs() < 1e-9, "{}", a.load.cpu_cores);
    assert_eq!(a.load.rss_bytes, 1_500);
    // Then both roots count; a drop (a child gone unreaped) adds nothing.
    let third = advance(
        second,
        vec![(roots("a", &[10, 11]), vec![(10, s(100), 1_000), (11, s(53), 500)])],
        t0 + dt * 2,
        Some(dt),
    );
    let got = third.last.sessions[0].load.cpu_cores;
    let want = ewma(Some(2.0), 1.0, dt, EWMA_TAU);
    assert!((got - want).abs() < 1e-9, "{got} vs {want}");
    assert!((third.last.cpu_cores - want).abs() < 1e-9);
}

#[test]
fn advance_sorts_heaviest_first_and_serializes_as_session_load() {
    let t0 = Instant::now();
    let dt = Duration::from_secs(3);
    let base = advance(
        State::default(),
        vec![(roots("a", &[1]), vec![(1, 0, 1)]), (roots("b", &[2]), vec![(2, 0, 2)])],
        t0,
        None,
    );
    let next = advance(
        base,
        vec![
            (roots("a", &[1]), vec![(1, 3_000_000_000, 1)]),
            (roots("b", &[2]), vec![(2, 9_000_000_000, 2)]),
        ],
        t0 + dt,
        Some(dt),
    );
    let ids: Vec<&str> = next.last.sessions.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["b", "a"]);
    let v = serde_json::to_value(&next.last.sessions[0]).unwrap();
    assert_eq!(v["id"], "b");
    assert_eq!(v["active"], true);
    assert_eq!(v["rss_bytes"], 2);
    assert!((v["cpu_cores"].as_f64().unwrap() - 3.0).abs() < 1e-9);
}

#[cfg(target_os = "linux")]
#[test]
fn sample_reads_this_process_tree() {
    let me = std::process::id();
    let mut child = std::process::Command::new("sleep").arg("5").spawn().expect("spawn sleep");
    let got = sample(vec![roots("me", &[me])]);
    let _ = child.kill();
    let _ = child.wait();
    let me = got.sessions.iter().find(|s| s.id == "me").expect("this process is read");
    assert!(me.load.rss_bytes > 0);
    assert_eq!(got.rss_bytes, me.load.rss_bytes);
}
