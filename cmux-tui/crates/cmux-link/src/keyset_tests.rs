//! The keyset reader against schemas/link-token/keyset-vectors.json (read
//! from its repo path, never copied) and the refresh schedule with times
//! passed in (no sleeps).

use super::*;

/// The vectors file, byte for byte from its repo path.
const VECTORS: &str = include_str!("../../../../schemas/link-token/keyset-vectors.json");

fn answer(raw: &Value) -> Result<Keyset, KeysetRefused> {
    let status = u16::try_from(raw["status"].as_u64().unwrap()).unwrap();
    let headers: Vec<(String, String)> = raw["headers"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, value)| (name.clone(), value.as_str().unwrap().to_string()))
        .collect();
    let body = serde_json::to_vec(&raw["body"]).unwrap();
    read_answer(status, &headers, &body)
}

fn keyset(version: &str, kids: &[&str]) -> Keyset {
    Keyset {
        version: version.to_string(),
        keys: kids.iter().map(|kid| ((*kid).to_string(), [7; 32])).collect(),
    }
}

/// The held keyset of a bound host before any answer.
fn bound() -> Keyset {
    keyset("00000000000000aa", &["bind-k0"])
}

/// RED: every vector answer reads as the file expects; only an `ok: true`
/// read replaces the held keyset, every other one keeps it.
#[test]
fn every_vector_answer_reads_as_expected_and_only_ok_replaces_the_held_keyset() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 9, "the vectors file looks truncated");
    let now = Instant::now();
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let mut refresh = KeysetRefresh::at_bind(bound(), now, Duration::ZERO);
        for raw in case["answers"].as_array().unwrap() {
            let expect = &raw["expect"];
            let before = refresh.held().clone();
            let read = answer(raw);
            if expect["ok"] == Value::Bool(true) {
                let keyset = read.clone().unwrap_or_else(|error| panic!("{name}: {error:?}"));
                assert_eq!(keyset.version, expect["version"].as_str().unwrap(), "{name}");
                let kids = expect["kids"].as_array().unwrap();
                let kids: Vec<&str> = kids.iter().map(|kid| kid.as_str().unwrap()).collect();
                assert_eq!(keyset.kids(), kids, "{name}");
                refresh.apply(read, now);
                assert_eq!(refresh.held(), &keyset, "{name}: a 200 replaces the held keyset");
            } else {
                let error = read.clone().expect_err(name);
                assert_eq!(error.as_str(), expect["error"].as_str().unwrap(), "{name}");
                assert_eq!(expect["keep_held"], Value::Bool(true), "{name}");
                if let Some(seconds) = expect["retry_after_s"].as_u64() {
                    assert_eq!(
                        error,
                        KeysetRefused::RateLimited { retry_after: Duration::from_secs(seconds) },
                        "{name}"
                    );
                }
                refresh.apply(read, now);
                assert_eq!(refresh.held(), &before, "{name}: an error keeps the held keyset");
            }
        }
    }
}

/// RED: the reader's own refusals beyond the vectors: a missing alg, a kid
/// field that differs from its map key, a short x, a bad version and no
/// kid at all are refused; a 429 without (or with an invalid) retry-after
/// waits 60 s.
#[test]
fn a_key_or_answer_that_fails_one_check_is_refused_whole() {
    let key = |kid: &str, x: &str| serde_json::json!({"kty": "OKP", "crv": "Ed25519", "x": x, "kid": kid, "alg": "EdDSA"});
    let x = "tRRe5k08ymM7wh1Rh9EZkgf1p8UAskG2c_3dH0bYSGY";
    let good = serde_json::json!({"version": "16f32fd56d465cc3", "keys": {"k1": key("k1", x)}});
    assert_eq!(read_keyset(&good).unwrap().kids(), vec!["k1"]);
    let mut no_alg = good.clone();
    no_alg["keys"]["k1"].as_object_mut().unwrap().remove("alg");
    assert_eq!(read_keyset(&no_alg), Err(KeysetRefused::BadKey));
    let with_key =
        |key: Value| serde_json::json!({"version": "16f32fd56d465cc3", "keys": {"k1": key}});
    let other_kid = with_key(key("k2", x));
    assert_eq!(read_keyset(&other_kid), Err(KeysetRefused::BadKey));
    let short_x = with_key(key("k1", "abc"));
    assert_eq!(read_keyset(&short_x), Err(KeysetRefused::BadKey));
    for version in ["16F32FD56D465CC3", "16f32fd56d465cc", "16f32fd56d465cc3a"] {
        let mut bad = good.clone();
        bad["version"] = Value::from(version);
        assert_eq!(read_keyset(&bad), Err(KeysetRefused::Malformed), "{version}");
    }
    let none = serde_json::json!({"version": "16f32fd56d465cc3", "keys": {}});
    assert_eq!(read_keyset(&none), Err(KeysetRefused::Malformed));
    let waited = |headers: &[(String, String)]| match read_answer(429, headers, b"{}") {
        Err(KeysetRefused::RateLimited { retry_after }) => retry_after,
        other => panic!("{other:?}"),
    };
    assert_eq!(waited(&[]), DEFAULT_RETRY_AFTER);
    assert_eq!(waited(&[("Retry-After".into(), "soon".into())]), DEFAULT_RETRY_AFTER);
    assert_eq!(waited(&[("Retry-After".into(), "0".into())]), DEFAULT_RETRY_AFTER);
    assert_eq!(waited(&[("retry-after".into(), "120".into())]), Duration::from_secs(120));
}

