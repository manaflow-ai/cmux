use super::*;

/// cosmic-gray at 23:10 PDT on 2026-10-21 (cmuxterm-hq#2995), read the way the probe reads it.
pub(super) fn incident() -> Sample {
    Sample {
        load1: Some(146.3),
        // 5 Super + 10 Performance cores (an M5 Pro): `performance_cores`.
        performance_cores: Some(15),
        physical_cores: Some(15),
        logical_cpus: 15,
        vm_pressure_level: Some(2),
        psi_some_avg10: None,
        available_ram_fraction: Some(0.34),
        swapout_bytes: Some(40 << 30),
    }
}

/// The same Mac running a normal lane load.
pub(super) fn calm() -> Sample {
    Sample {
        load1: Some(6.2),
        vm_pressure_level: Some(1),
        available_ram_fraction: Some(0.55),
        ..incident()
    }
}

/// A Mac with 12 performance cores (a load limit of 12) at these numbers, as the
/// app's tracker tests read it: `pressure` is the macOS level (1, 2 or 4).
pub(crate) fn gray(load: f64, pressure: u32, ram: f64, swap: f64, budget: &Budget) -> Verdict {
    let sample = Sample {
        load1: Some(load),
        performance_cores: Some(12),
        physical_cores: Some(12),
        logical_cpus: 12,
        vm_pressure_level: Some(pressure),
        psi_some_avg10: None,
        available_ram_fraction: Some(ram),
        swapout_bytes: None,
    };
    evaluate("gray", &sample, Some(swap), budget)
}

#[test]
fn a_calm_host_is_within_budget() {
    let v = evaluate("cosmic-gray", &calm(), Some(0.0), &Budget::default());
    assert!(v.ok, "{:?}", v.over);
    assert_eq!(v.warning, None);
    assert_eq!((v.cores, v.cores_kind, v.load_limit), (15, "performance", 15.0));
}

#[test]
fn the_incident_is_over_on_every_count_and_says_so_in_one_line() {
    let v = evaluate("cosmic-gray", &incident(), Some(900.0), &Budget::default());
    assert!(!v.ok);
    assert_eq!(
        v.over,
        ["load1 146.3 >= 15 (15 P-cores)", "memory pressure warn", "swap +900 MB/min"]
    );
    assert_eq!(
        v.warning.as_deref(),
        Some(
            "host-budget: cosmic-gray over its CPU/RAM budget: load1 146.3 >= 15 (15 P-cores); \
             memory pressure warn; swap +900 MB/min"
        )
    );
}

