use std::collections::VecDeque;
use std::sync::{Arc, Barrier};
use std::thread;

use super::*;

const URL: &str = "https://api.open-meteo.com/v1/forecast?latitude=1&longitude=2";

/// Answers from a script (the last reply repeats) and records every request;
/// `delay` holds each fetch so concurrent readers meet it in flight.
#[derive(Default)]
struct Scripted {
    replies: Mutex<VecDeque<Result<FetchResponse, EgressError>>>,
    requests: Mutex<Vec<FetchRequest>>,
    delay: Duration,
}

impl Scripted {
    fn new(replies: Vec<Result<FetchResponse, EgressError>>) -> Self {
        Self { replies: Mutex::new(replies.into()), ..Self::default() }
    }

    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

impl Fetcher for Scripted {
    fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, EgressError> {
        self.requests.lock().unwrap().push(request);
        if !self.delay.is_zero() {
            thread::sleep(self.delay);
        }
        let mut replies = self.replies.lock().unwrap();
        if replies.len() > 1 { replies.pop_front().unwrap() } else { replies[0].clone() }
    }
}

fn ok(body: &str, headers: &[(&str, &str)]) -> Result<FetchResponse, EgressError> {
    Ok(FetchResponse {
        status: 200,
        headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        body: body.into(),
    })
}

fn status(code: u16) -> Result<FetchResponse, EgressError> {
    Ok(FetchResponse { status: code, headers: vec![], body: "{}".into() })
}

fn request() -> FetchRequest {
    shared_request(FetchRequest {
        url: URL.into(),
        method: "GET".into(),
        headers: vec![],
        body: None,
    })
    .unwrap()
}

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

#[test]
fn many_readers_at_once_make_one_request_and_share_its_body() {
    let fetcher = Arc::new(Scripted {
        delay: Duration::from_millis(200),
        ..Scripted::new(vec![ok(r#"{"t":21}"#, &[])])
    });
    let cache = Arc::new(HttpCache::default());
    let start = Arc::new(Barrier::new(8));
    let t0 = Instant::now();
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let (fetcher, cache, start) = (fetcher.clone(), cache.clone(), start.clone());
            thread::spawn(move || {
                start.wait();
                cache.get(&*fetcher, request(), t0).unwrap().response.body
            })
        })
        .collect();
    for reader in readers {
        assert_eq!(reader.join().unwrap(), r#"{"t":21}"#);
    }
    assert_eq!(fetcher.count(), 1, "one upstream request for eight readers");
    // Later readers (another app, another mount) hit the cache.
    for _ in 0..20 {
        assert!(cache.get(&*fetcher, request(), t0 + secs(30)).unwrap().hit);
    }
    assert_eq!(fetcher.count(), 1);
}

#[test]
fn the_floor_holds_a_short_max_age_and_a_longer_one_is_honored() {
    let fetcher = Scripted::new(vec![ok("1", &[("Cache-Control", "public, max-age=10")])]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    let first = cache.get(&fetcher, request(), t0).unwrap();
    assert_eq!((first.hit, first.fresh_for), (false, FLOOR));
    assert!(cache.get(&fetcher, request(), t0 + secs(59)).unwrap().hit);
    assert_eq!(fetcher.count(), 1, "max-age=10 is raised to the 60 s floor");
    assert!(!cache.get(&fetcher, request(), t0 + secs(60)).unwrap().hit);
    assert_eq!(fetcher.count(), 2);

    let fetcher = Scripted::new(vec![ok("1", &[("cache-control", "max-age=900")])]);
    let cache = HttpCache::default();
    cache.get(&fetcher, request(), t0).unwrap();
    assert!(cache.get(&fetcher, request(), t0 + secs(899)).unwrap().hit);
    assert_eq!(fetcher.count(), 1, "a longer max-age is honored");
    cache.get(&fetcher, request(), t0 + secs(900)).unwrap();
    assert_eq!(fetcher.count(), 2);
}

#[test]
fn freshness_prefers_s_maxage_takes_off_age_and_is_bounded() {
    let h = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    };
    assert_eq!(freshness(&h(&[])), FLOOR);
    assert_eq!(freshness(&h(&[("Cache-Control", "no-store")])), FLOOR);
    assert_eq!(freshness(&h(&[("Cache-Control", "max-age=300, s-maxage=600")])), secs(600));
    assert_eq!(freshness(&h(&[("Cache-Control", "max-age=300"), ("Age", "100")])), secs(200));
    assert_eq!(freshness(&h(&[("Cache-Control", "max-age=300"), ("Age", "290")])), FLOOR);
    assert_eq!(freshness(&h(&[("Cache-Control", "max-age=99999999")])), MAX_FRESH);
}

#[test]
fn readers_get_the_kept_body_while_it_is_revalidated() {
    let fetcher = Scripted::new(vec![ok("old", &[]), ok("new", &[])]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    cache.get(&fetcher, request(), t0).unwrap();
    // Another reader's revalidation is in flight: this one is answered at once with the old body.
    cache.entries.lock().unwrap().get_mut(URL).unwrap().inflight = true;
    let during = cache.get(&fetcher, request(), t0 + secs(90)).unwrap();
    assert_eq!((during.response.body.as_str(), during.stale, during.hit), ("old", true, true));
    assert_eq!(fetcher.count(), 1, "no second request while one is in flight");
    cache.entries.lock().unwrap().get_mut(URL).unwrap().inflight = false;
    let after = cache.get(&fetcher, request(), t0 + secs(90)).unwrap();
    assert_eq!((after.response.body.as_str(), after.stale), ("new", false));
}

#[test]
fn a_failed_revalidation_serves_the_kept_body_and_is_tried_once_per_floor() {
    let fetcher = Scripted::new(vec![
        ok("good", &[]),
        Err(EgressError { code: "operation.failed", message: "offline".into() }),
        status(503),
        ok("back", &[]),
    ]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    cache.get(&fetcher, request(), t0).unwrap();
    let failed = cache.get(&fetcher, request(), t0 + secs(61)).unwrap();
    assert_eq!((failed.response.body.as_str(), failed.stale), ("good", true));
    // Within the floor after the failure every reader gets the kept body, no request.
    assert!(cache.get(&fetcher, request(), t0 + secs(100)).unwrap().stale);
    assert_eq!(fetcher.count(), 2);
    let server_error = cache.get(&fetcher, request(), t0 + secs(121)).unwrap();
    assert_eq!((server_error.response.status, server_error.stale), (200, true));
    let back = cache.get(&fetcher, request(), t0 + secs(181)).unwrap();
    assert_eq!((back.response.body.as_str(), back.stale), ("back", false));
    assert_eq!(fetcher.count(), 4);
}

#[test]
fn a_cold_failure_is_the_answer_and_is_remembered_for_the_floor() {
    let fetcher = Scripted::new(vec![status(404)]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    assert_eq!(cache.get(&fetcher, request(), t0).unwrap().response.status, 404);
    assert_eq!(cache.get(&fetcher, request(), t0 + secs(30)).unwrap().response.status, 404);
    assert_eq!(fetcher.count(), 1);
    cache.get(&fetcher, request(), t0 + secs(60)).unwrap();
    assert_eq!(fetcher.count(), 2);
}

#[test]
fn bodies_over_the_cap_are_refused_and_not_kept() {
    let big = "x".repeat(MAX_BODY + 1);
    let fetcher = Scripted::new(vec![ok(&big, &[])]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    assert_eq!(cache.get(&fetcher, request(), t0).unwrap_err().code, "app.limit");
    assert_eq!(cache.get(&fetcher, request(), t0 + secs(10)).unwrap_err().code, "app.limit");
    assert_eq!(fetcher.count(), 1);
    assert!(cache.entries.lock().unwrap()[URL].kept.is_none());
}

#[test]
fn revalidation_is_conditional_and_a_304_keeps_the_body() {
    let fetcher = Scripted::new(vec![
        ok(
            "body",
            &[
                ("ETag", "\"v1\""),
                ("Last-Modified", "Mon, 16 Nov 2026 20:00:00 GMT"),
                ("Set-Cookie", "s=1"),
            ],
        ),
        Ok(FetchResponse {
            status: 304,
            headers: vec![("Cache-Control".into(), "max-age=120".into())],
            body: String::new(),
        }),
    ]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    let first = cache.get(&fetcher, request(), t0).unwrap();
    assert!(first.response.headers.iter().all(|(k, _)| k != "Set-Cookie"));
    let again = cache.get(&fetcher, request(), t0 + secs(61)).unwrap();
    assert_eq!(
        (again.response.body.as_str(), again.response.status, again.fresh_for),
        ("body", 200, secs(120))
    );
    let sent = &fetcher.requests.lock().unwrap()[1];
    assert!(sent.headers.contains(&("If-None-Match".into(), "\"v1\"".into())));
    assert!(sent.headers.iter().any(|(k, _)| k == "If-Modified-Since"));
    assert!(cache.get(&fetcher, request(), t0 + secs(61 + 119)).unwrap().hit);
}

#[test]
fn nothing_is_fetched_without_a_reader_and_unread_urls_are_dropped() {
    let fetcher = Scripted::new(vec![ok("1", &[])]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    cache.get(&fetcher, request(), t0).unwrap();
    // No timer, no thread: with nobody reading, the cache sends nothing however long it waits.
    thread::sleep(Duration::from_millis(50));
    assert_eq!(fetcher.count(), 1);
    // A read of another URL after MAX_STALE prunes the one nobody read since.
    let other = FetchRequest { url: "https://api.open-meteo.com/other".into(), ..request() };
    cache.get(&fetcher, other, t0 + MAX_STALE + secs(1)).unwrap();
    assert_eq!(cache.urls(), 1);
}

#[test]
fn the_cache_is_bounded_by_url_count() {
    let fetcher = Scripted::new(vec![ok("1", &[])]);
    let cache = HttpCache::default();
    let t0 = Instant::now();
    for i in 0..(MAX_ENTRIES + 10) {
        let url = format!("https://api.example.com/{i}");
        cache
            .get(&fetcher, FetchRequest { url, ..request() }, t0 + Duration::from_millis(i as u64))
            .unwrap();
    }
    assert_eq!(cache.urls(), MAX_ENTRIES);
    assert!(
        !cache.entries.lock().unwrap().contains_key("https://api.example.com/0"),
        "the least recently read goes first"
    );
}

#[test]
fn a_shared_fetch_is_a_plain_get() {
    let post = FetchRequest {
        url: URL.into(),
        method: "POST".into(),
        headers: vec![],
        body: Some("x".into()),
    };
    assert_eq!(shared_request(post).unwrap_err().code, "validation.invalid");
    let get = FetchRequest {
        url: URL.into(),
        method: "GET".into(),
        headers: vec![("X-Api-Key".into(), "secret".into())],
        body: None,
    };
    assert_eq!(
        shared_request(get).unwrap().headers,
        vec![("Accept".to_string(), "application/json".to_string())]
    );
}

#[test]
fn a_fetcher_that_panics_does_not_leave_the_url_in_flight() {
    struct Panics;
    impl Fetcher for Panics {
        fn fetch(&self, _: FetchRequest) -> Result<FetchResponse, EgressError> {
            panic!("fetcher bug")
        }
    }
    let cache = HttpCache::default();
    let t0 = Instant::now();
    assert_eq!(cache.get(&Panics, request(), t0).unwrap_err().code, "operation.failed");
    assert!(!cache.entries.lock().unwrap()[URL].inflight);
    // After the failure's floor a working fetcher answers at once.
    let fetcher = Scripted::new(vec![ok("1", &[])]);
    assert_eq!(cache.get(&fetcher, request(), t0 + FLOOR).unwrap().response.body, "1");
}
