use super::*;

const GIB: u64 = 1024 * 1024 * 1024;

/// The tests that take `limit_slice`'s process-wide lock run one at a time.
#[cfg(target_os = "linux")]
static SLICE_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn from(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
    let map: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    move |key: &str| map.get(key).cloned()
}

fn joined(properties: &[String]) -> String {
    properties.join(" ")
}

#[test]
fn a_session_scope_gets_memory_a_throttle_below_it_a_task_cap_and_a_cpu_weight() {
    // huge-blue: 63 GB.
    let props = properties(&from(&[]), 63 * GIB);
    let half = 63 * GIB / 2;
    assert_eq!(
        joined(&props),
        format!(
            "-p MemoryMax={half} -p MemoryHigh={} -p TasksMax=4096 -p CPUWeight=50",
            half / 10 * 9
        )
    );
}

#[test]
fn a_session_gets_a_fraction_of_swap_and_can_override_or_disable_it() {
    let props = properties_with_swap(&from(&[]), 8 * GIB, 4 * GIB);
    assert!(joined(&props).contains(&format!("-p MemorySwapMax={}", GIB)));
    let explicit = from(&[("ACPMUX_SESSION_SWAP_MB", "512")]);
    assert!(
        joined(&properties_with_swap(&explicit, 0, 4 * GIB)).contains("-p MemorySwapMax=536870912")
    );
    let off = from(&[("ACPMUX_SESSION_SWAP_MB", "0")]);
    assert!(!joined(&properties_with_swap(&off, 0, 4 * GIB)).contains("MemorySwapMax"));
}

#[test]
fn profile_env_wins_over_daemon_config_then_daemon_env() {
    let config =
        SessionLimits { memory_mb: Some(6144), swap_mb: Some(2048), ..SessionLimits::default() };
    let profile =
        BTreeMap::from([(String::from("ACPMUX_SESSION_MEMORY_MB"), String::from("4096"))]);
    let get = knob_reader(&profile, config);
    let props = properties_with_swap(&get, 32 * GIB, 8 * GIB);
    assert!(joined(&props).contains("MemoryMax=4294967296"));
    assert!(joined(&props).contains("MemorySwapMax=2147483648"));
}

#[test]
fn cli_session_budget_reaches_a_new_scope() {
    let mut config = crate::config::Config::default();
    config.set_session_resource("session.memory_mb", "6144").unwrap();
    config.set_session_resource("session.swap_mb", "2048").unwrap();
    let profile = BTreeMap::new();
    let get = knob_reader(&profile, session_limits_from_config(&config));
    let props = properties_with_swap(&get, 32 * GIB, 8 * GIB);
    assert!(joined(&props).contains("MemoryMax=6442450944"));
    assert!(joined(&props).contains("MemorySwapMax=2147483648"));
}

#[test]
fn the_sessions_slice_gets_a_larger_fraction_of_swap() {
    let got = slice_settings_with_swap(&from(&[]), 8 * GIB, 4 * GIB, SESSIONS_TASKS_FLOOR);
    assert!(
        got.iter().any(|(key, value)| *key == "MemorySwapMax" && value == &(3 * GIB).to_string())
    );
    let off = slice_settings_with_swap(
        &from(&[("ACPMUX_SESSIONS_SWAP_MAX", "0")]),
        0,
        4 * GIB,
        SESSIONS_TASKS_FLOOR,
    );
    assert!(off.iter().any(|(key, value)| *key == "MemorySwapMax" && value == "infinity"));
    let sized = slice_settings_with_swap(
        &from(&[("ACPMUX_SESSIONS_SWAP_MAX", "4G")]),
        0,
        8 * GIB,
        SESSIONS_TASKS_FLOOR,
    );
    assert!(
        sized.iter().any(|(key, value)| *key == "MemorySwapMax" && value == &(4 * GIB).to_string())
    );
}

