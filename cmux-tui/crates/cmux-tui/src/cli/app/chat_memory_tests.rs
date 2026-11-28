use std::cell::RefCell;
use std::collections::HashMap;

use serde_json::{Value, json};

use super::super::{AppCommand, parse};
use super::{human, report};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// Five chats: `a` and `b` share WebContent process 100 (a New Tab page and a chat), `c` has 200,
/// `d` has 300, `e` has no page.
fn handover() -> Value {
    json!({
        "app_pid": 1,
        "daemon_pids": [2],
        "chats": [
            {"tab": "a", "machine": "m", "pid": 100, "new_tab": false, "frozen": false},
            {"tab": "b", "machine": "m", "pid": 100, "new_tab": true, "frozen": false},
            {"tab": "c", "machine": "m", "pid": 200, "new_tab": false, "frozen": false},
            {"tab": "d", "machine": "m", "pid": 300, "new_tab": true, "frozen": false},
            {"tab": "e", "machine": "m", "pid": null, "new_tab": false, "frozen": true},
        ],
    })
}

const MB: u64 = 1_048_576;

fn footprints() -> HashMap<u32, u64> {
    HashMap::from([(1, 500 * MB), (2, 40 * MB), (100, 300 * MB), (200, 150 * MB), (300, 100 * MB)])
}

fn run(handover: &Value, empty: &Value) -> (Value, Vec<u32>) {
    let table = footprints();
    let reads = RefCell::new(Vec::new());
    let out = report(handover, empty, &|pid| {
        reads.borrow_mut().push(pid);
        table.get(&pid).copied()
    });
    (out, reads.into_inner())
}

fn chat<'a>(out: &'a Value, tab: &str) -> &'a Value {
    out["chats"].as_array().unwrap().iter().find(|chat| chat["tab"] == tab).unwrap()
}

/// Two chats on one WebContent process are one process: it is read once, counted once in the total,
/// and each chat names the others it shares with.
#[test]
fn chats_sharing_a_process_are_grouped_by_pid_and_counted_once() {
    let (out, reads) = run(&handover(), &json!({}));
    let mut web_reads: Vec<u32> = reads.into_iter().filter(|pid| *pid >= 100).collect();
    web_reads.sort_unstable();
    assert_eq!(web_reads, vec![100, 200, 300]);
    assert_eq!(out["summary"]["web_processes"], 3);
    assert_eq!(out["summary"]["shared_processes"], 1);
    assert_eq!(out["summary"]["web_total_bytes"], (300 + 150 + 100) * MB);
    assert_eq!(chat(&out, "a")["shared_with"], json!(["b"]));
    assert_eq!(chat(&out, "b")["shared_with"], json!(["a"]));
    assert_eq!(chat(&out, "a")["footprint_bytes"], 300 * MB);
    assert_eq!(chat(&out, "b")["footprint_bytes"], 300 * MB);
    assert_eq!(chat(&out, "c")["shared"], false);
    assert_eq!(chat(&out, "e")["pid"], Value::Null);
    assert_eq!(out["processes"].as_array().unwrap().len(), 3);
    assert_eq!(out["app"], json!({"pid": 1, "footprint_bytes": 500 * MB}));
    assert_eq!(out["daemons"], json!([{"pid": 2, "footprint_bytes": 40 * MB}]));
}

/// With no flag the empty chat is a New Tab page alone in its process (`d`, 100 MB); `b` is a New
/// Tab page too but shares its process with `a`, so it is no baseline. The headline ratio is over
/// processes holding a chat with content: process 100 (3.0x, through `a`) and 200 (1.5x).
#[test]
fn the_empty_chat_is_a_new_tab_page_alone_in_its_process() {
    let (out, _) = run(&handover(), &json!({}));
    assert_eq!(out["empty"]["source"], "new_tab");
    assert_eq!(out["empty"]["tab"], "d");
    assert_eq!(out["empty"]["footprint_bytes"], 100 * MB);
    assert_eq!(chat(&out, "c")["ratio"], 1.5);
    assert_eq!(chat(&out, "a")["ratio"], 3.0);
    assert_eq!(out["summary"]["ratio_median"], 2.25);
    assert_eq!(out["summary"]["ratio_max"], 3.0);
}

