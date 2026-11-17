use super::*;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

fn ok_result(n: usize) -> Value {
    json!({"content": [], "structuredContent": {"n": n}, "isError": false})
}

async fn send(cache: &Cache, runs: &AtomicUsize, scope: &str, args: Value) -> Value {
    once(cache, scope, args, |a| async move {
        assert!(a.get(KEY_ARG).is_none(), "the key never reaches the daemon: {a}");
        ok_result(runs.fetch_add(1, Ordering::SeqCst) + 1)
    })
    .await
}

#[tokio::test]
async fn same_key_twice_acts_once_and_echoes_the_key() {
    let (cache, runs) = (Cache::new(TTL, MAX_ENTRIES), AtomicUsize::new(0));
    let args = json!({"sessionId": "s1", "text": "hi", "idempotency_key": "k1"});
    let first = send(&cache, &runs, "me", args.clone()).await;
    let again = send(&cache, &runs, "me", args).await;
    assert_eq!(runs.load(Ordering::SeqCst), 1);
    assert_eq!(first["structuredContent"]["idempotency_key"], "k1");
    assert_eq!(first["structuredContent"].get("replayed"), None);
    assert_eq!(again["structuredContent"]["n"], 1);
    assert_eq!(again["structuredContent"]["replayed"], true);
}

#[tokio::test]
async fn no_key_always_acts() {
    let (cache, runs) = (Cache::new(TTL, MAX_ENTRIES), AtomicUsize::new(0));
    let args = json!({"sessionId": "s1", "text": "hi"});
    send(&cache, &runs, "me", args.clone()).await;
    send(&cache, &runs, "me", args).await;
    assert_eq!(runs.load(Ordering::SeqCst), 2);
    assert!(cache.is_empty());
}

#[tokio::test]
async fn keys_are_per_session_and_other_arguments_conflict() {
    let (cache, runs) = (Cache::new(TTL, MAX_ENTRIES), AtomicUsize::new(0));
    send(&cache, &runs, "a", json!({"text": "hi", "idempotency_key": "k"})).await;
    send(&cache, &runs, "b", json!({"text": "hi", "idempotency_key": "k"})).await;
    assert_eq!(runs.load(Ordering::SeqCst), 2);
    let clash = send(&cache, &runs, "a", json!({"text": "other", "idempotency_key": "k"})).await;
    assert_eq!(clash["isError"], true, "{clash}");
    assert!(clash.to_string().contains("idempotency.conflict"), "{clash}");
    let bad = send(&cache, &runs, "a", json!({"text": "hi", "idempotency_key": 7})).await;
    assert_eq!(bad["isError"], true, "{bad}");
    assert_eq!(runs.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn an_error_is_forgotten_so_a_retry_acts_again() {
    let cache = Cache::new(TTL, MAX_ENTRIES);
    let args = json!({"text": "hi", "idempotency_key": "k"});
    let failed = once(&cache, "me", args.clone(), |_| async {
        crate::secret_mcp::error_result("busy".into())
    })
    .await;
    assert_eq!(failed["isError"], true);
    assert!(cache.is_empty());
    let retried = once(&cache, "me", args, |_| async { ok_result(1) }).await;
    assert_eq!(retried["structuredContent"]["n"], 1);
    assert_eq!(retried["structuredContent"].get("replayed"), None);
}

#[tokio::test]
async fn concurrent_calls_with_one_key_act_once() {
    let (cache, runs) = (Cache::new(TTL, MAX_ENTRIES), AtomicUsize::new(0));
    let args = json!({"text": "race", "idempotency_key": "k"});
    let calls = (0..8).map(|_| {
        once(&cache, "me", args.clone(), |_| async {
            tokio::task::yield_now().await;
            ok_result(runs.fetch_add(1, Ordering::SeqCst) + 1)
        })
    });
    let outs = futures::future::join_all(calls).await;
    assert_eq!(runs.load(Ordering::SeqCst), 1);
    assert!(outs.iter().all(|o| o["structuredContent"]["n"] == 1));
}

#[test]
fn the_cache_is_bounded_by_size_and_age() {
    let cache = Cache::new(Duration::from_secs(10), 4);
    let t0 = Instant::now();
    for i in 0..10 {
        cache.claim("s", &format!("k{i}"), 0, t0 + Duration::from_millis(i));
    }
    assert_eq!(cache.len(), 4, "oldest go first past the size bound");
    let first = cache.claim("s", "k9", 0, t0 + Duration::from_millis(20)).expect("live");
    let later = cache.claim("s", "k9", 0, t0 + Duration::from_secs(11)).expect("expired: new cell");
    assert!(!Arc::ptr_eq(&first, &later), "a key past its TTL acts again");
}

/// Per-call cost of the dedupe lookup, same harness before (no key) and after (a key,
/// first call and replay, cache full). Run:
/// `cargo test -p acpmux --release --lib idempotency::tests::bench -- --ignored --nocapture`.
#[tokio::test]
#[ignore = "bench"]
async fn bench_dedupe_lookup_per_call() {
    const N: usize = 200_000;
    let cache = Cache::new(TTL, MAX_ENTRIES);
    for i in 0..MAX_ENTRIES {
        cache.claim("me", &format!("fill{i}"), 0, Instant::now());
    }
    let base = json!({"sessionId": "s1", "text": "hello from the bench"});
    let time = |label: &str, d: Duration| {
        println!("{label}: {:.0} ns/call", d.as_nanos() as f64 / N as f64)
    };

    let start = Instant::now();
    for _ in 0..N {
        std::hint::black_box(once(&cache, "me", base.clone(), |_| async { ok_result(1) }).await);
    }
    time("before (no idempotency_key)", start.elapsed());

    let keyed = |i: usize| {
        let mut a = base.clone();
        a[KEY_ARG] = json!(format!("key-{i}"));
        a
    };
    let start = Instant::now();
    for i in 0..N {
        std::hint::black_box(once(&cache, "me", keyed(i), |_| async { ok_result(1) }).await);
    }
    time("after, new key each call (cache full, evicts)", start.elapsed());

    let start = Instant::now();
    for _ in 0..N {
        std::hint::black_box(once(&cache, "me", keyed(0), |_| async { ok_result(1) }).await);
    }
    time("after, replay of one key", start.elapsed());
}

#[test]
fn forgotten_and_replaced_keys_do_not_grow_the_order_queue() {
    let cache = Cache::new(Duration::from_secs(1), 4);
    let t0 = Instant::now();
    for i in 0..1000u64 {
        let now = t0 + Duration::from_secs(i * 2); // each claim expires the last
        let cell = cache.claim("s", "same", 0, now).expect("new cell");
        if i % 2 == 0 {
            cache.forget("s", "same", &cell);
        }
    }
    let entries = cache.entries.lock().unwrap();
    assert!(entries.map.len() <= 4, "{}", entries.map.len());
    assert!(entries.order.len() <= 2 * 4 + 1, "{}", entries.order.len());
}