#[test]
fn each_limit_follows_its_env_and_zero_turns_it_off() {
    let get = from(&[
        ("ACPMUX_SESSION_MEMORY_MB", "512"),
        ("ACPMUX_SESSION_TASKS_MAX", "1000"),
        ("ACPMUX_SESSION_CPU_WEIGHT", "40"),
    ]);
    assert_eq!(
        joined(&properties(&get, 64 * GIB)),
        "-p MemoryMax=536870912 -p MemoryHigh=483183819 -p TasksMax=1000 -p CPUWeight=40"
    );
    // An explicit throttle; one above the ceiling is the ceiling.
    let get =
        from(&[("ACPMUX_SESSION_MEMORY_MB", "512"), ("ACPMUX_SESSION_MEMORY_HIGH_MB", "400")]);
    assert!(joined(&properties(&get, 0)).contains("-p MemoryHigh=419430400 "));
    let get =
        from(&[("ACPMUX_SESSION_MEMORY_MB", "512"), ("ACPMUX_SESSION_MEMORY_HIGH_MB", "900")]);
    assert!(joined(&properties(&get, 0)).contains("-p MemoryHigh=536870912 "));
    // Only the throttle off.
    let get = from(&[("ACPMUX_SESSION_MEMORY_HIGH_MB", "0")]);
    assert_eq!(
        joined(&properties(&get, 8 * GIB)),
        format!("-p MemoryMax={} -p TasksMax=4096 -p CPUWeight=50", 4 * GIB)
    );
    // No task cap, other limits on: an explicit `infinity`, not systemd's default.
    let get = from(&[("ACPMUX_SESSION_TASKS_MAX", "0"), ("ACPMUX_SESSION_MEMORY_MB", "0")]);
    assert_eq!(joined(&properties(&get, 0)), "-p TasksMax=infinity -p CPUWeight=50");
    // Every limit off: no scope at all.
    let off = from(&[
        ("ACPMUX_SESSION_MEMORY_MB", "0"),
        ("ACPMUX_SESSION_TASKS_MAX", "0"),
        ("ACPMUX_SESSION_CPU_WEIGHT", "0"),
    ]);
    assert!(properties(&off, 64 * GIB).is_empty());
    // Unknown memory and no env: still capped by tasks and weight.
    assert_eq!(joined(&properties(&from(&[]), 0)), "-p TasksMax=4096 -p CPUWeight=50");
    // Unreadable values fall back to the defaults.
    let junk = from(&[("ACPMUX_SESSION_TASKS_MAX", "lots")]);
    assert!(joined(&properties(&junk, 0)).contains("TasksMax=4096"));
}

#[test]
fn the_scope_joins_the_sessions_slice_and_runs_the_harness_after_the_separator() {
    let props = properties(&from(&[("ACPMUX_SESSION_MEMORY_MB", "512")]), 0);
    let argv =
        scope_argv("/usr/bin/systemd-run", Some(SESSIONS_SLICE), "acpmux session s1", &props);
    assert_eq!(
        argv.join(" "),
        "/usr/bin/systemd-run --user --scope --quiet --collect \
             --slice=acpmuxsessions.slice --description=acpmux session s1 \
             -p MemoryMax=536870912 -p MemoryHigh=483183819 -p TasksMax=4096 -p CPUWeight=50 --"
    );
    // The probe stays out of the slice.
    let probe = scope_argv("/usr/bin/systemd-run", None, "acpmux scope probe", &props);
    assert!(!probe.iter().any(|a| a.starts_with("--slice")), "{probe:?}");
    assert!(!SESSIONS_SLICE.trim_end_matches(".slice").contains('-'), "a dash nests slices");
}

