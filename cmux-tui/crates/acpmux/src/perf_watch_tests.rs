use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;

/// Where a test watch's clock starts.
const START_MS: u64 = 1_000_000;

fn watch_on() -> Watch {
    let watch = Watch::with_clock(START_MS);
    watch.set(true, None);
    watch
}

fn events(watch: &Watch) -> Vec<Value> {
    watch.read(0, 10_000)["events"].as_array().cloned().unwrap_or_default()
}

fn notes(watch: &Watch) -> Vec<String> {
    events(watch)
        .into_iter()
        .filter(|e| e["kind"] == "note")
        .filter_map(|e| e["text"].as_str().map(str::to_owned))
        .collect()
}

#[test]
fn off_records_nothing() {
    let watch = Watch::with_clock(START_MS);
    watch.bytes(channel::IPC, "reply to _acpmux/sessions", 10 << 20);
    watch.span("new chat", Some("chat.first_token"), 9_000.0, &[], Value::Null);
    watch.log_read("chat-1", 9_000, 9 << 20, true, Duration::from_millis(8));
    watch.report("chat", &json!({"renders": {"SessionInfo": 99}}));
    assert_eq!(watch.read(0, 100), json!({"on": false, "events": [], "seq": 0}));
    assert_eq!(watch.status(), json!({"on": false}));
}

#[test]
fn the_global_hooks_cost_one_load_while_off() {
    // The daemon starts off: no hook makes a label, a clock read or an entry.
    assert!(!on());
    let mut made = false;
    bytes(
        channel::IPC,
        || {
            made = true;
            String::new()
        },
        1 << 20,
    );
    assert!(!made, "a label was made while off");
    assert!(request_started().is_none());
    assert!(LogPass::start("chat", true).is_none());
}

#[test]
fn a_span_over_budget_says_so_with_its_slowest_part_and_one_under_stays_quiet() {
    let watch = watch_on();
    let parts = [
        ("handshake".to_owned(), 0.0, 120.0),
        ("agent start".to_owned(), 120.0, 2_900.0),
        ("first token".to_owned(), 3_020.0, 380.0),
    ];
    watch.span("new chat", Some("chat.first_token"), 3_400.0, &parts, Value::Null);
    let said = notes(&watch);
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(said[0].contains("new chat to first token took 3.4 s"), "{}", said[0]);
    assert!(said[0].contains("higher than expected"), "{}", said[0]);
    assert!(said[0].contains("slowest part: agent start 2.9 s"), "{}", said[0]);

    watch.advance(60_000);
    watch.span("new chat", Some("chat.first_token"), 900.0, &parts, Value::Null);
    assert_eq!(notes(&watch).len(), 1, "a span under budget said something");
    let spans: Vec<Value> = events(&watch).into_iter().filter(|e| e["kind"] == "span").collect();
    assert_eq!(spans.len(), 2, "every span is in the stream, judged or not");
    assert_eq!(spans[0]["parts"][1]["name"], "agent start");
    assert_eq!(spans[1]["over"], false);
}

#[test]
fn a_note_is_said_once_per_quiet_window_and_the_minute_has_a_cap() {
    let watch = watch_on();
    for _ in 0..5 {
        watch.span("switch", Some("workspace.switch"), 400.0, &[], Value::Null);
        watch.advance(1_000);
    }
    assert_eq!(notes(&watch).len(), 1, "the same note was said again within its quiet window");
    watch.advance(NOTE_QUIET_MS);
    watch.span("switch", Some("workspace.switch"), 400.0, &[], Value::Null);
    assert_eq!(notes(&watch).len(), 2);

    // Many different subjects in one minute: NOTES_PER_MINUTE are said, the rest counted.
    let watch = watch_on();
    for i in 0..(NOTES_PER_MINUTE + 7) {
        watch.span(&format!("span {i}"), Some("page.load"), 5_000.0, &[], Value::Null);
    }
    assert_eq!(notes(&watch).len(), NOTES_PER_MINUTE);
    watch.advance(61_000);
    watch.span("later", Some("page.load"), 5_000.0, &[], Value::Null);
    let last = events(&watch).into_iter().rev().find(|e| e["kind"] == "note").unwrap_or_default();
    assert_eq!(last["quietedBefore"], 7, "the next note says how many were quieted");
}

