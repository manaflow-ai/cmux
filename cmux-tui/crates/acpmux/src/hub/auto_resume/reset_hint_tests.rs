use super::*;
#[test]
fn parses_router_claude_and_http_hints() {
    assert_eq!(reset_at("503 retry after 2401s", None, 1000), Some(2_402_000));
    assert_eq!(
        reset_at("usage limit|1760000000", None, 1_759_999_500_000),
        Some(1_760_000_000_000)
    );
    assert_eq!(reset_at("Retry-After: 2m", None, 1000), Some(121_000));
    assert_eq!(reset_at("Retry-After: 500 milliseconds", None, 1000), Some(1500));
    assert_eq!(reset_at("Retry-After: 999999999999999999d", None, 1000), None);
    assert_eq!(reset_at("Retry-After: 999999999999", None, 1000), None);
    assert_eq!(
        reset_at("You've hit your limit · resets 3pm", None, 12 * 3_600_000),
        Some(15 * 3_600_000)
    );
    assert_eq!(
        reset_at("You've hit your limit · resets 3pm", None, 16 * 3_600_000),
        Some(39 * 3_600_000)
    );
    let now = time::PrimitiveDateTime::new(
        time::Date::from_calendar_date(2026, time::Month::October, 30).unwrap(),
        time::Time::from_hms(12, 0, 0).unwrap(),
    )
    .assume_utc()
    .unix_timestamp_nanos() as u64
        / 1_000_000;
    assert_eq!(
        reset_at("You've hit your limit · resets 3pm (America/Los_Angeles)", None, now,),
        Some(now + 10 * 3_600_000)
    );
    assert_eq!(
        reset_at("You've hit your limit · resets 3pm (Europe/London)", None, now,),
        Some(now + 3 * 3_600_000)
    );
    let spring = time::PrimitiveDateTime::new(
        time::Date::from_calendar_date(2026, time::Month::March, 8).unwrap(),
        time::Time::from_hms(7, 30, 0).unwrap(),
    )
    .assume_utc()
    .unix_timestamp_nanos() as u64
        / 1_000_000;
    assert_eq!(
        reset_at("You've hit your limit · resets 12am (America/Los_Angeles)", None, spring,),
        Some(spring + 30 * 60_000)
    );
    let fall = time::PrimitiveDateTime::new(
        time::Date::from_calendar_date(2026, time::Month::November, 1).unwrap(),
        time::Time::from_hms(6, 30, 0).unwrap(),
    )
    .assume_utc()
    .unix_timestamp_nanos() as u64
        / 1_000_000;
    assert_eq!(
        reset_at("You've hit your limit · resets 3am (America/New_York)", None, fall,),
        Some(fall + 90 * 60_000)
    );
    let fall_back = time::PrimitiveDateTime::new(
        time::Date::from_calendar_date(2026, time::Month::November, 1).unwrap(),
        time::Time::from_hms(5, 45, 0).unwrap(),
    )
    .assume_utc()
    .unix_timestamp_nanos() as u64
        / 1_000_000;
    assert_eq!(
        reset_at("You've hit your limit · resets 1:30am (America/New_York)", None, fall_back,),
        Some(fall_back + 45 * 60_000)
    );
    assert_eq!(
        reset_at("You've hit your limit · resets 3pm (Europe/Berlin)", None, now,),
        Some(now + 2 * 3_600_000)
    );
    assert_eq!(reset_at("You've hit your limit · resets 3pm (€a)", None, now), None);
    let usage = serde_json::json!({
        "windows": [
            {"usedPercent": 100, "resetsAt": 1},
            {"usedPercent": 100, "resetsAt": 200},
            {"usedPercent": 100, "resetsAt": 300}
        ]
    });
    assert_eq!(reset_at("usage limit", Some(&usage), 150_000), Some(300_000));
    let far_usage = serde_json::json!({
        "windows": [{"usedPercent": 100, "resetsAt": 9_999_999_999u64}]
    });
    assert_eq!(reset_at("usage limit", Some(&far_usage), 0), None);
    assert_eq!(error_reset_at(Some(&serde_json::json!({"Retry-After":"2m"})), 1000), Some(121_000));
    assert_eq!(error_reset_at(Some(&serde_json::json!({"Retry-After":"500ms"})), 1000), Some(1500));
    assert_eq!(
        error_reset_at(Some(&serde_json::json!({"Retry-After":999999999999u64})), 1000),
        None
    );
    assert_eq!(
        error_reset_at(Some(&serde_json::json!({"details":{"Retry-After":"120"}})), 1000),
        Some(121_000)
    );
    assert_eq!(
        error_reset_at(
            Some(&serde_json::json!({"Retry-After":"Sun, 06 Nov 1994 08:49:37 GMT"})),
            784111000000
        ),
        Some(784111777000)
    );
    assert_eq!(
        reset_at(
            "limit",
            Some(&serde_json::json!({"windows":[{"usedPercent":100,"resetsAt":200}]})),
            0
        ),
        Some(200_000)
    );
}