#[test]
fn the_sessions_slice_caps_all_sessions_together_in_absolute_values() {
    let pair = |k: &'static str, v: &str| (k, v.to_owned());
    let default_max = (64 * GIB * 85 / 100).to_string();
    // 64 GiB: 85% and 80%, in bytes.
    assert_eq!(
        slice_settings(&from(&[]), 64 * GIB),
        [
            pair("MemoryMax", &default_max),
            pair("MemoryHigh", &(64 * GIB * 80 / 100).to_string()),
            pair("TasksMax", "16384"),
        ]
    );
    let get = from(&[
        ("ACPMUX_SESSIONS_MEMORY_MAX", "48G"),
        ("ACPMUX_SESSIONS_MEMORY_HIGH", "0"),
        ("ACPMUX_SESSIONS_TASKS_MAX", "infinity"),
    ]);
    assert_eq!(
        slice_settings(&get, 64 * GIB),
        [
            pair("MemoryMax", &(48 * GIB).to_string()),
            pair("MemoryHigh", "infinity"),
            pair("TasksMax", "infinity"),
        ],
        "0 turns a limit off explicitly, so one set earlier goes"
    );
    let get = from(&[("ACPMUX_SESSIONS_MEMORY_MAX", "50%"), ("ACPMUX_SESSIONS_TASKS_MAX", "0")]);
    let got = slice_settings(&get, 64 * GIB);
    assert_eq!(got[0], pair("MemoryMax", &(32 * GIB).to_string()));
    assert_eq!(got[2], pair("TasksMax", "infinity"));
    // Not a size or a count: the default, never passed through.
    for junk in ["1.5G", "120%", "-1", "85%; rm", "", "G", "0%", "99999999999T"] {
        let got = slice_settings(&from(&[("ACPMUX_SESSIONS_MEMORY_MAX", junk)]), 64 * GIB);
        assert_eq!(got[0], pair("MemoryMax", &default_max), "{junk:?}");
    }
    for junk in ["16K", "50%", "-1", "lots"] {
        let got = slice_settings(&from(&[("ACPMUX_SESSIONS_TASKS_MAX", junk)]), 64 * GIB);
        assert_eq!(got[2], pair("TasksMax", "16384"), "{junk:?}");
    }
    // Unknown memory: the percentages leave memory as it is.
    assert_eq!(slice_settings(&from(&[]), 0), [pair("TasksMax", "16384")]);
}

#[test]
fn a_slice_that_has_its_limits_is_not_written_again() {
    let wanted = [
        ("MemoryMax", "1000".to_owned()),
        ("MemoryHigh", "infinity".to_owned()),
        ("TasksMax", "16384".to_owned()),
    ];
    assert_eq!(
        slice_changes("MemoryMax=infinity\nMemoryHigh=infinity\nTasksMax=4915\n", &wanted),
        ["MemoryMax=1000", "TasksMax=16384"]
    );
    let set = "MemoryMax=1000\nMemoryHigh=infinity\nTasksMax=16384\n";
    assert!(slice_changes(set, &wanted).is_empty());
    // Nothing shown: everything is set.
    assert_eq!(slice_changes("", &wanted).len(), 3);
    assert_eq!(
        slice_changes("MemoryMax=10000\n", &wanted[..1]),
        ["MemoryMax=1000"],
        "a prefix is not a match"
    );
}

