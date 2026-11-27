use super::*;
use std::io::Write;

fn run_dir(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("coord-sim-metrics-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    for (f, s) in files {
        std::fs::write(d.join(f), s).unwrap();
    }
    d
}

fn event(
    c: u32,
    seq: u64,
    src: &str,
    emit_us: u64,
    daemon_n: u64,
    reader_us: Option<u64>,
    reader_n: u64,
) -> String {
    let daemon_at = if daemon_n > 0 { json!(emit_us / 1000 + 2) } else { Value::Null };
    json!({"c": c, "seq": seq, "k": 0, "kind": "in:agent_message_chunk", "update": if src == "agent" { "agent_message_chunk" } else { src },
        "src": src, "bytes": 100, "due_us": emit_us - 500, "emit_us": emit_us, "daemon_at_ms": daemon_at,
        "daemon_n": daemon_n, "reader_us": reader_us, "reader_n": reader_n})
    .to_string()
        + "\n"
}

#[test]
fn hist_quantiles_are_within_one_percent() {
    let mut h = LogHist::default();
    for v in 1..=1000 {
        h.add(v as f64);
    }
    for (q, want) in [(0.5, 500.0), (0.95, 950.0), (0.99, 990.0)] {
        let got = h.quantile(q).unwrap();
        assert!((got - want).abs() / want < 0.01, "q{q}: {got} vs {want}");
    }
    assert!(h.quantile(1.0).unwrap() <= 1000.0);
    assert!(LogHist::default().quantile(0.5).is_none());
    let mut z = LogHist::default();
    z.add(0.0);
    assert_eq!(z.quantile(0.5), Some(0.0));
}

#[test]
fn slope_of_a_line() {
    let mut s = Slope::default();
    for m in 0..10 {
        s.add(1.7e9 + m as f64, 100.0 + 3.0 * m as f64);
    }
    assert!((s.slope().unwrap() - 3.0).abs() < 1e-6);
}

/// The shape of the first real driver runs (c3-r10, c20-r10 at f1318b58466): CPU in cpu.ndjson, not proc.ndjson;
/// RSS climbing while the chats load and then flat; a run cut off before the followers drained (each
/// coordinator's last events unseen) with one real gap; sends a follower saw that the store had not recorded.
#[test]
fn report_from_a_cut_off_run_with_cpu_ndjson() {
    let run = r#"{"schema":"coord-sim-drive.v1","coordinators":2,"rate":10,"readers":4,"run_s":15,"daemon_cpu_s":30.0,"daemon_wall_s":12.0,"sessions":["s0","s1"]}"#;
    let base = 1_795_093_875_000_000u64;
    let mut ev = String::new();
    for c in 0..2u32 {
        for seq in 1..=100u64 {
            let emit = base + seq * 10_000;
            let seen = seq <= 80 && !(c == 0 && seq == 10);
            ev.push_str(&if seen {
                event(c, seq, "agent", emit, 1, Some(emit + 1000), 1)
            } else {
                event(c, seq, "agent", emit, 1, None, 0)
            });
        }
        ev.push_str(&event(c, 200, "send", base + 2_000_000, 0, Some(base + 2_010_000), 20));
    }
    let mut procs = String::new();
    let mut cpu = String::new();
    for i in 0..=40u64 {
        // 4 samples a second for 10 s: +100 MB over the first 5 s, then flat at 200 MB
        let mb = if i < 20 { 100 + i * 5 } else { 200 };
        procs.push_str(&format!("{{\"ok\":true,\"peak_rss_kb\":{},\"queued_bytes\":{},\"role\":\"daemon\",\"rss_kb\":{},\"status_ms\":{},\"t_us\":{}}}\n", mb * 1024, i * 1000, mb * 1024, i, base + i * 250_000));
        cpu.push_str(&format!(
            "{{\"t_ns\":{},\"cpu_pct\":{}}}\n",
            (base + i * 250_000) * 1000,
            if i % 2 == 0 { 100.0 } else { 300.0 }
        ));
    }
    let d = run_dir(
        "cut-off",
        &[("run.json", run), ("events.ndjson", &ev), ("proc.ndjson", &procs), ("cpu.ndjson", &cpu)],
    );
    let r = report(&d).unwrap();
    let e = &r["events"];
    assert_eq!(e["unseen_by_readers"], 41);
    assert_eq!((e["unseen_gap"].as_u64(), e["unseen_tail"].as_u64()), (Some(1), Some(40)));
    assert_eq!(
        (e["never_stored_but_seen"].as_u64(), e["never_stored_unseen"].as_u64()),
        (Some(2), Some(0))
    );
    // the second half is flat: no leak, though the whole run climbed 100 MB in 10 s
    let steady = r["daemon"]["rss_slope_mb_per_min"].as_f64().unwrap();
    assert!(steady.abs() < 0.01, "{steady}");
    assert!(r["daemon"]["rss_slope_whole_run_mb_per_min"].as_f64().unwrap() > 100.0);
    assert_eq!(r["daemon"]["cpu_source"], "cpu.ndjson");
    assert_eq!(r["daemon"]["cpu_pct"]["n"], 41);
    assert!((r["per_chat"]["cpu_pct"]["max"].as_f64().unwrap() - 150.0).abs() < 1.0);
    assert_eq!(r["daemon"]["mean_cpu_pct"].as_f64(), Some(250.0));
    assert!((r["daemon"]["peak_queued_mb"].as_f64().unwrap() - 0.038).abs() < 0.001);
    assert_eq!(r["daemon"]["status_call_ms"]["n"], 41);
}

