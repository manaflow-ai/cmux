use serde_json::{Value, json};

use crate::clock::{iso_utc, parse_timestamp, utc_stamp};
use crate::process::{Row, Tick, Usage, cpu_pct, from_root, kind_of, parse_procargs, per_second};
use crate::trace::{Event, document};
use crate::{pages, signposts, summary};

const BUNDLE: &str = "/Applications/cmux NIGHTLY.app";

#[test]
fn timestamps_of_log_stream_and_iso_share_one_clock() {
    let iso = parse_timestamp("2026-11-07T09:01:02.345Z").unwrap();
    assert_eq!(iso, 1_794_042_062_345_000);
    assert_eq!(parse_timestamp("2026-11-07 01:01:02.345000-0800"), Some(iso));
    assert_eq!(parse_timestamp("2026-11-07T10:01:02.345+01:00"), Some(iso));
    assert_eq!(parse_timestamp("2026-11-07T09:01:02Z"), Some(iso - 345_000));
    assert_eq!(parse_timestamp("1970-01-01T00:00:00.000001Z"), Some(1));
    assert_eq!(parse_timestamp("not a time"), None);
    assert_eq!(parse_timestamp("2026-13-07T09:01:02Z"), None);
    assert_eq!(iso_utc(iso), "2026-11-07T09:01:02.345Z");
    assert_eq!(utc_stamp(iso), "20261107T090102Z");
    assert_eq!(iso_utc(951_782_400_000_000), "2000-02-29T00:00:00.000Z");
}

#[test]
fn trace_document_has_the_perfetto_shape() {
    let events = vec![
        Event::slice("action.commit", "action", 2_000, 1_500, 7, 3).with_arg("id", "tab.new"),
        Event::counter("cpu_pct", 1_000, 7, &[("cpu_pct", 12.34567)]),
        Event::name_of(7, None, "app 7"),
        Event::instant("navigation", "page", 1_500, 7, 900_001),
    ];
    let doc = document(events, json!({"app": "cmux.app"}));
    let text = serde_json::to_string(&doc).unwrap();
    let back: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(back["displayTimeUnit"], "ms");
    assert_eq!(back["metadata"]["app"], "cmux.app");
    let list = back["traceEvents"].as_array().unwrap();
    assert_eq!(
        list[0],
        json!({"name": "process_name", "ph": "M", "ts": 0, "pid": 7, "tid": 0, "args": {"name": "app 7"}})
    );
    assert_eq!(
        list[1],
        json!({"name": "cpu_pct", "ph": "C", "ts": 1000, "pid": 7, "tid": 0, "args": {"cpu_pct": 12.346}})
    );
    assert_eq!(list[2]["ph"], "i");
    assert_eq!(list[2]["s"], "t");
    assert_eq!(
        list[3],
        json!({"name": "action.commit", "cat": "action", "ph": "X", "ts": 2000, "dur": 1500, "pid": 7, "tid": 3, "args": {"id": "tab.new"}})
    );
}

fn signpost(kind: &str, name: &str, id: u64, time: &str, message: &str) -> String {
    json!({
        "eventType": "signpostEvent", "subsystem": signposts::SUBSYSTEM, "category": "action",
        "signpostName": name, "signpostID": id, "signpostType": kind, "processID": 41, "threadID": 9,
        "timestamp": format!("2026-10-23 04:55:{time}-0700"), "eventMessage": message,
    })
    .to_string()
}