/// With a real user manager: limits go onto a slice of this test's own
/// (never the sessions slice), a second call with the same limits
/// writes nothing, a limit turned off goes, and the slice is reverted.
/// Without a user manager this says so and passes.
#[test]
#[cfg(target_os = "linux")]
fn a_real_user_manager_takes_the_slice_limits_once() {
    let _serial = SLICE_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    let systemctl = std::path::Path::new("/usr/bin/systemctl");
    let env = BTreeMap::new();
    let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let manager = run_bounded(systemctl, &args(&["--user", "show-environment"]), &env, false);
    if manager.is_none() {
        eprintln!("no user systemd manager here: skipped");
        return;
    }
    let slice = format!("acpmuxtest{}.slice", std::process::id());
    let wanted = |tasks: &str| {
        vec![
            ("MemoryMax", GIB.to_string()),
            ("MemoryHigh", "infinity".to_owned()),
            ("TasksMax", tasks.to_owned()),
        ]
    };
    let first = limit_slice(systemctl, &slice, &wanted("100"), &env);
    let again = limit_slice(systemctl, &slice, &wanted("100"), &env);
    let off = limit_slice(systemctl, &slice, &wanted("infinity"), &env);
    let shown = run_bounded(
        systemctl,
        &args(&["--user", "show", &slice, "-p", "MemoryMax", "-p", "TasksMax"]),
        &env,
        true,
    );
    run_bounded(systemctl, &args(&["--user", "revert", &slice]), &env, false);
    assert!(first.as_ref().is_ok_and(|n| *n >= 2), "{first:?}");
    assert_eq!(again, Ok(0), "unchanged limits are not written again");
    assert_eq!(off, Ok(1));
    let shown = shown.unwrap_or_default();
    assert!(shown.contains(&format!("MemoryMax={GIB}")), "{shown}");
    assert!(shown.contains("TasksMax=infinity"), "{shown}");
}

