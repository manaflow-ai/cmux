//! `cmux metrics`: the arguments, the one `metrics.snapshot` request it
//! sends (names only, no read barrier), the exit codes of a refusal and the
//! table in both catalogs.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::*;
use crate::localization::catalog_for_locale;

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| (*arg).to_owned()).collect()
}

/// An app socket that answers each accepted request with the next reply
/// (`{"ok": true, "result": …}` or, for an `Err`, `{"ok": false, "error": …}`)
/// and returns the requests it read.
fn fake_app(
    dir: &Path,
    replies: Vec<Result<Value, Value>>,
) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut requests = Vec::new();
        for reply in replies {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            requests.push(serde_json::from_str::<Value>(&line).unwrap());
            let answer = match reply {
                Ok(result) => json!({"id": 1, "ok": true, "result": result}),
                Err(error) => json!({"id": 1, "ok": false, "error": error}),
            };
            let mut stream = stream;
            stream.write_all(format!("{answer}\n").as_bytes()).unwrap();
        }
        requests
    });
    (socket, server)
}

fn histogram(
    name: &str,
    unit: &str,
    count: u64,
    mean: f64,
    percentiles: Option<[u64; 4]>,
) -> Value {
    let mut value = json!({
        "name": name, "unit": unit, "count": count, "sum": 0, "mean": mean, "overflow_count": 0,
        "layout": {"kind": "log_linear", "maximum": 60_000_000}, "buckets": [],
    });
    if let Some([p50, p95, p99, max]) = percentiles {
        for (key, at) in [("p50", p50), ("p95", p95), ("p99", p99), ("max", max)] {
            value[key] = json!(at);
        }
    }
    value
}

#[test]
fn cli_metrics_parses_names_help_and_refuses_options() {
    assert_eq!(parse(&[]), Ok(Invocation::Snapshot(vec![])));
    assert_eq!(
        parse(&words(&["key.frame", "daemon.request"])),
        Ok(Invocation::Snapshot(words(&["key.frame", "daemon.request"])))
    );
    for help in [&["--help"][..], &["-h"], &["help"], &["key.frame", "--help"]] {
        assert_eq!(parse(&words(help)), Ok(Invocation::Help), "{help:?}");
    }
    assert!(parse(&words(&["--names", "x"])).is_err());
    assert!(parse(&words(&["key.frame", "-x"])).is_err());
}

#[test]
fn cli_metrics_sends_only_names() {
    assert_eq!(params(&[]), json!({}));
    assert_eq!(params(&words(&["main.turn"])), json!({"names": ["main.turn"]}));
}

#[test]
fn cli_metrics_asks_the_app_once_without_a_read_barrier() {
    let temp = tempfile::tempdir().unwrap();
    let reply = json!({"recording": true, "pid": 42, "count": 0, "histograms": []});
    let (socket, server) = fake_app(temp.path(), vec![Ok(reply.clone())]);
    let global = GlobalArgs { app_socket: Some(socket), ..GlobalArgs::default() };

    assert_eq!(snapshot(&global, &words(&["key.frame"])), Ok(reply));

    let requests = server.join().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["method"], METHOD);
    assert_eq!(requests[0]["params"], json!({"names": ["key.frame"]}), "no `after`, no `caller`");
}

#[test]
fn cli_metrics_exit_codes_tell_an_old_app_from_a_feature_that_is_off() {
    let temp = tempfile::tempdir().unwrap();
    let old = json!({"code": "method_not_found", "message": "Unknown method metrics.snapshot"});
    let off = json!({"code": "unavailable", "message": "metrics.snapshot is off"});
    let (socket, server) = fake_app(temp.path(), vec![Err(old.clone()), Err(off.clone())]);
    let global = GlobalArgs { app_socket: Some(socket), ..GlobalArgs::default() };

    assert_eq!(snapshot(&global, &[]), Err(Failure { error: old, exit_code: 5 }));
    assert_eq!(snapshot(&global, &[]), Err(Failure { error: off, exit_code: 1 }));
    server.join().unwrap();

    let gone =
        GlobalArgs { app_socket: Some(temp.path().join("none.sock")), ..GlobalArgs::default() };
    assert_eq!(snapshot(&gone, &[]).map_err(|failure| failure.exit_code), Err(3));
}