#[test]
fn signposts_pair_begin_and_end_and_keep_strays() {
    let start = parse_timestamp("2026-10-23 04:55:40.000000-0700").unwrap();
    let end = parse_timestamp("2026-10-23 04:55:50.000000-0700").unwrap();
    let lines = [
        "Filtering the log data using \"subsystem == ...\"".to_owned(),
        signpost("begin", "action.commit", 7, "41.243635", "id=tab.new origin=user"),
        signpost("begin", "action.perform", 8, "41.243700", ""),
        signpost("end", "action.perform", 8, "41.245700", ""),
        signpost("end", "action.commit", 7, "41.249635", "commit=missed"),
        signpost("end", "action.commit", 99, "42.000000", ""),
        signpost("event", "key.flow", 5, "43.000000", "hop=app.keydown"),
        signpost("begin", "action.gate", 12, "44.000000", ""),
        signpost("begin", "action.commit", 13, "39.000000", ""),
        json!({"eventType": "lossEvent", "eventMessage": "lost 3 unreliable messages"}).to_string(),
        json!({"eventType": "signpostEvent", "subsystem": "other", "signpostType": "event",
               "timestamp": "2026-10-23 04:55:45.000000-0700"})
        .to_string(),
    ];
    let parsed = signposts::parse(lines.iter().map(String::as_str), start, end);
    assert_eq!(parsed.intervals.len(), 2);
    assert_eq!(
        (parsed.instants, parsed.unpaired_end, parsed.unpaired_begin, parsed.lost),
        (1, 1, 1, 1)
    );
    let commit = parsed
        .events
        .iter()
        .find(|event| event.name == "action.commit" && event.ph == "X")
        .unwrap();
    assert_eq!(commit.dur, Some(6_000));
    assert_eq!((commit.pid, commit.tid), (41, 9));
    assert_eq!(commit.args["id"], "tab.new");
    assert_eq!(commit.args["end.commit"], "missed");
    let top = summary::top_intervals(&parsed.intervals, 10);
    assert_eq!(top[0].name, "action.commit");
    assert!((top[0].ms - 6.0).abs() < 1e-9);
    assert!(
        parsed.events.iter().any(|event| event.ph == "i" && event.args.contains_key("unpaired"))
    );
    assert_eq!(parsed.events.len(), 5);
}

#[test]
fn page_ring_keeps_its_window_and_reads_frames() {
    let start = parse_timestamp("2026-11-07T09:00:00Z").unwrap();
    let end = parse_timestamp("2026-11-07T09:00:10Z").unwrap();
    let text = [
        r#"{"at":"2026-11-07T08:59:59.000Z","kind":"page-load","page":"new-tab","from":"page","pid":77}"#,
        r#"{"at":"2026-11-07T09:00:01.000Z","kind":"long-frame","ms":120.5,"page":"chat:s1","from":"page","pid":77}"#,
        r#"{"at":"2026-11-07T09:00:02.000Z","kind":"frames","n":60,"p50":16.7,"p95":20.1,"max":40,"miss120":30,"miss60":3,"over50":0,"ms":1000,"page":"chat:s1","from":"page","pid":77}"#,
        r#"{"at":"2026-11-07T09:00:03.000Z","kind":"frames","n":40,"p50":8.3,"p95":33.4,"max":60,"miss120":10,"miss60":2,"over50":1,"ms":1000,"page":"chat:s1","from":"page","pid":77}"#,
        r#"{"at":"2026-11-07T09:00:04.000Z","kind":"navigation"}"#,
        "not json",
        r#"{"at":"2026-11-07T09:00:11.000Z","kind":"visibility","page":"chat:s1"}"#,
    ]
    .join("\n");
    let parsed = pages::parse(text.lines(), start, end, 5);
    assert_eq!((parsed.lines, parsed.long_frames, parsed.frames.len()), (4, 1, 2));
    let long = parsed.events.iter().find(|event| event.name == "long-frame").unwrap();
    assert_eq!(
        (long.ph, long.ts, long.dur, long.pid),
        ("X", start + 1_000_000 - 120_500, Some(120_500), 77)
    );
    let navigation = parsed.events.iter().find(|event| event.name == "navigation").unwrap();
    assert_eq!((navigation.ph, navigation.pid), ("i", 5));
    assert!(parsed.events.iter().any(|event| event.ph == "C" && event.name == "frames chat:s1"));
    assert_eq!(parsed.threads.len(), 2);
    let row = summary::pages(&parsed.frames, parsed.long_frames);
    assert_eq!((row.windows, row.frames, row.long_frames), (2, 100.0, 1));
    assert!((row.miss120_share - 0.4).abs() < 1e-9);
    assert!((row.miss60_share - 0.05).abs() < 1e-9);
    assert!((row.median_p50_ms - 12.5).abs() < 1e-9);
    assert!((row.worst_p95_ms - 33.4).abs() < 1e-9);
}

