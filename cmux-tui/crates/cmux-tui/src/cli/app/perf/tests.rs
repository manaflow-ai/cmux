use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

use serde_json::json;

use super::compare::{self, Trend, Verdict};
use super::host::{self, Sample};
use super::profile::{self, Probe};
use super::report::{Better, Metric, Report, SCHEMA};
use super::{Command, ProfileArgs, SimArgs, ab, sim, stats};

fn words(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

#[test]
fn percentile_is_nearest_rank() {
    let sorted: Vec<f64> = (1..=100).map(f64::from).collect();
    assert_eq!(stats::percentile(&sorted, 50.0), Some(50.0));
    assert_eq!(stats::percentile(&sorted, 95.0), Some(95.0));
    assert_eq!(stats::percentile(&sorted, 99.0), Some(99.0));
    assert_eq!(stats::percentile(&sorted, 0.0), Some(1.0));
    assert_eq!(stats::percentile(&[], 50.0), None);
    assert_eq!(stats::percentile(&[7.0], 99.0), Some(7.0));
}

#[test]
fn summarize_counts_values_over_the_budget_and_drops_non_finite() {
    let summary = stats::summarize(&[4.0, 9.0, 8.0, f64::NAN, 20.0], 8.33).unwrap();
    assert_eq!(summary.count, 4);
    assert_eq!(summary.over, 2);
    assert_eq!(summary.max, 20.0);
    assert_eq!(summary.p50, 8.0);
    assert_eq!(summary.over_pct(), 50.0);
    assert_eq!(summary.total, 41.0);
    assert!(stats::summarize(&[], 1.0).is_none());
}

fn sample(at: f64, cpu: &[(i32, f64)], rss_kb: u64, disk: &[(i32, (u64, u64))]) -> Sample {
    Sample {
        at,
        cpu_s: cpu.iter().copied().collect(),
        rss_kb,
        footprint: None,
        disk: disk.iter().copied().collect(),
        gpu_pct: None,
        processes: cpu.len(),
    }
}

#[test]
fn growth_counts_new_pids_in_full_and_ended_ones_not_at_all() {
    let before: HashMap<i32, f64> = [(1, 10.0), (2, 5.0)].into_iter().collect();
    let now: HashMap<i32, f64> = [(1, 11.0), (3, 0.5)].into_iter().collect();
    assert_eq!(host::growth(&before, &now), 1.5);
}

#[test]
fn host_summary_has_cpu_percent_memory_peak_and_disk() {
    let mb = 1024 * 1024;
    let samples = vec![
        sample(0.0, &[(1, 10.0)], 1024, &[(1, (0, 0))]),
        sample(1.0, &[(1, 10.5)], 4096, &[(1, (mb, 2 * mb))]),
        sample(2.0, &[(1, 11.5), (2, 0.5)], 2048, &[(1, (2 * mb, 2 * mb))]),
    ];
    let summary = host::summarize(&samples);
    assert_eq!(summary.cpu_avg_pct, Some(100.0));
    assert_eq!(summary.cpu_peak_pct, Some(150.0));
    assert_eq!(summary.rss_peak_mb, Some(4.0));
    assert_eq!(summary.disk_read_mb, Some(2.0));
    assert_eq!(summary.disk_write_mb, Some(2.0));
    assert_eq!(summary.processes_peak, Some(2.0));
    assert_eq!(summary.gpu_avg_pct, None);
    assert_eq!(host::summarize(&[]), host::HostSummary::default());
}

#[test]
fn gpu_utilization_takes_the_busiest_device() {
    let text = r#"| "PerformanceStatistics" = {"Device Utilization %"=12,"Renderer Utilization %"=10}
| "PerformanceStatistics" = {"Device Utilization %"=47}"#;
    assert_eq!(host::parse_gpu(text), Some(47.0));
    assert_eq!(host::parse_gpu("nothing"), None);
}

fn metric(key: &str, value: Option<f64>, budget: Option<f64>, better: Better) -> Metric {
    let mut metric = Metric::new(key, "frames", key, "ms", "debug.frames").value(value);
    metric.budget = budget;
    metric.better = better;
    metric
}

#[test]
fn trend_ignores_noise_and_respects_direction() {
    assert_eq!(compare::trend(Better::Lower, 10.0, 10.3), Trend::Same);
    assert_eq!(compare::trend(Better::Lower, 10.0, 8.0), Trend::Better);
    assert_eq!(compare::trend(Better::Lower, 10.0, 12.0), Trend::Worse);
    assert_eq!(compare::trend(Better::Higher, 100.0, 200.0), Trend::Better);
    assert_eq!(compare::trend(Better::Lower, 0.0, 0.005), Trend::Same);
}

#[test]
fn verdicts_against_the_budget() {
    let row = |b: Option<f64>, a: Option<f64>, budget: Option<f64>| {
        compare::row(
            Some(&metric("k", b, budget, Better::Lower)),
            Some(&metric("k", a, budget, Better::Lower)),
        )
        .unwrap()
        .verdict
    };
    assert_eq!(row(Some(12.0), Some(7.0), Some(8.33)), Verdict::Fixed);
    assert_eq!(row(Some(7.0), Some(12.0), Some(8.33)), Verdict::Broke);
    assert_eq!(row(Some(5.0), Some(6.0), Some(8.33)), Verdict::Within);
    assert_eq!(row(Some(20.0), Some(30.0), Some(8.33)), Verdict::Over);
    assert_eq!(row(Some(20.0), Some(10.0), None), Verdict::Better);
    assert_eq!(row(Some(10.0), Some(20.0), None), Verdict::Worse);
    assert_eq!(row(Some(10.0), Some(10.0), None), Verdict::Same);
    assert_eq!(row(None, Some(10.0), Some(8.33)), Verdict::Unmeasured);
    let r = compare::row(
        Some(&metric("k", Some(10.0), None, Better::Lower)),
        Some(&metric("k", Some(5.0), None, Better::Lower)),
    )
    .unwrap();
    assert_eq!(r.delta, Some(-5.0));
    assert_eq!(r.change_pct, Some(-50.0));
}

fn report(label: &str, metrics: Vec<Metric>) -> Report {
    Report {
        schema: SCHEMA.into(),
        label: Some(label.into()),
        created_unix: 1,
        seconds: 10,
        app: json!({ "pid": 1, "bundle_id": "x" }),
        sources: BTreeMap::new(),
        metrics,
        details: json!({}),
        notes: vec![],
    }
}

#[test]
fn compare_keeps_rows_from_either_report() {
    let before = report(
        "a",
        vec![
            metric("only.before", Some(1.0), None, Better::Lower),
            metric("both", Some(10.0), Some(8.33), Better::Lower),
        ],
    );
    let after = report(
        "b",
        vec![
            metric("both", Some(5.0), Some(8.33), Better::Lower),
            metric("only.after", Some(2.0), None, Better::Lower),
        ],
    );
    let rows = compare::compare(&before, &after);
    let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    assert_eq!(keys, vec!["both", "only.after", "only.before"]);
    assert_eq!(rows[0].verdict, Verdict::Fixed);
    assert_eq!(rows[1].verdict, Verdict::Unmeasured);
    let text = compare::human(&before, &after, &rows);
    assert!(text.contains("both"));
}

#[test]
fn report_round_trips_through_json_and_load_checks_the_schema() {
    let original =
        report("x", vec![metric("frames.p95_ms", Some(9.123_456), Some(8.33), Better::Lower)]);
    assert_eq!(original.metrics[0].value, Some(9.123));
    let text = serde_json::to_string(&original).unwrap();
    let back: Report = serde_json::from_str(&text).unwrap();
    assert_eq!(back, original);
    let dir = std::env::temp_dir().join(format!("cmux-perf-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let good = dir.join("good.json");
    std::fs::write(&good, &text).unwrap();
    assert_eq!(compare::load(&good).unwrap(), original);
    let bad = dir.join("bad.json");
    std::fs::write(&bad, r#"{"schema":"other"}"#).unwrap();
    assert!(compare::load(&bad).is_err());
    assert!(compare::load(&dir.join("missing.json")).is_err());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn frame_metrics_prefer_raw_intervals() {
    let mut intervals = vec![8.0; 98];
    intervals.extend([20.0, 40.0]);
    let raw = json!({ "frames": 3, "p95_ms": 99.0, "intervals_ms": intervals, "main_ms": [1.0, 2.0, 3.0] });
    let metrics = profile::frame_metrics(Some(&raw));
    let get = |key: &str| metrics.iter().find(|m| m.key == key).unwrap().value;
    assert_eq!(get("frames.count"), Some(100.0));
    assert_eq!(get("frames.p95_ms"), Some(8.0));
    assert_eq!(get("frames.longest_ms"), Some(40.0));
    assert_eq!(get("frames.over_budget_pct"), Some(2.0));
    assert_eq!(get("frames.main_p95_ms"), Some(3.0));
    let reported = json!({ "frames": 3, "p95_ms": 11.0, "max_ms": 12.0 });
    let metrics = profile::frame_metrics(Some(&reported));
    let get = |key: &str| metrics.iter().find(|m| m.key == key).unwrap().value;
    assert_eq!(get("frames.p95_ms"), Some(11.0));
    assert_eq!(get("frames.over_budget_pct"), None);
    assert!(profile::frame_metrics(None).iter().all(|m| m.value.is_none()));
}

#[test]
fn stall_metrics_use_main_minus_ping() {
    let probes = vec![
        Probe { ping_ms: 1.0, main_ms: Some(2.0) },
        Probe { ping_ms: 1.0, main_ms: Some(81.0) },
        Probe { ping_ms: 1.0, main_ms: None },
    ];
    assert_eq!(probes[0].queue_ms(), Some(1.0));
    let hangs = json!({ "records": [{ "duration_ms": 120.0, "kind": "a" }, { "duration_ms": 60.0, "kind": "a" }] });
    let metrics = profile::stall_metrics(&probes, Some(&hangs));
    let get = |key: &str| metrics.iter().find(|m| m.key == key).unwrap().value;
    assert_eq!(get("probe.stalls"), Some(1.0));
    assert_eq!(get("probe.longest_ms"), Some(80.0));
    assert_eq!(get("stalls.count"), Some(2.0));
    assert_eq!(get("stalls.total_ms"), Some(180.0));
    assert_eq!(get("stalls.longest_ms"), Some(120.0));
    let release = profile::stall_metrics(&probes, None);
    assert_eq!(release.iter().find(|m| m.key == "stalls.count").unwrap().value, None);
    let attributions = profile::stall_attributions(&hangs);
    assert_eq!(attributions["by_kind"][0]["count"], 2);
    assert_eq!(attributions["longest"][0]["duration_ms"], 120.0);
}

#[test]
fn hang_file_header_and_main_thread_frames() {
    let text = "cmux hang\nduration: 2.345 s\nstate: blocked\nmain thread (innermost first):\n  0  mach_msg2_trap\n  1  CFRunLoopRun\n\nother thread:\n  0  x\n";
    let hang = profile::parse_hang_file(text).unwrap();
    assert_eq!(hang.duration_ms, 2345.0);
    assert!(hang.ongoing);
    assert_eq!(hang.frames, vec!["mach_msg2_trap", "CFRunLoopRun"]);
    assert!(profile::parse_hang_file("no duration").is_none());
    let recovered = profile::parse_hang_file("duration: 3 s\nstate: recovered\n").unwrap();
    assert!(!recovered.ongoing);
}

#[test]
fn visible_chat_tabs_are_selected_conversations_in_shown_workspaces() {
    let snapshot = json!({ "topology": {
        "windows": [{ "workspace": "w1" }],
        "workspaces": [
            { "id": "w1", "screens": [{ "panes": [
                { "tabs": [{ "id": "c1", "kind": "conversation", "selected": true }, { "id": "c2", "kind": "conversation", "selected": false }] },
                { "tabs": [{ "id": "t1", "kind": "terminal", "selected": true }] },
                { "tabs": [{ "id": "pending_1", "kind": "conversation", "selected": true }] },
            ] }] },
            { "id": "w2", "screens": [{ "panes": [{ "tabs": [{ "id": "c3", "kind": "conversation", "selected": true }] }] }] },
        ],
    } });
    assert_eq!(profile::visible_chat_tabs(&snapshot), vec!["c1"]);
}

#[test]
fn counter_delta_and_switch_times() {
    let delta =
        profile::counter_delta(&json!({ "a": 10, "b": 1 }), &json!({ "a": 15, "c": 2, "s": "x" }));
    assert_eq!(delta["a"], 5.0);
    assert_eq!(delta["c"], 2.0);
    assert!(!delta.contains_key("s"));
    let switches = json!({ "switches": [{ "apply_ms": 1.0, "commit_ms": 2.0, "commit_end_ms": 3.0 }, { "apply_ms": 4.0 }] });
    assert_eq!(profile::switch_times(Some(&switches)), vec![3.0, 4.0]);
    assert!(profile::switch_times(None).is_empty());
}

#[test]
fn responsiveness_composer_is_always_unmeasured() {
    let interactions = vec![
        profile::Interaction { element: "tab", ms: 5.0, ok: true },
        profile::Interaction { element: "tab", ms: 500.0, ok: false },
    ];
    let metrics = profile::responsiveness_metrics(&interactions, None, None);
    let get = |key: &str| metrics.iter().find(|m| m.key == key).unwrap().value;
    assert_eq!(get("resp.tab_switch_rtt_ms"), Some(5.0));
    assert_eq!(get("resp.composer_typing_ms"), None);
    assert_eq!(get("resp.tab_switch_ms"), None);
}

#[test]
fn perf_parse_accepts_each_verb() {
    assert_eq!(
        super::parse(&words(&["profile", "--seconds", "5", "--out", "a.json", "--probe"])).unwrap(),
        Command::Profile(ProfileArgs {
            seconds: 5,
            out: Some(PathBuf::from("a.json")),
            label: None,
            probe: true
        })
    );
    assert_eq!(
        super::parse(&words(&["compare", "a.json", "b.json"])).unwrap(),
        Command::Compare { before: "a.json".into(), after: "b.json".into() }
    );
    let Command::Ab(ab) = super::parse(&words(&["ab", "--patch", "abc123", "--rollback"])).unwrap()
    else {
        panic!()
    };
    assert_eq!(ab.patch, "abc123");
    assert!(ab.rollback);
    assert_eq!(ab.seconds, super::DEFAULT_PROFILE_SECONDS);
    assert_eq!(
        super::parse(&words(&["sim", "--profile", "unreasonable", "--events", "10000"])).unwrap(),
        Command::Sim(SimArgs {
            profile: "unreasonable".into(),
            seconds: super::DEFAULT_SIM_SECONDS,
            events: Some(10_000),
            shape: None,
            scale: 1,
        })
    );
}

#[test]
fn perf_parse_refuses_bad_input() {
    for bad in [
        &["profile", "--seconds", "0"][..],
        &["profile", "--seconds", "601"],
        &["profile", "extra"],
        &["compare", "a.json"],
        &["compare", "a", "b", "c"],
        &["ab"],
        &["ab", "--patch", ""],
        &["sim", "--profile", "nope-not-a-profile"],
        &["sim", "--events", "0"],
        &["sim", "--events", "2000000"],
        &["sim", "--scale", "0"],
        &["sim", "--scale", "101"],
        &["bogus"],
        &[],
    ] {
        assert!(super::parse(&words(bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn builtin_shapes_parse_and_both_profiles_are_known() {
    let mut names = sim::builtin_profiles();
    names.sort();
    assert_eq!(names, vec!["cosmic-gray", "unreasonable"]);
    for name in &names {
        assert!(sim::is_known_profile(name));
        let shape = sim::load_shape(&SimArgs {
            profile: name.clone(),
            seconds: 1,
            events: None,
            shape: None,
            scale: 1,
        });
        let (shape, _) = shape.unwrap();
        assert_eq!(shape.burst_lines, 10_000);
        assert!(shape.workspaces > 0 && !shape.churn.is_empty());
        assert!(shape.busy_command.contains("{sleep}"));
        assert!(shape.agent_command.contains("{name}"));
        assert!(shape.burst_command.contains("{lines}"));
    }
    assert!(!sim::is_known_profile("../etc"));
}

#[test]
fn bare_shape_files_fill_defaults() {
    let shape = sim::parse_shape(r#"{"workspaces": 2}"#, "any").unwrap();
    assert_eq!(shape.workspaces, 2);
    assert_eq!(shape.busy_terminals, sim::Shape::default().busy_terminals);
    assert!(sim::parse_shape(r#"{"profiles": {"a": {}}}"#, "b").is_none());
    assert!(sim::parse_shape("not json", "a").is_none());
}

#[test]
fn burst_lines_split_evenly() {
    assert_eq!(sim::burst_split(10_000, 3), vec![3334, 3333, 3333]);
    assert_eq!(sim::burst_split(10_000, 3).iter().sum::<u64>(), 10_000);
    assert_eq!(sim::burst_split(2, 5), vec![1, 1]);
    assert!(sim::burst_split(10, 0).is_empty());
}

#[test]
fn roles_are_busy_then_agents_then_idle() {
    let shape = sim::Shape { busy_terminals: 2, agents: 1, ..sim::Shape::default() };
    assert_eq!(
        sim::roles(&shape, 4),
        vec![sim::Role::Busy, sim::Role::Busy, sim::Role::Agent(1), sim::Role::Idle]
    );
    assert_eq!(
        sim::command("{name} {sleep}", &[("name", "a".into()), ("sleep", "0.1".into())]),
        "a 0.1"
    );
}

#[test]
fn sim_panes_skip_docks() {
    let topology = json!({ "workspaces": [{ "id": "w", "screens": [{ "panes": [
        { "id": "p1", "tabs": [{ "id": "t1", "kind": "terminal" }] },
        { "id": "d", "dock": true, "tabs": [] },
    ] }] }] });
    let panes = sim::panes(&topology, "w");
    assert_eq!(panes.len(), 1);
    assert_eq!(panes[0].0, "p1");
    assert_eq!(panes[0].1, vec![("t1".to_owned(), "terminal".to_owned())]);
    assert!(sim::panes(&topology, "other").is_empty());
}

#[test]
fn ab_plan_and_repo() {
    let plan = ab::parse_plan("progress\n{\"sha\":\"x\",\"parts\":[\"web\",\"rust\"],\"left\":{\"swift\":[\"Foo.swift signature\"]}}\n").unwrap();
    assert_eq!(plan.parts, vec!["web", "rust"]);
    assert_eq!(plan.left, vec![("swift".to_owned(), "Foo.swift signature".to_owned())]);
    assert!(ab::parse_plan("no json").is_none());
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo = ab::find_repo(&here).expect("this crate lives in a cmux checkout");
    assert!(repo.join("scripts/cmux-next/hot-apply.py").is_file());
}

const COSMIC_GRAY_CAPTURE: &str = include_str!("captures/cosmic-gray-2026-11-21.json");

#[test]
fn the_cosmic_gray_capture_is_read_as_captured() {
    let raw: serde_json::Value = serde_json::from_str(COSMIC_GRAY_CAPTURE).unwrap();
    assert_eq!(raw["schema"], sim::CAPTURE_SCHEMA);
    let shape = sim::parse_shape(COSMIC_GRAY_CAPTURE, "cosmic-gray").unwrap();
    assert_eq!(shape.workspaces, 213);
    assert_eq!(shape.panes_per_workspace.len(), 213);
    let listed: Vec<usize> = raw["panes_per_workspace"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_u64().unwrap() as usize)
        .collect();
    assert_eq!(shape.panes_per_workspace, listed);
    assert_eq!(shape.busy_terminals, 0);
    assert_eq!(shape.agents, 40, "streaming chats run as fake agent terminals");
    assert_eq!(shape.browsers, 16);
    assert_eq!(shape.burst_lines, 10_000);
    // A workspace the capture lists with no pane still gets the one it opens with.
    assert_eq!(sim::panes_in(&shape, 207), 1);
    assert_eq!(sim::panes_in(&shape, 122), 3);
    // The built-in cosmic-gray profile is that capture.
    let builtin = sim::load_shape(&SimArgs {
        profile: "cosmic-gray".into(),
        seconds: 1,
        events: None,
        shape: None,
        scale: 1,
    })
    .unwrap()
    .0;
    assert_eq!(builtin.workspaces, shape.workspaces);
    assert_eq!(builtin.panes_per_workspace, shape.panes_per_workspace);
    assert_eq!((builtin.busy_terminals, builtin.agents, builtin.browsers), (0, 40, 16));
}

#[test]
fn scale_and_unreasonable_multiply_the_capture() {
    let load = |profile: &str, scale: usize| {
        sim::load_shape(&SimArgs {
            profile: profile.into(),
            seconds: 1,
            events: None,
            shape: None,
            scale,
        })
        .unwrap()
        .0
    };
    let tripled = load("cosmic-gray", 3);
    assert_eq!(tripled.workspaces, 639);
    assert_eq!(tripled.panes_per_workspace.len(), 639);
    assert_eq!((tripled.agents, tripled.browsers), (120, 48));
    assert_eq!(tripled.burst_lines, 10_000, "the burst stays 10,000 events at once");
    let unreasonable = load("unreasonable", 1);
    assert_eq!(unreasonable.workspaces, 213 * 4);
    assert_eq!(unreasonable.busy_terminals, 32);
    assert_eq!((unreasonable.agents, unreasonable.browsers), (160, 64));
    assert_eq!((unreasonable.burst_lines, unreasonable.burst_every_s), (10_000, 5));
    assert_eq!(load("unreasonable", 2).workspaces, 213 * 8);
    let parsed = super::parse(&words(&["sim", "--scale", "5"])).unwrap();
    assert!(matches!(parsed, Command::Sim(SimArgs { scale: 5, .. })));
}