#[test]
fn report_from_a_fixture_run_dir() {
    let run = r#"{"schema":"coord-sim-drive.v1","coordinators":2,"rate":10,"readers":2,"run_s":30,"sessions":["s0","s1"]}"#;
    let base = 1_763_500_000_000_000u64;
    let mut ev = String::new();
    for seq in 1..=100u64 {
        for c in 0..2u32 {
            let emit = base + seq * 10_000;
            let lat = seq * 1000; // 1..100 ms
            match (c, seq) {
                (1, 50) => ev.push_str(&event(c, seq, "agent", emit, 0, None, 0)), // lost in the daemon
                (1, 51) => ev.push_str(&event(c, seq, "agent", emit, 1, None, 0)), // stored, never seen
                (1, 60) => ev.push_str(&event(c, seq, "agent", emit, 2, Some(emit + lat), 3)), // 1 + 2 extra
                _ => ev.push_str(&event(c, seq, "agent", emit, 1, Some(emit + lat), 1)),
            }
        }
    }
    for i in 0..10u64 {
        ev.push_str(&event(
            0,
            1000 + i,
            "turn",
            base + i * 1_000_000,
            1,
            Some(base + i * 1_000_000 + (i + 1) * 5000),
            1,
        ));
    }
    ev.push_str("{\"c\":0,\"seq\":3,\"src\":\"age"); // half a line from a killed driver
    let mut ops = String::new();
    for i in 1..=20u64 {
        let t = base + i;
        ops.push_str(&format!("{{\"op\":\"open\",\"reader\":0,\"c\":0,\"t_us\":{t},\"latency_us\":{},\"bytes\":10,\"n\":{},\"ok\":true,\"err\":null}}\n", i * 10_000, if i % 2 == 0 { 5 } else { 0 }));
        ops.push_str(&format!("{{\"op\":\"scroll\",\"reader\":0,\"c\":0,\"t_us\":{t},\"latency_us\":{},\"bytes\":10,\"n\":50,\"ok\":true,\"err\":null}}\n", i * 2000));
    }
    ops.push_str(&format!("{{\"op\":\"scroll\",\"reader\":0,\"c\":0,\"t_us\":{base},\"latency_us\":900000,\"bytes\":0,\"n\":null,\"ok\":false,\"err\":\"timeout\"}}\n"));
    ops.push_str("{\"op\":\"follower\",\"c\":0,\"notes\":120,\"bytes\":5000,\"lagged\":3}\n{\"op\":\"follower\",\"c\":1,\"notes\":100,\"bytes\":4000,\"lagged\":0}\n");
    let mut procs = String::new();
    for m in 0..=10u64 {
        // +10 MB per minute from 100 MB, 30 % CPU; children alongside
        procs.push_str(&format!("{{\"t_us\":{},\"role\":\"daemon\",\"pids\":[9],\"rss_kb\":{},\"cpu_ticks\":0,\"cpu_pct\":30.0}}\n", base + m * 60_000_000, 102_400 + m * 10_240));
        procs.push_str(&format!("{{\"t_us\":{},\"role\":\"children\",\"pids\":[10,11],\"rss_kb\":2048,\"cpu_ticks\":0,\"cpu_pct\":5.0}}\n", base + m * 60_000_000));
    }
    let d = run_dir(
        "fixture",
        &[("run.json", run), ("events.ndjson", &ev), ("ops.ndjson", &ops), ("proc.ndjson", &procs)],
    );
    let r = report(&d).unwrap();

    assert_eq!(r["schema"], SCHEMA);
    assert_eq!(r["config"]["coordinators"], 2);
    assert_eq!(r["config"]["chats"], 2);
    assert_eq!(r["events"]["emitted"]["agent"], 200);
    assert_eq!(r["events"]["emitted"]["turn"], 10);
    assert_eq!(
        (r["events"]["lost_in_daemon"].as_u64(), r["events"]["unseen_by_readers"].as_u64()),
        (Some(1), Some(1))
    );
    assert_eq!(r["events"]["lost"], 2);
    assert_eq!(
        (r["events"]["dup_in_daemon"].as_u64(), r["events"]["dup_at_readers"].as_u64()),
        (Some(1), Some(2))
    );
    assert_eq!(r["events"]["duplicated"], 3);
    assert_eq!(r["events"]["dup_events"], 1);
    // seq 51 of coordinator 1 is followed by seen events: a gap, not the tail
    assert_eq!(
        (r["events"]["unseen_gap"].as_u64(), r["events"]["unseen_tail"].as_u64()),
        (Some(1), Some(0))
    );
    assert_eq!(r["events"]["never_stored_unseen"], 1);
    assert_eq!(r["bad_lines"]["events"], 1);
    assert_eq!(r["delivery_ms"]["n"], 198);
    let p95 = r["delivery_ms"]["p95"].as_f64().unwrap();
    assert!((p95 - 95.0).abs() < 1.5, "{p95}");
    assert_eq!(r["typing"]["ack_ms"]["n"], 10);
    let echo = r["typing"]["echo_ms"]["p50"].as_f64().unwrap();
    assert!((echo - 25.0).abs() < 0.5, "{echo}");
    let a95 = r["attach_ms"]["p95"].as_f64().unwrap();
    assert!((a95 - 190.0).abs() < 2.0, "{a95}");
    assert_eq!(r["first_paint_ms"]["n"], 10); // the opens whose reply had events
    // pages 2..40 ms: over 16.7 => 18..40 (12); over 33.3 => 34..40 (4); the failed page is no latency
    assert_eq!(r["scroll"]["page_ms"]["n"], 20);
    assert_eq!(r["scroll"]["over_16_7ms"], 12);
    assert_eq!(r["scroll"]["over_33_3ms"], 4);
    assert_eq!(r["ops"]["scroll"]["failed"], 1);
    assert_eq!(r["follower"]["lagged"], 3);
    let slope = r["daemon"]["rss_slope_mb_per_min"].as_f64().unwrap();
    assert!((slope - 10.0).abs() < 0.01, "{slope}");
    assert_eq!(r["daemon"]["peak_rss_mb"].as_f64().unwrap(), 200.0);
    assert_eq!(r["daemon"]["baseline_rss_mb"].as_f64().unwrap(), 100.0);
    let pc = r["per_chat"]["cpu_pct"]["p50"].as_f64().unwrap();
    assert!((pc - 15.0).abs() < 0.2, "{pc}");
    // per chat RSS over the baseline: 0..100 MB / 2 chats, median 25
    let pm = r["per_chat"]["rss_mb"]["p50"].as_f64().unwrap();
    assert!((24.0..26.0).contains(&pm), "{pm}");
    assert_eq!(r["peak_rss_mb_by_role"]["children"].as_f64().unwrap(), 2.0);

    let rows = perf_rows(&r);
    let names: Vec<&str> = rows.iter().filter_map(|x| x["name"].as_str()).collect();
    for want in [
        "coord_sim.delivery_ms",
        "coord_sim.attach_ms",
        "coord_sim.events.lost",
        "coord_sim.events.duplicated",
        "coord_sim.events.lost_or_duplicated",
        "coord_sim.daemon.rss_slope_mb_per_min",
        "coord_sim.per_chat.rss_mb",
        "coord_sim.typing.echo_ms",
        "coord_sim.scroll.over_33ms",
    ] {
        assert!(names.contains(&want), "{want} missing from {names:?}");
    }
    for n in &names {
        assert!(
            n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-".contains(c)),
            "{n}"
        );
        assert!(!n.ends_with(".frame") && !n.ends_with(".missed") && !n.ends_with(".dropped"));
    }
    let ld = rows.iter().find(|x| x["name"] == "coord_sim.events.lost_or_duplicated").unwrap();
    assert_eq!((ld["p95"].as_f64(), ld["target"].as_f64()), (Some(5.0), Some(0.0)));

    // the CLI writes report.json, with what the harness passes
    super::run(&[
        d.to_string_lossy().into_owned(),
        "--commit".into(),
        "abc123".into(),
        "--seed".into(),
        "7".into(),
    ])
    .unwrap();
    let written: Value =
        serde_json::from_str(&std::fs::read_to_string(d.join("report.json")).unwrap()).unwrap();
    assert_eq!(written["events"]["lost"], 2);
    assert_eq!(written["config"]["commit"], "abc123");
    assert_eq!(written["config"]["seed"], 7);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn fanin_ramp_section_and_rows() {
    let table = |n: u64, rss_kb_per: f64, cpu_per: f64| {
        json!({"schema": "fanin-table.v1", "n": n, "hosts": 10,
            "attach_ms": {"n": n, "p50": 3.0, "p95": 8.0 + n as f64 / 100.0, "p99": 9.0, "max": 12.0}, "attach_failed": 0,
            "attach_one_ms": {"n": 30, "p50": 2.0, "p95": 4.0},
            "list": {"whole_ms_at_rest": 1.5 * n as f64 / 50.0, "paged_ms_at_rest": 2.0, "rows": n, "pages": 1,
                     "whole_ms_window": {"n": 5, "p50": 3.0, "p95": 6.0}},
            "fanin_ms": {"n": 100, "p50": 1.0, "p95": 2.0},
            "fanout_ms": {"n": n, "p50": 5.0, "p95": 20.0, "p99": 25.0, "max": 30.0},
            "events": {"emitted": 1000, "lost": if n == 2000 { 3 } else { 0 }, "dup": 0, "fanout_sent": n,
                       "fanout_lost": 0, "fanout_dup": 1, "client_lagged": 0},
            "controller": {"cpu_pct": cpu_per * n as f64, "cpu_pct_per_session": cpu_per, "rss_kb": 50_000.0 + rss_kb_per * n as f64,
                           "rss_kb_per_session": rss_kb_per},
            "gaps": []})
    };
    let summary = json!({"schema": "fanin-summary.v1", "controller_slopes": [{"from": 50, "to": 200, "rss_kb_per_added_session": 110.0}],
        "ratios": [], "goal_met_at_2000": false,
        "tables": [table(50, 102.4, 0.02), table(200, 204.8, 0.02), table(2000, 2150.4, 0.02),
                   {"schema": "fanin-table.v1", "n": 5000, "error": "wall clock cap"}]});
    let d = run_dir("fanin", &[("fanin-summary.json", &summary.to_string())]);
    let r = report(&d).unwrap();
    let f = &r["fanin"];
    let n200 = &f["ramps"][1];
    assert_eq!(n200["n"], 200);
    assert_eq!(n200["attach_ms"]["p95"].as_f64(), Some(10.0));
    assert_eq!(n200["controller"]["rss_mb_per_session"].as_f64(), Some(0.2));
    assert_eq!(n200["fanout_ms"]["max"].as_f64(), Some(30.0));
    assert_eq!(n200["list_ms"]["whole_at_rest"].as_f64(), Some(6.0));
    assert_eq!(f["ramps"][2]["events"]["lost"].as_f64(), Some(3.0));
    assert_eq!(f["ramps"][3]["error"], "wall clock cap");
    // per-session RSS: 0.1, 0.2, 2.1 MB at 50, 200, 2000: rising, about 1.03 MB per 1,000 sessions
    let slope = f["slope_per_1000_sessions"]["controller_rss_mb_per_session"].as_f64().unwrap();
    assert!((slope - 1.03).abs() < 0.05, "{slope}");
    assert_eq!(f["slope_per_1000_sessions"]["controller_cpu_pct_per_session"].as_f64(), Some(0.0));
    assert_eq!(f["marginal"][0]["rss_kb_per_added_session"].as_f64(), Some(110.0));
    let rows = perf_rows(&r);
    let get =
        |n: &str| rows.iter().find(|x| x["name"] == n).unwrap_or_else(|| panic!("{n} missing"));
    assert_eq!(get("coord_sim.fanin.n200.attach_ms")["p95"].as_f64(), Some(10.0));
    assert_eq!(
        get("coord_sim.fanin.n200.controller_rss_mb_per_session")["p95"].as_f64(),
        Some(0.2)
    );
    assert_eq!(get("coord_sim.fanin.n200.fanout_ms")["p50"].as_f64(), Some(5.0));
    assert_eq!(get("coord_sim.fanin.n200.fanout_max_ms")["p95"].as_f64(), Some(30.0));
    assert_eq!(get("coord_sim.fanin.n50.lost_or_duplicated")["p95"].as_f64(), Some(1.0));
    assert!(
        get("coord_sim.fanin.slope.controller_rss_mb_per_session_per_ksession")["p95"]
            .as_f64()
            .unwrap()
            > 1.0
    );
    assert!(rows.iter().all(|x| !x["name"].as_str().unwrap().contains("n5000")));
    // one ramp's own dir (fanin-table.json, and the raw files with fanin's `attach` op)
    let one = run_dir(
        "fanin-one",
        &[
            ("fanin-table.json", &table(200, 204.8, 0.02).to_string()),
            (
                "ops.ndjson",
                "{\"op\":\"attach\",\"c\":1,\"t_us\":1,\"latency_us\":7000,\"n\":3,\"ok\":true}\n",
            ),
        ],
    );
    let r1 = report(&one).unwrap();
    assert_eq!(r1["fanin"]["ramps"][0]["n"], 200);
    assert_eq!(r1["attach_ms"]["n"], 1);
    assert_eq!(r1["first_paint_ms"]["n"], 1);
    assert_eq!(r1["fanin"]["ramps"][0]["controller"]["cpu_basis"], "whole life");
    assert!(
        perf_rows(&r1)
            .iter()
            .any(|x| x["name"] == "coord_sim.fanin.n200.controller_life_cpu_pct_per_session")
    );
    // a committed results dir (the first fleet ramp's layout): the summary without `tables`, each table beside
    // it as n<N>.fanin-table.json, out of order on disk
    let mut no_tables = summary.clone();
    no_tables["tables"] = Value::Null;
    let committed = run_dir(
        "fanin-committed",
        &[
            ("fanin-summary.json", &no_tables.to_string()),
            ("n2000.fanin-table.json", &table(2000, 2150.4, 0.02).to_string()),
            ("n50.fanin-table.json", &table(50, 102.4, 0.02).to_string()),
            ("n200.fanin-table.json", &table(200, 204.8, 0.02).to_string()),
        ],
    );
    let rc = report(&committed).unwrap();
    let ns: Vec<u64> =
        rc["fanin"]["ramps"].as_array().unwrap().iter().filter_map(|t| t["n"].as_u64()).collect();
    assert_eq!(ns, [50, 200, 2000]);
    assert_eq!(rc["fanin"]["ramps"][1]["controller"]["rss_mb_per_session"].as_f64(), Some(0.2));
    // --fanin DIR adds the ramp to a drive run's report
    let drive = run_dir("fanin-drive", &[("run.json", "{}")]);
    super::run(&[
        drive.to_string_lossy().into_owned(),
        "--fanin".into(),
        d.to_string_lossy().into_owned(),
    ])
    .unwrap();
    let written: Value =
        serde_json::from_str(&std::fs::read_to_string(drive.join("report.json")).unwrap()).unwrap();
    assert_eq!(written["fanin"]["ramps"][1]["n"], 200);
    for x in [d, one, drive] {
        let _ = std::fs::remove_dir_all(&x);
    }
}

#[test]
fn empty_run_dir_reports_nulls_not_errors() {
    let d = run_dir("empty", &[]);
    let r = report(&d).unwrap();
    assert_eq!(r["files"]["events"], false);
    assert_eq!(r["delivery_ms"]["p95"], Value::Null);
    assert_eq!(r["daemon"]["rss_slope_mb_per_min"], Value::Null);
    assert_eq!(r["events"]["lost"], 0);
    assert!(perf_rows(&r).is_empty(), "an empty run has no rows");
    assert!(r["fanin"].is_null());
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn large_file_memory_is_constant() {
    // 2M event lines: only counters and fixed histograms are kept.
    let d = run_dir("large", &[("run.json", "{}")]);
    let mut f = std::io::BufWriter::new(File::create(d.join("events.ndjson")).unwrap());
    for seq in 1..=2_000_000u64 {
        let emit = 1_000_000 + seq * 1000;
        writeln!(f, "{{\"c\":0,\"seq\":{seq},\"k\":0,\"src\":\"agent\",\"due_us\":{emit},\"emit_us\":{emit},\"daemon_at_ms\":{},\"daemon_n\":1,\"reader_us\":{},\"reader_n\":1}}", emit / 1000, emit + (seq % 7) * 1000).unwrap();
    }
    drop(f);
    let r = report(&d).unwrap();
    assert_eq!(r["events"]["lost"], 0);
    assert_eq!(r["delivery_ms"]["n"], 2_000_000);
    assert_eq!(r["delivery_ms"]["max"].as_f64().unwrap(), 6.0);
    let _ = std::fs::remove_dir_all(&d);
}