#[test]
fn counters_are_rates_between_two_readings() {
    let before = Usage { cpu_ns: 1_000_000_000, wakeups: 100, memory: 0 };
    let after = Usage { cpu_ns: 1_125_000_000, wakeups: 150, memory: 0 };
    assert!((cpu_pct(&before, &after, 250_000_000) - 50.0).abs() < 1e-9);
    assert!((per_second(before.wakeups, after.wakeups, 250_000_000) - 200.0).abs() < 1e-9);
    assert_eq!(cpu_pct(&before, &after, 0), 0.0);
    // A counter that went down (a reused pid between readings) is no negative rate.
    assert_eq!(per_second(150, 100, 1_000_000_000), 0.0);
}

#[test]
fn kinds_follow_bench_memory() {
    let cases = [
        (format!("{BUNDLE}/Contents/MacOS/cmux"), "app"),
        (
            format!("{BUNDLE}/Contents/Frameworks/cmux Helper (Renderer).app/Contents/MacOS/cmux Helper (Renderer) --type=renderer"),
            "cef-renderer",
        ),
        (format!("{BUNDLE}/Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU) --type=gpu-process"), "cef-gpu"),
        (format!("{BUNDLE}/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper --type=utility"), "cef-utility"),
        (format!("{BUNDLE}/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper"), "cef-helper"),
        (format!("{BUNDLE}/Contents/Resources/bin/cmux-tui serve"), "tui-daemon"),
        (format!("{BUNDLE}/Contents/Resources/bin/cmux __terminal-host --id 3"), "terminal-host"),
        (format!("{BUNDLE}/Contents/Resources/bin/cmux-tui serve --session cmux-chief"), "tui-daemon-chief"),
        (format!("{BUNDLE}/Contents/Resources/bin/acpmux serve --socket x"), "acpmux-serve"),
        (format!("{BUNDLE}/Contents/Resources/bin/acpmux"), "acpmux-agent"),
        (format!("{BUNDLE}/Contents/Resources/bin/rg --json"), "rg"),
        (
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent".to_owned(),
            "webkit-webcontent",
        ),
        ("/usr/bin/login -pf me".to_owned(), "login"),
    ];
    for (command, kind) in cases {
        assert_eq!(kind_of(&command, BUNDLE), kind, "{command}");
    }
    // The app runs from /private/tmp while its daemons keep /tmp.
    assert_eq!(
        kind_of("/tmp/cmux.app/Contents/Resources/bin/cmux-tui serve", "/private/tmp/cmux.app"),
        "tui-daemon"
    );
    assert!(from_root("/tmp/cmux.app/Contents/MacOS/cmux", "/private/tmp/cmux.app"));
    assert!(!from_root("/Applications/cmux.app2/Contents/MacOS/x", "/Applications/cmux.app"));
    assert!(from_root("/usr/local/bin/cmux-tui serve", "/usr/local"));
    assert!(from_root("/usr/local/bin/acpmux serve", "/usr/local"));
    assert!(!from_root("/usr/local/bin/node server.js", "/usr/local"));
}

#[test]
fn procargs_give_the_exec_path_and_arguments() {
    let mut buffer = 3i32.to_ne_bytes().to_vec();
    buffer.extend_from_slice(b"/Applications/cmux.app/Contents/MacOS/cmux Helper\0\0\0\0");
    buffer.extend_from_slice(b"cmux Helper\0--type=renderer\0--lang=en\0HOME=/Users/me\0");
    assert_eq!(
        parse_procargs(&buffer).as_deref(),
        Some("/Applications/cmux.app/Contents/MacOS/cmux Helper --type=renderer --lang=en")
    );
    assert_eq!(parse_procargs(&[1, 0]), None);
}