/// RED: an unknown kid fetches at most once per 60 s; a known kid never
/// fetches.
#[test]
fn an_unknown_kid_fetches_at_most_once_per_60_seconds() {
    let t0 = Instant::now();
    let mut refresh = KeysetRefresh::at_bind(bound(), t0, Duration::from_secs(3600));
    assert!(!refresh.on_unknown_kid("bind-k0", t0), "a held kid never fetches");
    assert!(refresh.on_unknown_kid("new-k1", t0));
    assert!(!refresh.on_unknown_kid("new-k1", t0 + Duration::from_secs(1)));
    assert!(!refresh.on_unknown_kid("other-k2", t0 + Duration::from_secs(59)));
    assert!(refresh.on_unknown_kid("new-k1", t0 + Duration::from_secs(60)));
    assert!(!refresh.on_unknown_kid("new-k1", t0 + Duration::from_secs(119)));
}

/// RED: a 429 holds every fetch (unknown kid and daily) until its
/// retry-after, and keeps the held keyset.
#[test]
fn a_429_holds_every_fetch_until_its_retry_after() {
    let t0 = Instant::now();
    let mut refresh = KeysetRefresh::at_bind(bound(), t0, Duration::ZERO);
    assert!(refresh.on_daily_deadline(t0));
    refresh.apply(Err(KeysetRefused::RateLimited { retry_after: Duration::from_secs(300) }), t0);
    assert_eq!(refresh.held(), &bound());
    assert!(!refresh.on_unknown_kid("new-k1", t0 + Duration::from_secs(120)), "inside the hold");
    assert!(refresh.on_unknown_kid("new-k1", t0 + Duration::from_secs(300)), "the hold ended");
    // A daily deadline that falls inside a hold waits for the hold's end.
    let day = t0 + REFRESH_PERIOD;
    refresh.apply(Err(KeysetRefused::RateLimited { retry_after: Duration::from_secs(90) }), day);
    assert_eq!(refresh.next_wakeup(), day + Duration::from_secs(90));
    assert!(!refresh.on_daily_deadline(day));
    assert!(refresh.on_daily_deadline(day + Duration::from_secs(90)));
}

/// RED: an error keeps the held keyset; a 200 replaces it.
#[test]
fn an_error_keeps_the_held_keyset_and_a_200_replaces_it() {
    let t0 = Instant::now();
    let mut refresh = KeysetRefresh::at_bind(bound(), t0, Duration::ZERO);
    for refused in [KeysetRefused::Unavailable, KeysetRefused::Malformed, KeysetRefused::BadKey] {
        refresh.apply(Err(refused), t0);
        assert_eq!(refresh.held(), &bound(), "{refused:?}");
    }
    let next = keyset("16f32fd56d465cc3", &["test-k1", "test-k2"]);
    refresh.apply(Ok(next.clone()), t0);
    assert_eq!(refresh.held(), &next);
    assert!(refresh.key("test-k1").is_some());
    assert!(refresh.key("bind-k0").is_none());
}

/// RED: the daily deadline fires once a day at the jittered time and arms
/// one timer: over ten days of hourly wakeups it fires exactly ten times,
/// and the next wakeup is never more than one day away.
#[test]
fn the_daily_deadline_fires_once_a_day_at_the_jittered_time() {
    let t0 = Instant::now();
    let jitter = daily_jitter("host_abc");
    assert!(jitter < REFRESH_PERIOD);
    assert_ne!(daily_jitter("host_abc"), daily_jitter("host_abd"), "hosts spread over the day");
    let mut refresh = KeysetRefresh::at_bind(bound(), t0, jitter);
    assert_eq!(refresh.next_wakeup(), t0 + jitter);
    let mut fired = Vec::new();
    for hour in 0..(24 * 10) {
        let now = t0 + Duration::from_secs(3600 * hour);
        if refresh.on_daily_deadline(now) {
            fired.push(hour);
        }
        assert!(refresh.next_wakeup() > now);
        assert!(refresh.next_wakeup() <= now + REFRESH_PERIOD);
    }
    assert_eq!(fired.len(), 10, "{fired:?}");
    // A late wakeup (the host slept three days) fetches once and arms the
    // next deadline past now, not three catch-up fetches.
    let late = refresh.next_wakeup() + 3 * REFRESH_PERIOD;
    assert!(refresh.on_daily_deadline(late));
    assert!(!refresh.on_daily_deadline(late));
    assert!(refresh.next_wakeup() > late);
}