/// A second session start never queues behind one that is setting the
/// slice's limits (its `systemctl` may hang for the full timeout).
#[test]
#[cfg(target_os = "linux")]
fn a_session_start_never_waits_for_another_to_set_the_slice() {
    let _serial = SLICE_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    let (held, release) = std::sync::mpsc::channel::<()>();
    let (go, ready) = std::sync::mpsc::channel::<()>();
    let marker = std::env::temp_dir().join(format!("acpmux-stalled-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let seen = marker.clone();
    let holder = std::thread::spawn(move || {
        // A `systemctl` that says it started, then stalls.
        let stall = std::env::temp_dir().join(format!("acpmux-stall-{}", std::process::id()));
        crate::test_exec::write_executable(
            &stall,
            format!("#!/bin/sh\n: > '{}'\nsleep 2\n", seen.display()),
        );
        let wanted = [("TasksMax", "1".to_owned())];
        go.send(()).unwrap();
        let _ = limit_slice(&stall, "acpmuxunused.slice", &wanted, &BTreeMap::new());
        let _ = std::fs::remove_file(&stall);
        let _ = release.recv();
    });
    ready
        .recv_timeout(std::time::Duration::from_secs(30))
        .expect("the holder never reached its stalled `systemctl`");
    // The holder is in its stalled `systemctl` (so it holds the lock).
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !marker.exists() {
        assert!(std::time::Instant::now() < deadline, "the stalled systemctl never ran");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let _ = std::fs::remove_file(&marker);
    let started = std::time::Instant::now();
    let nowhere = std::path::Path::new("/nonexistent/systemctl");
    let wanted = [("TasksMax", "1".to_owned())];
    assert_eq!(limit_slice(nowhere, "acpmuxunused.slice", &wanted, &BTreeMap::new()), Ok(0));
    assert!(started.elapsed() < std::time::Duration::from_millis(500), "it waited");
    let _ = held.send(());
    holder.join().unwrap();
}

#[test]
fn a_host_scope_takes_the_session_task_cap() {
    assert_eq!(tasks_max(&from(&[])), Some(SESSION_TASKS_MAX));
    assert_eq!(tasks_max(&from(&[("ACPMUX_SESSION_TASKS_MAX", "8192")])), Some(8192));
    assert_eq!(tasks_max(&from(&[("ACPMUX_SESSION_TASKS_MAX", "0")])), None);
}

#[test]
#[cfg(target_os = "linux")]
fn cached_scope_capability_still_reconciles_shared_slice_limits() {
    let _serial = SLICE_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    let root = tempfile::tempdir().unwrap();
    let runner = root.path().join("systemd-run");
    let log = root.path().join("slice.log");
    crate::test_exec::write_executable(&runner, "#!/bin/sh\nexit 0\n");
    crate::test_exec::write_executable(
        root.path().join("systemctl"),
        "#!/bin/sh\necho \"$*\" >> \"$FAKE_SCOPE_LOG\"\n",
    );
    let mut env = BTreeMap::from([
        ("FAKE_SCOPE_LOG".to_owned(), log.to_string_lossy().into_owned()),
        ("ACPMUX_SESSIONS_SWAP_MAX".to_owned(), "1M".to_owned()),
    ]);
    assert!(can_scope(&runner, &[], &env, SessionLimits::default()));
    env.insert("ACPMUX_SESSIONS_SWAP_MAX".to_owned(), "0".to_owned());
    assert!(can_scope(&runner, &[], &env, SessionLimits::default()));
    env.insert("ACPMUX_SESSIONS_SWAP_MAX".to_owned(), "1M".to_owned());
    assert!(can_scope(&runner, &[], &env, SessionLimits::default()));
    let calls = std::fs::read_to_string(log).unwrap();
    let sets: Vec<_> = calls.lines().filter(|line| line.contains("set-property")).collect();
    assert_eq!(sets.len(), 3, "a cache hit must still reconcile: {calls}");
    assert!(sets[1].ends_with("MemorySwapMax=infinity"));
    assert!(sets[2].ends_with("MemorySwapMax=1048576"));
}

fn limits(tasks: Option<u64>, sessions: Option<u64>) -> SessionLimits {
    SessionLimits { tasks_max: tasks, sessions_tasks_max: sessions, ..SessionLimits::default() }
}

fn slice_tasks(wanted: &[(&'static str, String)]) -> Option<String> {
    wanted.iter().find(|(key, _)| *key == "TasksMax").map(|(_, value)| value.clone())
}

#[test]
fn typed_config_task_caps_win_over_env() {
    let profile = BTreeMap::from([
        ("ACPMUX_SESSION_TASKS_MAX".to_owned(), "1000".to_owned()),
        ("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "20000".to_owned()),
    ]);
    let config = limits(Some(2048), Some(50_000));
    assert_eq!(scope_tasks_max(&profile, config), Some(2048));
    let props = properties(&knob_reader(&profile, config), 0);
    assert!(joined(&props).contains("-p TasksMax=2048 "), "{props:?}");
    let wanted = sessions_slice_wanted(&profile, config, 64 * GIB, 0, Some(514_402));
    assert_eq!(slice_tasks(&wanted).as_deref(), Some("50000"));
}

#[test]
fn env_task_caps_win_over_the_computed_default() {
    let profile = BTreeMap::from([
        ("ACPMUX_SESSION_TASKS_MAX".to_owned(), "1000".to_owned()),
        ("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "20000".to_owned()),
    ]);
    let none = SessionLimits::default();
    assert_eq!(scope_tasks_max(&profile, none), Some(1000));
    let wanted = sessions_slice_wanted(&profile, none, 64 * GIB, 0, Some(514_402));
    assert_eq!(slice_tasks(&wanted).as_deref(), Some("20000"));
    // Nothing set: the computed defaults.
    let empty = BTreeMap::new();
    assert_eq!(scope_tasks_max(&empty, none), Some(SESSION_TASKS_MAX));
    let wanted = sessions_slice_wanted(&empty, none, 64 * GIB, 0, Some(514_402));
    assert_eq!(slice_tasks(&wanted).as_deref(), Some("128600"));
}

#[test]
fn the_slice_task_default_scales_with_threads_max_between_a_floor_and_a_ceiling() {
    // A 64 GiB, 32-core fleet host: threads-max 514402, a quarter of it.
    assert_eq!(sessions_tasks_default(Some(514_402)), 128_600);
    // A small machine: never below the old fixed cap.
    assert_eq!(sessions_tasks_default(Some(30_000)), 16_384);
    assert_eq!(sessions_tasks_default(Some(65_536)), 16_384);
    assert_eq!(sessions_tasks_default(Some(0)), 16_384);
    // A very large machine: at most 262144.
    assert_eq!(sessions_tasks_default(Some(4_194_304)), 262_144);
    assert_eq!(sessions_tasks_default(Some(u64::MAX)), 262_144);
    // threads-max unreadable: the old fixed cap.
    assert_eq!(sessions_tasks_default(None), 16_384);
    assert_eq!(parse_threads_max("514402\n"), Some(514_402));
    assert_eq!(parse_threads_max("lots"), None);
    assert_eq!(parse_threads_max(""), None);
    let pair = |k: &'static str, v: &str| (k, v.to_owned());
    let got = slice_settings_with_swap(&from(&[]), 0, 0, sessions_tasks_default(Some(514_402)));
    assert_eq!(got, [pair("TasksMax", "128600")]);
    // A junk env value takes the computed default, not 16384.
    let junk = from(&[("ACPMUX_SESSIONS_TASKS_MAX", "lots")]);
    let got = slice_settings_with_swap(&junk, 0, 0, sessions_tasks_default(Some(514_402)));
    assert_eq!(got, [pair("TasksMax", "128600")]);
}

#[test]
fn zero_and_infinity_still_turn_a_task_cap_off() {
    let empty = BTreeMap::new();
    // Typed config 0: no cap, written as `infinity`.
    let off = limits(Some(0), Some(0));
    assert_eq!(scope_tasks_max(&empty, off), None);
    let props = properties(&knob_reader(&empty, off), 0);
    assert!(joined(&props).contains("-p TasksMax=infinity "), "{props:?}");
    let wanted = sessions_slice_wanted(&empty, off, 0, 0, Some(514_402));
    assert_eq!(slice_tasks(&wanted).as_deref(), Some("infinity"));
    // The env's 0 and `infinity` as before.
    for value in ["0", "infinity"] {
        let env = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), value.to_owned())]);
        let wanted = sessions_slice_wanted(&env, SessionLimits::default(), 0, 0, Some(514_402));
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("infinity"), "{value}");
    }
    let env = BTreeMap::from([("ACPMUX_SESSION_TASKS_MAX".to_owned(), "0".to_owned())]);
    assert_eq!(scope_tasks_max(&env, SessionLimits::default()), None);
    // A typed cap beats an env that turns it off, and the other way round.
    let env = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "0".to_owned())]);
    let wanted = sessions_slice_wanted(&env, limits(None, Some(40_000)), 0, 0, None);
    assert_eq!(slice_tasks(&wanted).as_deref(), Some("40000"));
    let env = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "40000".to_owned())]);
    let wanted = sessions_slice_wanted(&env, limits(None, Some(0)), 0, 0, None);
    assert_eq!(slice_tasks(&wanted).as_deref(), Some("infinity"));
}

#[test]
fn the_slice_and_every_scope_read_the_task_caps_from_one_source() {
    // Two profiles that disagree in their env: with the typed config set,
    // both ask the shared slice for the same cap, so neither rewrites it.
    let a = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "20000".to_owned())]);
    let b = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "30000".to_owned())]);
    let config = limits(Some(3000), Some(100_000));
    let wa = sessions_slice_wanted(&a, config, 64 * GIB, 0, Some(514_402));
    let wb = sessions_slice_wanted(&b, config, 64 * GIB, 0, Some(514_402));
    assert_eq!(wa, wb);
    assert!(
        slice_changes("TasksMax=100000\n", &[("TasksMax", slice_tasks(&wb).unwrap())]).is_empty()
    );
    // The host scope (no profile env yet) and a session scope agree.
    assert_eq!(scope_tasks_max(&BTreeMap::new(), config), Some(3000));
    assert_eq!(scope_tasks_max(&a, config), Some(3000));
    // The CLI's typed setting reaches both.
    let mut cfg = crate::config::Config::default();
    cfg.set_session_resource("session.tasks_max", "3000").unwrap();
    cfg.set_session_resource("session.sessions_tasks_max", "100000").unwrap();
    assert_eq!(session_limits_from_config(&cfg), config);
}
