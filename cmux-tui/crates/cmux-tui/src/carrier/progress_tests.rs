use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use tokio::time::Instant;

use super::super::client::Marks;
use super::{Expected, Reporter, Stage, WAKE_AFTER, line, spoken, stage_of};

const MS: fn(u64) -> Duration = Duration::from_millis;

fn progress(line: &str) -> Value {
    assert!(line.ends_with('\n') && !line.trim_end().contains('\n'), "{line:?}");
    let value: Value = serde_json::from_str(line.trim_end()).expect("one JSON line");
    assert!(value.get("ok").is_none(), "a progress line is never a reply line: {line}");
    value.get("progress").cloned().expect("a progress object")
}

fn text(line: &str) -> String {
    progress(line).get("text").and_then(Value::as_str).unwrap_or_default().to_owned()
}

#[test]
fn an_attempt_s_marks_name_its_stage_and_the_time_in_it() {
    let t0 = Instant::now();
    let at = |ms| Some(t0 + MS(ms));
    let now = t0 + MS(10_000);
    assert_eq!(
        stage_of(&Marks { started: at(9_000), ..Marks::default() }, now),
        (Stage::Access, MS(1_000))
    );
    let answered = Marks { started: at(0), answered: at(9_500), ..Marks::default() };
    assert_eq!(stage_of(&answered, now), (Stage::Relay, MS(500)));
    // A short hold reaches the machine; past WAKE_AFTER it wakes it, counted
    // from the hold's start.
    let held = Marks { relay_up: at(9_000), first_open: at(9_000), ..answered };
    assert_eq!(stage_of(&held, now), (Stage::Machine, MS(1_000)));
    let waking = Marks { first_open: at(1_000), ..held };
    assert_eq!(stage_of(&waking, now), (Stage::Waking, MS(9_000)));
    assert!(MS(9_000) >= WAKE_AFTER);
    let allocated = Marks { first_allocated: at(9_900), ..waking };
    assert_eq!(stage_of(&allocated, now), (Stage::Securing, MS(100)));
    let connected = Marks { connected: at(9_950), ..allocated };
    assert_eq!(stage_of(&connected, now).0, Stage::Securing);
}

#[test]
fn durations_read_as_whole_seconds_at_least_one() {
    assert_eq!(spoken(MS(0)), "1 s");
    assert_eq!(spoken(MS(1_200)), "2 s");
    assert_eq!(spoken(MS(25_000)), "25 s");
    assert_eq!(spoken(MS(60_000)), "1 min");
    assert_eq!(spoken(MS(160_000)), "2 min 40 s");
}

#[test]
fn a_waking_machine_says_why_and_how_long_is_left() {
    let expected = Expected::default();
    let line = line(Stage::Waking, MS(5_000), MS(170_000), &expected, true);
    let value = progress(&line);
    assert_eq!(value.get("stage").and_then(Value::as_str), Some("waking"));
    // The rest of the usual wake, then the handshake and the desktop's open.
    let eta = expected.waking - MS(5_000) + expected.securing + expected.desktop;
    assert_eq!(value.get("eta_ms").and_then(Value::as_u64), Some(eta.as_millis() as u64));
    assert_eq!(value.get("deadline_ms").and_then(Value::as_u64), Some(170_000));
    assert_eq!(text(&line), format!("Waking up the machine, about {} left", spoken(eta)));
}

#[test]
fn every_stage_has_a_reason_and_an_eta_inside_the_deadline() {
    let expected = Expected::default();
    for stage in [
        Stage::Access,
        Stage::Relay,
        Stage::Machine,
        Stage::Waking,
        Stage::Securing,
        Stage::Desktop,
        Stage::Retrying,
    ] {
        let line = line(stage, MS(0), MS(4_000), &expected, true);
        let value = progress(&line);
        assert_eq!(value.get("stage").and_then(Value::as_str), Some(stage.id()));
        assert!(text(&line).starts_with(stage.reason()), "{line}");
        assert!(text(&line).contains(" left"), "{line}");
        let eta = value.get("eta_ms").and_then(Value::as_u64).unwrap_or(u64::MAX);
        assert!(eta <= 4_000, "{line}");
    }
}

#[test]
fn a_stage_past_its_usual_time_says_so_and_when_the_dial_stops() {
    let expected = Expected::default();
    let late = line(Stage::Waking, expected.waking + MS(5_000), MS(130_000), &expected, true);
    assert_eq!(
        text(&late),
        "Waking up the machine: taking longer than usual, stops trying in 2 min 10 s"
    );
    assert_eq!(progress(&late).get("eta_ms").and_then(Value::as_u64), Some(130_000));
    // A short hold never reads late: past WAKE_AFTER it is waking.
    let short = line(Stage::Machine, MS(1_900), MS(170_000), &expected, true);
    assert!(text(&short).starts_with("Reaching the machine, about"), "{short}");
}

#[test]
fn the_usual_times_come_from_this_mac_s_successful_connects() {
    let ok = |ticket, parked, handshake, mux| {
        format!(
            "carrier.phases machine=vm_0123456789abcdefghij phase=connect carrier=relay:0 outcome=ok ticket_ms={ticket} relay_ms=40 parked_ms={parked} handshake_ms={handshake} mux_ms={mux} lanes=3 ms=1\n"
        )
    };
    let mut log = String::new();
    log += "cloud.connect route=carrier machine=vm_0123456789abcdefghij phase=connect outcome=ok ms=1\n";
    log += "carrier.phases machine=vm_0123456789abcdefghij phase=connect carrier=relay:0 outcome=parked_timeout ticket_ms=9 relay_ms=9 parked_ms=180000 handshake_ms=0 mux_ms=0 lanes=0 ms=1\n";
    for (ticket, parked, handshake, mux) in [
        (300, 100, 200, 20),
        (500, 12_000, 250, 30),
        (400, 120, 300, 40),
        (900, 14_000, 260, 50),
        (350, 16_000, 240, 60),
    ] {
        log += &ok(ticket, parked, handshake, mux);
    }
    let expected = Expected::from_log(&log);
    assert_eq!(expected.access, MS(400));
    assert_eq!(expected.relay, MS(40));
    // Three holds woke a machine (the failed attempt's does not count); two
    // short holds are too few, so that one keeps its default.
    assert_eq!(expected.waking, MS(14_000));
    assert_eq!(expected.parked, Expected::default().parked);
    assert_eq!(expected.securing, MS(300));
    assert_eq!(expected.desktop, MS(40));
    assert_eq!(Expected::from_log(""), Expected::default());
    assert_eq!(Expected::read(None), Expected::default());
}

#[tokio::test]
async fn the_reporter_writes_on_change_and_nothing_after_stop() {
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let reporter = Reporter::new(
        Expected::default(),
        Instant::now() + Duration::from_secs(180),
        true,
        move |line| sink.lock().expect("lines").push(line.to_owned()),
    );
    reporter.tick();
    reporter.tick();
    let count = || lines.lock().expect("lines").len();
    assert_eq!(count(), 1, "the same text is written once");
    reporter.desktop();
    reporter.tick();
    assert_eq!(count(), 2);
    let last = lines.lock().expect("lines").last().cloned().unwrap_or_default();
    assert!(text(&last).starts_with("Opening the desktop"), "{last}");
    reporter.retrying();
    reporter.stop();
    reporter.tick();
    assert_eq!(count(), 2, "no line after stop");
}
