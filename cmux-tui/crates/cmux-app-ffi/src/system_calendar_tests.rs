use super::*;

fn record(id: &str, start: f64, end: f64) -> Record {
    Record {
        id: id.into(),
        title: format!("t-{id}"),
        start,
        end,
        all_day: false,
        calendar: "Work".into(),
        location: None,
        url: None,
        color: None,
    }
}

fn run(op: &str, request: Value) -> Result<Value, i32> {
    let op = std::ffi::CString::new(op).unwrap();
    let bytes = serde_json::to_vec(&request).unwrap();
    let mut out = CmuxSystemCalendarBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let code =
        unsafe { cmux_system_calendar_call(op.as_ptr(), bytes.as_ptr(), bytes.len(), &mut out) };
    if code != CMUX_SYSTEM_CALENDAR_OK {
        return Err(code);
    }
    // SAFETY: from the call, freed once below.
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    unsafe { cmux_system_calendar_bytes_free(out) };
    Ok(serde_json::from_slice(&reply).unwrap())
}

#[test]
fn the_window_defaults_and_refuses_bad_params() {
    let reply = run("window", json!({"now": 1000.0})).unwrap();
    assert_eq!(
        reply,
        json!({"days": 7, "limit": 20, "start": 1000.0, "end": 1000.0 + 7.0 * 86_400.0})
    );
    let reply = run("window", json!({"now": 0.0, "params": {"days": 31, "limit": null}})).unwrap();
    assert_eq!((reply["days"].clone(), reply["limit"].clone()), (json!(31), json!(20)));
    for (params, message) in [
        (json!({"days": 0}), "days is a whole number from 1 to 31"),
        (json!({"days": 32}), "days is a whole number from 1 to 31"),
        (json!({"days": 1.5}), "days is a whole number from 1 to 31"),
        (json!({"days": "3"}), "days is a whole number from 1 to 31"),
        (json!({"limit": 51}), "limit is a whole number from 1 to 50"),
        (json!({"limit": true}), "limit is a whole number from 1 to 50"),
        (json!([1]), "system_calendar.events takes an object"),
    ] {
        let reply = run("window", json!({"now": 0.0, "params": params})).unwrap();
        assert_eq!(
            reply,
            json!({"error": {"code": "invalid_params", "message": message}}),
            "{params}"
        );
    }
    assert_eq!(run("window", json!({})), Err(CMUX_SYSTEM_CALENDAR_ERR_INVALID));
    assert_eq!(run("nope", json!({})), Err(CMUX_SYSTEM_CALENDAR_ERR_UNKNOWN_OP));
}

#[test]
fn only_granted_access_gets_events() {
    for access in ["denied", "restricted", "notDetermined", "unavailable"] {
        let reply = answer(access, vec![record("a", 10.0, 20.0)], 0.0, 7, 20);
        assert_eq!(reply, json!({"access": access, "events": []}));
    }
}

#[test]
fn events_are_windowed_sorted_and_limited() {
    let now = 1_000_000.0;
    let records = vec![
        record("ended", now - 100.0, now),
        record("later", now + 50.0, now + 60.0),
        record("running", now - 10.0, now + 10.0),
        record("b", now + 50.0, now + 60.0),
        record("too-far", now + 2.0 * DAY_SECONDS, now + 2.0 * DAY_SECONDS + 1.0),
        record("shorter", now + 50.0, now + 55.0),
    ];
    let reply = answer("granted", records.clone(), now, 1, 20);
    let ids: Vec<&str> =
        reply["events"].as_array().unwrap().iter().map(|e| e["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["running", "shorter", "b", "later"]);
    let reply = answer("granted", records, now, 1, 2);
    assert_eq!(reply["events"].as_array().unwrap().len(), 2);
}

#[test]
fn an_event_has_capped_text_and_no_empty_optionals() {
    let mut long = record(&"i".repeat(300), 1.0005, 2.0);
    long.title = "\u{1F44D}\u{1F3FD}".repeat(250);
    long.location = Some("  Room 1 \n".into());
    long.url = Some("https://x".into());
    long.color = Some("#a1B2c3".into());
    long.all_day = true;
    let event = event(&long);
    assert_eq!(event["id"].as_str().unwrap().len(), MAX_TEXT);
    assert_eq!(event["title"].as_str().unwrap().graphemes(true).count(), MAX_TEXT);
    assert_eq!(event["start"], json!(1001.0));
    assert_eq!(event["end"], json!(2000.0));
    assert_eq!(event["allDay"], json!(true));
    assert_eq!(event["location"], json!("Room 1"));
    assert_eq!(event["url"], json!("https://x"));
    assert_eq!(event["color"], json!("#a1B2c3"));

    let mut empty = record("e", 1.0, 2.0);
    empty.location = Some(" \n".into());
    empty.url = Some(format!("https://{}", "x".repeat(MAX_URL)));
    empty.color = Some("red".into());
    let event = super::event(&empty);
    for key in ["location", "url", "color"] {
        assert!(event.get(key).is_none(), "{key}");
    }
}

#[test]
fn the_answer_op_reads_the_apps_records() {
    let reply = run(
        "answer",
        json!({"access": "granted", "now": 0.0, "days": 7, "limit": 20, "records": [
            {"id": "x@1", "title": "T", "start": 1.0, "end": 2.0, "allDay": false, "calendar": "C"}
        ]}),
    )
    .unwrap();
    assert_eq!(
        reply,
        json!({"access": "granted", "events": [
            {"id": "x@1", "title": "T", "start": 1000.0, "end": 2000.0, "allDay": false, "calendar": "C"}
        ]})
    );
}
