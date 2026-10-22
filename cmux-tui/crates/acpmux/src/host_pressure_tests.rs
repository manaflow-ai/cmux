use super::*;
use std::sync::Arc;

/// cosmic-gray at 23:10 PDT on 2026-10-21 (cmuxterm-hq#2995), read the way the probe reads it.
fn incident() -> Sample {
    Sample {
        load1: Some(146.3),
        performance_cores: Some(10),
        physical_cores: Some(15),
        logical_cpus: 15,
        vm_pressure_level: Some(2),
        psi_some_avg10: None,
        available_ram_fraction: Some(0.34),
        swapout_bytes: Some(40 << 30),
    }
}

/// The same Mac running a normal lane load.
fn calm() -> Sample {
    Sample {
        load1: Some(6.2),
        vm_pressure_level: Some(1),
        available_ram_fraction: Some(0.55),
        ..incident()
    }
}

#[test]
fn a_calm_host_is_within_budget() {
    let v = evaluate("cosmic-gray", &calm(), Some(0.0), &Budget::default());
    assert!(v.ok, "{:?}", v.over);
    assert_eq!(v.warning, None);
    assert_eq!((v.cores, v.cores_kind, v.load_limit), (10, "performance", 10.0));
}

#[test]
fn the_incident_is_over_on_every_count_and_says_so_in_one_line() {
    let v = evaluate("cosmic-gray", &incident(), Some(900.0), &Budget::default());
    assert!(!v.ok);
    assert_eq!(
        v.over,
        ["load1 146.3 >= 10 (10 P-cores)", "memory pressure warn", "swap +900 MB/min"]
    );
    assert_eq!(
        v.warning.as_deref(),
        Some(
            "host-budget: cosmic-gray over its CPU/RAM budget: load1 146.3 >= 10 (10 P-cores); \
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
    assert!(at(9.9, calm()).ok);
    assert!(!at(10.0, calm()).ok);
    // No perf levels (an Intel Mac): physical cores.
    let intel = Sample { performance_cores: None, ..calm() };
    assert_eq!((at(14.0, intel.clone()).load_limit, at(14.0, intel).ok), (15.0, true));
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
    assert_eq!(evaluate("h", &calm(), None, &budget).cores, 15);
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
        "hosts": {"cosmic-gray": {"load1_per_core": 0.8}, "huge-blue": {"load1_per_core": 3}}
    }"#;
    let b = parse_budget(Some(file), "cosmic-gray");
    assert!(b.enforce);
    assert_eq!(b.formula.load1_per_core, 0.8);
    assert_eq!(b.formula.swap_growth_mb_per_min, 128.0);
    assert_eq!(b.formula.sample_seconds, 3.0);
    assert_eq!(evaluate("cosmic-gray", &calm(), None, &b).load_limit, 8.0);
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

/// A probe whose readings a test changes between samples, and counts.
#[derive(Default)]
struct FakeProbe {
    sample: Mutex<Sample>,
    reads: Mutex<u32>,
}

impl Probe for Arc<FakeProbe> {
    fn sample(&self) -> Sample {
        *self.reads.lock().unwrap() += 1;
        self.sample.lock().unwrap().clone()
    }
}

fn defaults(_host: &str) -> Budget {
    Budget::default()
}

fn meter(probe: &Arc<FakeProbe>) -> Meter {
    Meter::new("h".into(), Box::new(probe.clone()), Box::new(defaults))
}

#[test]
fn the_meter_samples_at_most_once_per_sample_seconds() {
    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = calm();
    let m = meter(&probe);
    let t0 = Instant::now();
    m.verdict_at(t0);
    m.verdict_at(t0 + Duration::from_millis(2_900));
    assert_eq!(*probe.reads.lock().unwrap(), 1);
    m.verdict_at(t0 + Duration::from_secs(3));
    assert_eq!(*probe.reads.lock().unwrap(), 2);
}

#[test]
fn swap_growth_is_the_rate_between_two_samples() {
    let probe = Arc::new(FakeProbe::default());
    let set_swap = |bytes: u64| {
        *probe.sample.lock().unwrap() = Sample { swapout_bytes: Some(bytes), ..calm() }
    };
    let m = meter(&probe);
    let t0 = Instant::now();
    set_swap(1 << 30);
    // One sample has no rate yet.
    assert_eq!(m.verdict_at(t0).swap_mb_per_min, None);
    // 100 MiB in 30 s is 200 MB/min: over.
    set_swap((1 << 30) + (100 << 20));
    let v = m.verdict_at(t0 + Duration::from_secs(30));
    assert_eq!((v.swap_mb_per_min, v.ok), (Some(200.0), false));
    // Then flat: back within budget.
    let v = m.verdict_at(t0 + Duration::from_secs(60));
    assert_eq!((v.swap_mb_per_min, v.ok), (Some(0.0), true));
    // A baseline older than the window gives no rate, and starts a new one.
    set_swap(5 << 30);
    assert_eq!(m.verdict_at(t0 + Duration::from_secs(60 + 601)).swap_mb_per_min, None);
    assert_eq!(m.verdict_at(t0 + Duration::from_secs(60 + 661)).swap_mb_per_min, Some(0.0));
}