#[test]
fn a_named_tab_or_bytes_is_the_baseline_and_a_shared_one_is_refused() {
    let (out, _) = run(&handover(), &json!({"tab": "c"}));
    assert_eq!(out["empty"]["source"], "tab");
    assert_eq!(chat(&out, "a")["ratio"], 2.0);
    // The baseline's own process is out of the headline: only process 100 and 300 remain, and 300
    // holds only a New Tab page, so only 100 counts.
    assert_eq!(out["summary"]["ratio_median"], 2.0);
    assert_eq!(out["summary"]["ratio_max"], 2.0);

    let (out, _) = run(&handover(), &json!({"bytes": 50 * MB}));
    assert_eq!(out["empty"]["source"], "bytes");
    assert_eq!(chat(&out, "c")["ratio"], 3.0);

    let (out, _) = run(&handover(), &json!({"tab": "a"}));
    assert_eq!(out["empty"]["reason"], "shared_process");
    assert_eq!(chat(&out, "c")["ratio"], Value::Null);
    assert_eq!(out["summary"]["ratio_median"], Value::Null);

    let (out, _) = run(&handover(), &json!({"tab": "gone"}));
    assert_eq!(out["empty"]["reason"], "no_page");
}

/// No empty page: ratios are null and the report says why; a chat whose process ended has a null
/// footprint and does not fail the report.
#[test]
fn without_an_empty_page_ratios_are_null_and_an_ended_process_reads_null() {
    let only = json!({
        "app_pid": 1, "daemon_pids": [],
        "chats": [
            {"tab": "x", "machine": "m", "pid": 200, "new_tab": false, "frozen": false},
            {"tab": "y", "machine": "m", "pid": 999, "new_tab": false, "frozen": false},
        ],
    });
    let (out, _) = run(&only, &json!({}));
    assert_eq!(out["empty"], json!({"source": null, "reason": "no_empty_chat"}));
    assert_eq!(chat(&out, "x")["ratio"], Value::Null);
    assert_eq!(chat(&out, "y")["footprint_bytes"], Value::Null);
    assert_eq!(out["summary"]["web_total_bytes"], 150 * MB);
    let (out, _) = run(&only, &json!({"bytes": 75 * MB}));
    assert_eq!(chat(&out, "x")["ratio"], 2.0);
    assert_eq!(chat(&out, "y")["ratio"], Value::Null);
}

#[test]
fn no_chats_reports_the_app_alone() {
    let (out, _) = run(&json!({"app_pid": 1, "daemon_pids": [2], "chats": []}), &json!({}));
    assert_eq!(out["summary"]["chats"], 0);
    assert_eq!(out["summary"]["web_total_bytes"], 0);
    assert_eq!(out["summary"]["ratio_max"], Value::Null);
}

#[test]
fn the_summary_names_each_chat_in_both_languages() {
    let (out, _) = run(&handover(), &json!({}));
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let text =
            human(&out, &crate::localization::catalog_for_locale(locale).app_control.chat_memory);
        for needle in ["pid 200", "pid 300", "150.0 MB", "2.25x", "3.00x"] {
            assert!(text.contains(needle), "{locale}: {needle} missing from:\n{text}");
        }
        assert!(!text.contains('{'), "{locale}: an unfilled placeholder in:\n{text}");
    }
}

#[test]
fn the_command_parses_its_two_options() {
    let command = parse(&args(&["app", "chat", "memory"])).unwrap().unwrap();
    assert_eq!(command, AppCommand::ChatMemory { empty: json!({}) });
    let command =
        parse(&args(&["app", "chat", "memory", "--empty-tab", "tab_1", "--empty-bytes=99"]))
            .unwrap()
            .unwrap();
    assert_eq!(command, AppCommand::ChatMemory { empty: json!({"tab": "tab_1", "bytes": 99}) });
    for bad in [
        &["app", "chat", "memory", "--empty-bytes", "lots"][..],
        &["app", "chat", "memory", "--empty-tab", ""],
        &["app", "chat", "memory", "--tab", "tab_1"],
        &["app", "chat", "memory", "extra"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?} should be refused");
    }
}