fn row(pid: i32, kind: &str, cpu: Option<f64>, memory: f64) -> Row {
    Row {
        pid,
        kind: kind.to_owned(),
        cpu_pct: cpu,
        wakeups_per_s: cpu.map(|cpu| cpu * 10.0),
        memory_mb: memory,
    }
}

#[test]
fn summary_sums_pids_per_kind_at_each_sample() {
    let ticks = vec![
        Tick {
            at_us: 0,
            rows: vec![row(1, "app", None, 100.0), row(2, "cef-renderer", None, 50.0)],
        },
        Tick {
            at_us: 250_000,
            rows: vec![
                row(1, "app", Some(20.0), 110.0),
                row(2, "cef-renderer", Some(5.0), 50.0),
                row(3, "cef-renderer", None, 30.0),
            ],
        },
        Tick {
            at_us: 500_000,
            rows: vec![
                row(1, "app", Some(40.0), 120.0),
                row(2, "cef-renderer", Some(5.0), 55.0),
                row(3, "cef-renderer", Some(10.0), 30.0),
            ],
        },
    ];
    let kinds = summary::kinds(&ticks);
    assert_eq!(kinds[0].kind, "app");
    assert!((kinds[0].cpu_pct_mean - 30.0).abs() < 1e-9);
    assert!((kinds[0].cpu_pct_max - 40.0).abs() < 1e-9);
    assert!((kinds[0].wakeups_per_s_mean - 300.0).abs() < 1e-9);
    assert!((kinds[0].memory_mb_end - 120.0).abs() < 1e-9);
    assert!((kinds[0].memory_mb_growth - 20.0).abs() < 1e-9);
    let renderer = &kinds[1];
    assert_eq!((renderer.kind.as_str(), renderer.pids), ("cef-renderer", 2));
    assert!((renderer.cpu_pct_mean - 10.0).abs() < 1e-9);
    assert!((renderer.cpu_pct_max - 15.0).abs() < 1e-9);
    assert!((renderer.memory_mb_end - 85.0).abs() < 1e-9);
    assert!((renderer.memory_mb_growth - 35.0).abs() < 1e-9);

    let counters = crate::counter_events(&ticks);
    // Memory every sample (8 rows), CPU and wakeups from each pid's second sample (5 rows).
    assert_eq!(counters.len(), 8 + 5 * 2);

    let sources = [
        summary::Source::ok("processes", "3 processes"),
        summary::Source::unavailable("signposts", "macOS only"),
    ];
    let value = json!({
        "app": "cmux NIGHTLY.app", "bundle_id": "com.cmuxterm.app.nightly", "version": "1.2", "seconds": 0.5,
        "start": "2026-11-07T09:00:00.000Z", "sources": summary::sources_json(&sources),
        "wakeups_name": "wakeups_per_s", "memory_name": "footprint_mb", "processes": kinds,
        "pages": summary::pages(&[], 0), "signposts": null, "trace": "/tmp/x/trace.json",
    });
    assert_eq!(value["sources"]["signposts"]["status"], "unavailable");
    let text = summary::text(&value);
    assert!(text.contains("cef-renderer"), "{text}");
    assert!(text.contains("unavailable  macOS only"), "{text}");
    assert!(text.contains("agent pages"), "{text}");
    assert!(
        text.ends_with("trace: /tmp/x/trace.json\nopen it in https://ui.perfetto.dev\n"),
        "{text}"
    );
}

#[cfg(target_os = "linux")]
#[test]
fn linux_sampler_reads_this_process() {
    let own = std::process::id() as i32;
    let usage = crate::process::usage(own).unwrap();
    assert!(usage.memory > 0);
    let processes = crate::process::processes();
    assert!(processes.iter().any(|process| process.pid == own && !process.command.is_empty()));
}