#[test]
fn a_send_that_reads_the_whole_chat_log_three_times_is_named() {
    // #46010's shape: each resend made three keyed scans of a 7,338-record coordinator chat.
    let watch = watch_on();
    for _ in 0..3 {
        watch.log_read("019a5f3e-coordinator", 7_338, 4 << 20, true, Duration::from_micros(7_700));
        watch.advance(2);
    }
    let said = notes(&watch);
    assert!(
        said.iter()
            .any(|n| n.contains("read the whole chat log of 019a5f3e: 7,338 records, 4.0 MB")),
        "{said:?}"
    );
    assert!(
        said.iter().any(|n| n.contains("read chat 019a5f3e's whole log 3 times within a second")),
        "{said:?}"
    );
    // A read from a later seq, and short whole reads, are never re-reads.
    let watch = watch_on();
    for _ in 0..5 {
        watch.log_read("small", 40, 4_000, true, Duration::from_micros(30));
        watch.log_read("tail", 9_000, 9 << 20, false, Duration::from_micros(30));
    }
    assert!(notes(&watch).is_empty(), "{:?}", notes(&watch));
}

#[test]
fn the_meter_ranks_hot_zones_and_names_a_reply_far_larger_than_its_view() {
    let watch = watch_on();
    // The session list sent 1.9 GB in 7.7 minutes: about 4 MB a second to one client.
    for _ in 0..10 {
        watch.bytes(channel::IPC, "reply to _acpmux/sessions \u{2192} acpmux-ls", 4 << 20);
        watch.bytes(channel::PEER, "session/update \u{2192} cloud-1", 2_000);
        watch.advance(1_000);
    }
    let snap = watch.snapshot();
    let top = snap["meter"].as_array().cloned().unwrap_or_default();
    assert_eq!(top[0]["label"], "reply to _acpmux/sessions \u{2192} acpmux-ls");
    assert_eq!(top[0]["bytesPerMinute"], 40u64 << 20);
    assert_eq!(top[1]["channel"], channel::PEER);
    let said = notes(&watch);
    assert!(
        said.iter().any(|n| n
            .starts_with("reply to _acpmux/sessions \u{2192} acpmux-ls was 4.0 MB in one message")),
        "{said:?}"
    );
    assert!(said.iter().any(|n| n.starts_with("hot zone: reply to _acpmux/sessions")), "{said:?}");
    // Past a minute the old seconds fall out of the ranking.
    watch.advance(61_000);
    watch.bytes(channel::IPC, "small", 10);
    let top = watch.snapshot()["meter"].as_array().cloned().unwrap_or_default();
    assert_eq!(top.len(), 1);
    assert_eq!(top[0]["label"], "small");
}

#[test]
fn a_page_report_names_rerenders_stalls_and_shifts_after_paint() {
    let watch = watch_on();
    watch.report(
        "chat",
        &json!({
            "windowMs": 200,
            "renders": {"SessionList": 14, "Composer": 2},
            "frames": [12.0, 180.0, 70.0],
            "layoutShifts": [{"score": 0.2, "afterPaint": true, "what": "transcript"}, {"score": 0.5, "afterPaint": false}],
            "spans": [{"name": "page load", "budget": "page.load", "ms": 1_300.0,
                       "parts": [{"name": "connect", "startMs": 0, "ms": 900}, {"name": "first paint", "startMs": 900, "ms": 400}]}],
            "bytes": [{"label": "_acpmux/rows", "bytes": 2048}],
        }),
    );
    let said = notes(&watch);
    assert!(said.iter().any(|n| n == "SessionList re-rendered 14 times in 200 ms"), "{said:?}");
    assert!(!said.iter().any(|n| n.contains("Composer")), "{said:?}");
    assert!(
        said.iter()
            .any(|n| n.contains("main thread stalled 180 ms on a chat page (2 frames over 50 ms)")),
        "{said:?}"
    );
    assert!(
        said.iter().any(|n| n.contains("layout shifted after paint (transcript, score 0.20)")),
        "{said:?}"
    );
    assert!(
        said.iter().any(|n| n.contains("chat page load to first paint took 1.3 s")),
        "{said:?}"
    );
    assert_eq!(said.len(), 4, "{said:?}");
    let top = watch.snapshot()["meter"].as_array().cloned().unwrap_or_default();
    assert_eq!(top[0]["channel"], channel::BRIDGE);
}

