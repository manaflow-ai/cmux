use super::*;

#[test]
fn events_params_are_filled_in_and_bounded() {
    assert_eq!(
        normalize(EVENTS, &Value::Null).unwrap(),
        json!({ "days": DEFAULT_DAYS, "limit": DEFAULT_LIMIT })
    );
    assert_eq!(
        normalize(EVENTS, &json!({ "days": 2, "limit": null })).unwrap(),
        json!({ "days": 2, "limit": DEFAULT_LIMIT })
    );
    for bad in [
        json!({ "days": 0 }),
        json!({ "days": MAX_DAYS + 1 }),
        json!({ "days": 1.5 }),
        json!({ "days": "2" }),
        json!({ "limit": 0 }),
        json!({ "limit": MAX_LIMIT + 1 }),
        json!({ "days": 2, "calendar": "Work" }),
        json!([2, 20]),
    ] {
        assert_eq!(normalize(EVENTS, &bad).unwrap_err()["code"], "validation.invalid", "{bad}");
    }
}

#[test]
fn request_access_takes_no_params() {
    assert_eq!(normalize(REQUEST_ACCESS, &Value::Null).unwrap(), json!({}));
    assert!(normalize(REQUEST_ACCESS, &json!({ "silent": true })).is_err());
    assert_eq!(
        normalize("system_calendar.event.create", &json!({})).unwrap_err()["code"],
        "operation.unsupported"
    );
}

#[test]
fn only_granted_answers_are_cached_and_access_clears_them() {
    let mut cache = Cache::default();
    let now = Instant::now();
    let key = cache_key(EVENTS, &normalize(EVENTS, &Value::Null).unwrap()).unwrap();
    let asking = json!({ "value": { "access": "notDetermined", "events": [] } });
    cache.record(EVENTS, Some(&key), true, &asking, now);
    assert_eq!(cache.hit(&key, now), None, "a not-granted answer is read again");
    let granted = json!({ "value": { "access": "granted", "events": [] } });
    cache.record(EVENTS, Some(&key), true, &granted, now);
    assert_eq!(cache.hit(&key, now + Duration::from_secs(1)), Some(granted.clone()));
    assert_eq!(cache.hit(&key, now + CACHE_TTL), None, "stale after the TTL");
    cache.record(EVENTS, Some(&key), true, &granted, now);
    cache.record(REQUEST_ACCESS, None, true, &json!({ "value": { "access": "denied" } }), now);
    assert_eq!(cache.hit(&key, now), None, "an access change clears the cache");
}

#[test]
fn the_cache_keeps_a_bounded_number_of_reads() {
    let mut cache = Cache::default();
    let now = Instant::now();
    let granted = json!({ "value": { "access": "granted", "events": [] } });
    let key = |days: u64| cache_key(EVENTS, &json!({ "days": days, "limit": 20 })).unwrap();
    for days in 1..=(CACHE_ENTRIES as u64 + 4) {
        cache.record(EVENTS, Some(&key(days)), true, &granted, now);
    }
    assert_eq!(cache.entries.len(), CACHE_ENTRIES);
    assert_eq!(cache.hit(&key(1), now), None, "the oldest read went first");
}