#[test]
fn load_is_measured_against_performance_cores_then_physical_then_logical() {
    let at = |load: f64, s: Sample| {
        evaluate("h", &Sample { load1: Some(load), ..s }, None, &Budget::default())
    };
    // Under the P-core count, over at it.
    assert!(at(14.9, calm()).ok);
    assert!(!at(15.0, calm()).ok);
    // No perf levels (an Intel Mac): physical cores.
    let intel = Sample { performance_cores: None, physical_cores: Some(8), ..calm() };
    assert_eq!((at(7.0, intel.clone()).load_limit, at(7.0, intel).ok), (8.0, true));
    // Linux reports neither: the CPUs this process may use.
    let linux = Sample {
        performance_cores: None,
        physical_cores: None,
        logical_cpus: 32,
        vm_pressure_level: None,
        ..calm()
    };
    let v = at(31.0, linux);
    assert_eq!((v.cores, v.cores_kind, v.ok), (32, "logical", true));
    // `cores: logical` counts every CPU even with perf levels.
    let budget = parse_budget(Some(br#"{"formula": {"cores": "logical"}}"#), "h");
    let threads = Sample { logical_cpus: 18, ..calm() };
    assert_eq!(evaluate("h", &threads, None, &budget).cores, 18);
}

#[test]
fn memory_pressure_ram_and_swap_each_trip_it_alone() {
    let b = Budget::default();
    let warn = Sample { vm_pressure_level: Some(2), ..calm() };
    assert_eq!(evaluate("h", &warn, None, &b).over, ["memory pressure warn"]);
    // `pressure: warn` lets warn through but not critical.
    let lax = parse_budget(Some(br#"{"formula": {"pressure": "warn"}}"#), "h");
    assert!(evaluate("h", &warn, None, &lax).ok);
    let critical = Sample { vm_pressure_level: Some(4), ..calm() };
    assert_eq!(evaluate("h", &critical, None, &lax).over, ["memory pressure critical"]);
    // Linux PSI.
    let psi = |avg10| Sample { vm_pressure_level: None, psi_some_avg10: Some(avg10), ..calm() };
    assert!(evaluate("h", &psi(9.9), None, &b).ok);
    assert_eq!(evaluate("h", &psi(10.0), None, &b).pressure, "warn");
    // Available RAM.
    let low = Sample { available_ram_fraction: Some(0.07), ..calm() };
    assert_eq!(evaluate("h", &low, None, &b).over, ["available RAM 7% < 10%"]);
    // Swap: at the limit is fine, over it is not, unknown is not over.
    assert!(evaluate("h", &calm(), Some(64.0), &b).ok);
    assert_eq!(evaluate("h", &calm(), Some(65.0), &b).over, ["swap +65 MB/min"]);
    assert!(evaluate("h", &calm(), None, &b).ok);
}

#[test]
fn the_file_overrides_defaults_then_the_host_entry_overrides_the_file() {
    let file = br#"{
        "enforce": true,
        "formula": {"load1_per_core": 1.5, "swap_growth_mb_per_min": 128},
        "hosts": {"cosmic-gray": {"load1_per_core": 0.5}, "huge-blue": {"load1_per_core": 3}}
    }"#;
    let b = parse_budget(Some(file), "cosmic-gray");
    assert!(b.enforce);
    assert_eq!(b.formula.load1_per_core, 0.5);
    assert_eq!(b.formula.swap_growth_mb_per_min, 128.0);
    assert_eq!(b.formula.sample_seconds, 3.0);
    assert_eq!(evaluate("cosmic-gray", &calm(), None, &b).load_limit, 7.5);
    assert_eq!(parse_budget(Some(file), "air-blue").formula.load1_per_core, 1.5);
}

#[test]
fn bad_values_and_bad_files_keep_the_defaults() {
    let b = parse_budget(
        Some(br#"{"formula": {"load1_per_core": -1, "min_available_ram_fraction": 2, "cores": "all", "sample_seconds": "3"}}"#),
        "h",
    );
    assert_eq!(b.formula, Formula::default());
    assert_eq!(parse_budget(Some(b"{not json"), "h"), Budget::default());
    assert_eq!(parse_budget(None, "h"), Budget::default());
}

#[test]
fn the_override_file_must_be_a_small_regular_file() {
    let dir = std::env::temp_dir().join(format!("acpmux-host-budget-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let small = dir.join("small.json");
    std::fs::write(&small, br#"{"formula": {"load1_per_core": 2}}"#).unwrap();
    assert!(read_override(&small).is_some());
    let big = dir.join("big.json");
    std::fs::write(&big, vec![b' '; 70 << 10]).unwrap();
    assert_eq!(read_override(&big), None);
    assert_eq!(read_override(&dir), None);
    assert_eq!(read_override(&dir.join("missing.json")), None);
    #[cfg(unix)]
    {
        // A FIFO with no writer would block a plain open forever: it is opened without
        // blocking and refused because the opened handle is not a regular file.
        let fifo = dir.join("fifo.json");
        let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: a NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        assert_eq!(read_override(&fifo), None);
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn performance_cores_are_every_level_but_efficiency() {
    let levels =
        |l: &[(&str, u32)]| l.iter().map(|(n, c)| ((*n).to_owned(), *c)).collect::<Vec<_>>();
    // cosmic-gray, an M5 Pro: 5 Super + 10 Performance.
    assert_eq!(performance_cores(&levels(&[("Super", 5), ("Performance", 10)])), Some(15));
    // air-blue, an M5: 4 Super + 6 Efficiency.
    assert_eq!(performance_cores(&levels(&[("Super", 4), ("Efficiency", 6)])), Some(4));
    // cmux16, an M6: 2 Super + 4 Performance + 6 Efficiency.
    let m6 = levels(&[("Super", 2), ("Performance", 4), ("Efficiency", 6)]);
    assert_eq!(performance_cores(&m6), Some(6));
    // M1 to M4.
    assert_eq!(performance_cores(&levels(&[("Performance", 8), ("Efficiency", 4)])), Some(8));
    assert_eq!(performance_cores(&levels(&[("Efficiency", 4)])), None);
    assert_eq!(performance_cores(&[]), None);
}

#[test]
fn linux_proc_files_parse() {
    assert_eq!(parse_loadavg("23.41 21.65 17.77 3/1201 4242\n"), Some(23.41));
    let psi = "some avg10=12.50 avg60=3.10 avg300=0.80 total=123456\nfull avg10=1.00 avg60=0.20 avg300=0.05 total=2345\n";
    assert_eq!(parse_psi_some_avg10(psi), Some(12.5));
    let meminfo =
        "MemTotal:       65536000 kB\nMemFree:         1000000 kB\nMemAvailable:   16384000 kB\n";
    assert_eq!(parse_meminfo_available(meminfo), Some(0.25));
    assert_eq!(parse_meminfo_available("MemFree: 1 kB\n"), None);
    assert_eq!(parse_vmstat_pswpout("pswpin 10\npswpout 4096\n"), Some(4096));
}

#[test]
fn the_load_sample_proc_files_parse() {
    let psi = "some avg10=12.50 avg60=3.10 avg300=0.80 total=123456\nfull avg10=1.00 avg60=0.20 avg300=0.05 total=2345\n";
    assert_eq!(parse_psi_avg60(psi, "some"), Some(3.1));
    assert_eq!(parse_psi_avg60(psi, "full"), Some(0.2));
    // /proc/pressure/cpu has a `full` line of zeros on newer kernels and none on older ones.
    let cpu = "some avg10=0.00 avg60=42.75 avg300=0.00 total=0\n";
    assert_eq!(parse_psi_avg60(cpu, "some"), Some(42.75));
    assert_eq!(parse_psi_avg60(cpu, "full"), None);
    assert_eq!(parse_vmstat_oom_kill("pgfault 1\noom_kill 3\n"), Some(3));
    assert_eq!(parse_vmstat_oom_kill("pgfault 1\n"), None);
    let meminfo = "MemTotal: 8000 kB\nSwapTotal:       4000 kB\nSwapFree:        1000 kB\n";
    assert_eq!(parse_meminfo_swap_used(meminfo), Some(0.75));
    assert_eq!(parse_meminfo_swap_used("SwapTotal: 0 kB\nSwapFree: 0 kB\n"), None);
    let before = "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 100 0 50 800 50 0 0 0 0 0\nintr 1\n";
    let after = "cpu  250 0 100 900 50 0 0 0 0 0\ncpu0 250 0 100 900 50 0 0 0 0 0\nintr 2\n";
    let (a, b) = (parse_proc_stat_cpu(before).unwrap(), parse_proc_stat_cpu(after).unwrap());
    assert_eq!((a, b), ((1000, 850), (1300, 950)));
    // 300 jiffies passed, 100 of them idle.
    assert!((cpu_busy(a, b).unwrap() - 2.0 / 3.0).abs() < 1e-9);
    assert_eq!(cpu_busy(a, a), None, "no time passed");
    assert_eq!(parse_proc_stat_cpu("cpu0 1 2 3 4\n"), None);
}

#[test]
fn the_verdict_carries_the_contract_keys() {
    let v =
        serde_json::to_value(evaluate("h", &incident(), Some(100.0), &Budget::default())).unwrap();
    let mut keys: Vec<_> = v.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "available_ram_fraction",
            "cores",
            "cores_kind",
            "enforce",
            "formula",
            "host",
            "load1",
            "load_limit",
            "ok",
            "over",
            "pressure",
            "swap_mb_per_min",
            "warning"
        ]
    );
    let mut formula: Vec<_> =
        v["formula"].as_object().unwrap().keys().map(String::as_str).collect();
    formula.sort_unstable();
    assert_eq!(
        formula,
        [
            "cores",
            "load1_per_core",
            "min_available_ram_fraction",
            "pressure",
            "psi_some_avg10",
            "sample_seconds",
            "swap_growth_mb_per_min"
        ]
    );
}