#[test]
fn a_request_over_budget_is_a_span_and_waits_by_design_are_not() {
    let watch = watch_on();
    watch.request("_acpmux/sessions", "Local", Duration::from_millis(340), true);
    watch.request("_acpmux/info", "Local", Duration::from_millis(20), false);
    watch.request("_acpmux/wait", "Local", Duration::from_secs(20), false);
    watch.request("session/prompt", "LocalApp", Duration::from_secs(20), false);
    watch.request("session/new", "LocalApp", Duration::from_millis(80), false);
    let names: Vec<String> = events(&watch)
        .into_iter()
        .filter(|e| e["kind"] == "span")
        .filter_map(|e| e["name"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(names, ["request _acpmux/sessions", "daemon session/new"]);
    assert!(
        notes(&watch)
            .iter()
            .any(|n| n.contains("a cheap read (status, the session list) took 340 ms"))
    );
}

#[test]
fn reads_follow_by_seq_and_a_waiting_read_wakes_on_the_next_event() {
    let watch = std::sync::Arc::new(watch_on());
    watch.span("a", None, 1.0, &[], Value::Null);
    let first = watch.read(0, 10);
    let seq = first["seq"].as_u64().unwrap_or(0);
    // The span, then the meter's first summary.
    assert_eq!(first["events"][0]["name"], "a");
    assert_eq!(first["events"][1]["kind"], "meter");
    assert_eq!(watch.read(seq, 10)["events"], json!([]));

    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build();
    let Ok(runtime) = runtime else { panic!("runtime") };
    runtime.block_on(async {
        let waiter = {
            let watch = watch.clone();
            tokio::spawn(async move { watch.read_wait(seq, 10, Duration::from_secs(5)).await })
        };
        tokio::task::yield_now().await;
        watch.span("b", None, 1.0, &[], Value::Null);
        let read = tokio::time::timeout(Duration::from_secs(5), waiter).await;
        let Ok(Ok(read)) = read else { panic!("the waiting read did not wake") };
        assert_eq!(read["events"][0]["name"], "b");
        // Nothing new: the wait ends at its bound with no events.
        let started = Instant::now();
        let empty =
            watch.read_wait(read["seq"].as_u64().unwrap_or(0), 10, Duration::from_millis(50)).await;
        assert_eq!(empty["events"], json!([]));
        assert!(started.elapsed() >= Duration::from_millis(40));
    });
}

#[test]
fn the_tail_file_gets_each_event_as_a_line() {
    let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let path = dir.path().join("perf-watch.jsonl");
    let watch = Watch::with_clock(START_MS);
    let status = watch.set(true, Some(path.clone()));
    assert_eq!(status["file"], path.display().to_string());
    watch.span("page load", Some("page.load"), 2_000.0, &[], Value::Null);
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let lines: Vec<Value> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    assert!(lines.iter().any(|l| l["kind"] == "span" && l["name"] == "page load"), "{text}");
    assert!(lines.iter().any(|l| l["kind"] == "note"), "{text}");
    // Off and on again starts fresh.
    watch.set(false, None);
    watch.set(true, Some(path.clone()));
    assert_eq!(std::fs::read_to_string(&path).unwrap_or_default(), "");
}

/// The cost while on, per metered send: the busiest path is every streamed token per attached
/// connection (`Conn::send_line`). At 2,000 metered sends a second (several chats streaming to
/// several pages) the watch must stay under 1% of one core: under 5 us a send. Debug builds are
/// several times slower; the bound scales.
#[test]
fn the_watch_costs_under_one_percent_of_a_core_while_on() {
    let watch = watch_on();
    let labels: Vec<String> =
        (0..40).map(|i| format!("session/update \u{2192} client-{i}")).collect();
    let sends = 200_000u32;
    let started = Instant::now();
    for i in 0..sends {
        watch.bytes(channel::IPC, &labels[i as usize % labels.len()], 900);
    }
    let per_send = started.elapsed() / sends;
    let rate = 2_000.0;
    let share = per_send.as_secs_f64() * rate;
    eprintln!(
        "perf watch on: {per_send:?} a metered send, {:.3}% of a core at {rate} sends/s",
        share * 100.0
    );
    let bound = if cfg!(debug_assertions) { 0.05 } else { 0.01 };
    assert!(share < bound, "{per_send:?} a send is {:.2}% of a core", share * 100.0);
}

#[test]
fn a_full_meter_gives_an_idle_label_s_slot_to_a_new_one() {
    let watch = watch_on();
    for i in 0..METER_KEYS {
        watch.bytes(channel::IPC, &format!("old client {i}"), 10);
    }
    watch.bytes(channel::IPC, "new client", 10);
    let labels = |watch: &Watch| -> Vec<String> {
        watch.snapshot()["meter"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|z| z["label"].as_str().map(str::to_owned))
            .collect()
    };
    assert!(!labels(&watch).contains(&"new client".to_owned()), "every label is still busy");
    watch.advance(61_000);
    watch.bytes(channel::IPC, "new client", 10);
    assert_eq!(labels(&watch), ["new client"]);
}

#[cfg(unix)]
#[test]
fn the_tail_file_is_its_owner_s_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let path = dir.path().join("perf-watch.jsonl");
    let watch = Watch::with_clock(START_MS);
    watch.set(true, Some(path.clone()));
    let mode = std::fs::metadata(&path).map(|m| m.permissions().mode() & 0o777).unwrap_or(0);
    assert_eq!(mode, 0o600);
}