#[test]
fn cli_metrics_table_aligns_every_column_in_both_catalogs() {
    let reply = json!({
        "recording": true, "pid": 4242, "count": 2,
        "histograms": [
            histogram("key.frame.view", "us", 100, 1234.4, Some([1279, 8191, 8191, 57343])),
            histogram("cef.helper_exit", "enumeration", 3, 9.0, None),
        ],
    });
    let english = table(&reply, &catalog_for_locale("en").metrics);
    assert_eq!(
        english,
        "NAME             UNIT         COUNT  MEAN   P50   P95   P99    MAX\n\
         key.frame.view   us             100  1234  1279  8191  8191  57343\n\
         cef.helper_exit  enumeration      3     9     -     -     -      -\n\
         2 histograms since the app started (pid 4242)"
    );
    let japanese = table(&reply, &catalog_for_locale("ja").metrics);
    assert!(japanese.starts_with("名前"), "{japanese}");
    assert!(japanese.ends_with("(pid 4242)"), "{japanese}");
    // Each CJK title fills two terminal cells per char: the columns still line up on screen.
    for text in [&english, &japanese] {
        let lines: Vec<&str> = text.lines().take(3).collect();
        let header = cell_spans(lines[0]);
        assert_eq!(header.len(), 8, "{text}");
        for line in &lines[1..] {
            let cells = cell_spans(line);
            assert_eq!(cells.len(), header.len(), "{text}");
            for (column, (cell, title)) in cells.iter().zip(&header).enumerate() {
                // NAME and UNIT are left-aligned, the numbers right-aligned.
                let (at, expected) = if column < 2 { (cell.0, title.0) } else { (cell.1, title.1) };
                assert_eq!(at, expected, "column {column} is out of line:\n{text}");
            }
        }
    }
}

/// The start and end terminal-cell offsets of each space-separated cell of a table line.
fn cell_spans(line: &str) -> Vec<(usize, usize)> {
    use unicode_width::UnicodeWidthChar;
    let mut spans = Vec::new();
    let mut offset = 0;
    let mut start = None;
    for character in line.chars() {
        if character == ' ' {
            if let Some(begin) = start.take() {
                spans.push((begin, offset));
            }
        } else if start.is_none() {
            start = Some(offset);
        }
        offset += character.width().unwrap_or(0);
    }
    if let Some(begin) = start {
        spans.push((begin, offset));
    }
    spans
}

#[test]
fn cli_metrics_table_marks_values_past_the_largest_bucket() {
    let mut turns = histogram(
        "main.turn",
        "us",
        2,
        30_000_000.0,
        Some([1023, 60_000_001, 60_000_001, 60_000_001]),
    );
    turns["overflow_count"] = json!(1);
    let reply = json!({"recording": true, "pid": 1, "histograms": [turns]});
    let text = table(&reply, &catalog_for_locale("en").metrics);
    let row = text.lines().nth(1).unwrap();
    assert!(row.ends_with("1023  >60000000  >60000000  >60000000"), "{row}");
}

#[test]
fn cli_metrics_table_says_when_nothing_is_recorded_or_matches() {
    let messages = &catalog_for_locale("en").metrics;
    assert_eq!(
        table(&json!({"recording": false, "histograms": []}), messages),
        messages.not_recording
    );
    assert_eq!(
        table(&json!({"recording": true, "histograms": []}), messages),
        messages.no_histograms
    );
}

#[test]
fn cli_metrics_help_runs_from_both_spellings() {
    for catalog in [catalog_for_locale("en"), catalog_for_locale("ja")] {
        assert!(catalog.metrics.usage.contains("cmux metrics"));
        assert!(catalog.metrics.usage.contains("--json"));
        assert!(catalog.metrics.usage.contains("metricsView"));
        assert!(catalog.local_server.cmux_root_help.contains("cmux metrics --help"));
    }
}
