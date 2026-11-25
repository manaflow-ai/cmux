//! Feed churn stress: what `feed_stress.rs` (one op against a full feed)
//! does not drive. The client mirror with a snooze backlog and snooze churn
//! at 1k, 10k and 100k items, its badge read, and a hook storm of 1k items
//! per synthetic second for 10 s through the local owner, the integration
//! owner and the mirror, with a frame tick every 16 ms. Each scenario times
//! a window of ops after the build-up and asserts that the 100k p95 stays
//! within [`MAX_RATIO`] of the 1k p95 (a storm hook: an absolute budget),
//! and that every owner stays at its cap.
//!
//! Timing is not a CI gate: run it yourself, in release, before and after a
//! change to a `feed-*` path of scripts/cmux-next/perf-hot-benches.json:
//! `cargo nextest run --release -p cmux-feed-core --test feed_churn_stress
//! --run-ignored only --no-capture` prints the table.

use std::time::{Duration, Instant};

use cmux_feed_core::client::{
    FeedItem, IntegrationOwner, Intent, IntentKind, Mirror, Owner, Poster,
};
use cmux_feed_core::{Context, Feed, MAX_ITEMS, Notice};

const SCALES: [usize; 3] = [1_000, 10_000, 100_000];
/// Ops timed per round, after the build-up.
const WINDOW: usize = 1_000;
/// Rounds per scale; the best round's percentiles count (a busy runner
/// slows a round, never speeds one up).
const ROUNDS: usize = 3;
/// The 100k p95 may be at most this many times the 1k p95 ...
const MAX_RATIO: f64 = 3.0;
/// ... plus this, so a sub-microsecond op does not fail on timer noise.
const SLACK: Duration = Duration::from_micros(2);
const NOW: i64 = 1_800_000_000_000;

#[derive(Clone, Copy, Debug)]
struct Cost {
    p50: Duration,
    p95: Duration,
}

fn cost(mut samples: Vec<Duration>) -> Cost {
    samples.sort_unstable();
    let at = |q: usize| samples[(samples.len() * q / 100).min(samples.len() - 1)];
    Cost { p50: at(50), p95: at(95) }
}

fn best(rounds: impl IntoIterator<Item = Cost>) -> Cost {
    rounds.into_iter().min_by_key(|cost| cost.p95).expect("one round")
}

fn time(op: impl FnOnce()) -> Duration {
    let start = Instant::now();
    op();
    start.elapsed()
}

/// Prints the scenario's table and fails when the largest scale's p95 grew
/// past the bound against the smallest.
fn assert_flat(scenario: &str, costs: &[(usize, Cost)]) {
    for (n, cost) in costs {
        eprintln!("stress {scenario:<28} N={n:>7} p50={:>9.2?} p95={:>9.2?}", cost.p50, cost.p95);
    }
    let (base_n, base) = costs.first().expect("a base scale");
    let (scale_n, scale) = costs.last().expect("a top scale");
    let bound = base.p95.mul_f64(MAX_RATIO) + SLACK;
    assert!(
        scale.p95 <= bound,
        "{scenario}: p95 at N={scale_n} is {:?}, more than {MAX_RATIO}x the N={base_n} p95 {:?} \
         (+{SLACK:?}): the per-op cost grows with the feed",
        scale.p95,
        base.p95,
    );
}

fn poster() -> Poster {
    Poster::new("agent", "Agent")
}

// MARK: Local owner (the daemon's notification items)

/// Notice `i` of a hook stream: 32 terminals, every 5th notice repeats the
/// key of one 3 back (a retried hook), every other notice may coalesce.
fn local_notice(i: usize, at_ms: u64) -> Notice {
    let key = if i % 5 == 4 { i.saturating_sub(3) } else { i };
    Notice {
        id: format!("fl_{i}"),
        dedupe_key: format!("notify:stress:{key}"),
        title: format!("Hook {i}"),
        body: "Agent finished a turn".to_owned(),
        level: "info".to_owned(),
        source: "agent".to_owned(),
        context: Context {
            workspace: Some("ws_1".to_owned()),
            tab: Some(format!("tab_{}", i % 32)),
            terminal: Some(format!("term_{}", i % 32)),
        },
        actor: None,
        at_ms,
        read: false,
        coalesce: i.is_multiple_of(2),
    }
}

/// One op of the local owner's churn, on the daemon's path
/// (`mux/feed_local.rs`: post to a copy, install the copy): posts, with a
/// terminal ack every 7th op.
fn local_op(feed: &mut Feed, i: usize) {
    let at_ms = 1_000_000 + i as u64;
    if i % 7 == 6 {
        let _ = feed.read_terminal(&format!("term_{}", i % 32), at_ms);
        return;
    }
    let mut next = feed.clone();
    next.post(local_notice(i, at_ms)).expect("post");
    *feed = next;
}

// MARK: Client mirror and its badge

/// The mirror after a cloud snapshot of `n` notices, every 10th snoozed
/// into the future (the snooze backlog a long-lived feed carries).
fn seeded_mirror(n: usize) -> Mirror {
    let mut mirror = Mirror::new("device_1");
    let items = (0..n)
        .map(|i| {
            let mut item = FeedItem::notice(
                &format!("fi_{i}"),
                &format!("Notice {i}"),
                poster(),
                NOW - n as i64 + i as i64,
            );
            if i.is_multiple_of(10) {
                item.snoozed_until = Some(NOW + 3_600_000 + i as i64);
            }
            item
        })
        .collect();
    mirror.cloud_snapshot("user_1", items, NOW);
    mirror
}

/// One op of the mirror's churn at `now`: a duplicate re-post of an item
/// (the owner's newer revision), a snooze intent and its echo, or a frame
/// tick; plus the badge read every op does.
fn mirror_op(mirror: &mut Mirror, n: usize, i: usize, now: i64) -> usize {
    let id = format!("fi_{}", (i * 7919) % n);
    let current = mirror.confirmed(&id).cloned().expect("seeded item");
    match i % 3 {
        0 => {
            let mut item = current;
            item.revision += 1;
            item.title = format!("Notice again {i}");
            item.read_at = None;
            mirror.event(Owner::Cloud, vec![item], Vec::new(), None, now);
        }
        1 => {
            let key = format!("snooze_{i}");
            let until = now + 60_000;
            let intent = Intent::new(&key, IntentKind::Snooze { items: vec![id], until }, now);
            mirror.begin(intent, true, now);
            let mut item = current;
            item.revision += 1;
            item.snoozed_until = Some(until);
            mirror.event(Owner::Cloud, vec![item], Vec::new(), Some(&key), now);
        }
        _ => {
            mirror.tick(now);
        }
    }
    mirror.counts().badge()
}

#[test]
#[ignore = "stress: run in release with --run-ignored only --no-capture (perf-hot-benches.json feed-mirror-commit)"]
fn mirror_commit_cost_stays_flat_with_snooze_churn() {
    let mut costs = Vec::new();
    for n in SCALES {
        let mut mirror = seeded_mirror(n);
        let mut i = 0;
        let rounds = (0..ROUNDS).map(|_| {
            cost(
                (0..WINDOW)
                    .map(|_| {
                        i += 1;
                        let now = NOW + i as i64;
                        time(|| {
                            mirror_op(&mut mirror, n, i, now);
                        })
                    })
                    .collect(),
            )
        });
        costs.push((n, best(rounds.collect::<Vec<_>>())));
        assert_eq!(mirror.timeline().count(), n, "the mirror holds what its owner sent");
    }
    assert_flat("mirror commit + snooze", &costs);
}

#[test]
#[ignore = "stress: run in release with --run-ignored only --no-capture (perf-hot-benches.json feed-mirror-commit)"]
fn badge_read_cost_stays_flat() {
    let mut costs = Vec::new();
    for n in SCALES {
        let mirror = seeded_mirror(n);
        let counts = mirror.counts();
        assert_eq!(counts.unread, n);
        assert_eq!(counts.unread_notices, n - n.div_ceil(10), "snoozed notices leave the badge");
        let rounds = (0..ROUNDS).map(|_| {
            cost(
                (0..WINDOW)
                    .map(|_| {
                        // One read is a few ns: time 100 per sample.
                        time(|| {
                            for _ in 0..100 {
                                std::hint::black_box(
                                    std::hint::black_box(&mirror).counts().badge(),
                                );
                            }
                        })
                    })
                    .collect(),
            )
        });
        costs.push((n, best(rounds.collect::<Vec<_>>())));
    }
    assert_flat("badge read (x100)", &costs);
}

// MARK: Integration owner (GitHub items, update cards) into the mirror

fn integration_item(i: usize, at: i64) -> FeedItem {
    let mut item = FeedItem::notice(&format!("fl_{i}"), &format!("Pull {i}"), poster(), at);
    item.home = "local:install_1".to_owned();
    // Every 5th post repeats a key one 3 back: the poster's re-post.
    let key = if i % 5 == 4 { i.saturating_sub(3) } else { i };
    item.dedupe_key = Some(format!("github:pr:{key}"));
    item
}

/// One integration op into the mirror: a post (every 4th op a snooze of
/// the newest item instead, committed by the owner).
fn integration_op(owner: &mut IntegrationOwner, mirror: &mut Mirror, i: usize, now: i64) {
    let events = if i % 4 == 3 {
        let target = format!("fl_{}", i - 1);
        if !owner.contains(&target) {
            return;
        }
        let key = format!("snooze_{i}");
        let intent =
            Intent::new(&key, IntentKind::Snooze { items: vec![target], until: now + 60_000 }, now);
        mirror.begin(intent.clone(), true, now);
        let (result, events) = owner.commit(&intent);
        result.expect("commit");
        mirror.settle(&key, None, now);
        events
    } else {
        owner.post(integration_item(i, now)).1
    };
    for event in events {
        mirror.event(Owner::Local, event.items, event.removed, event.tx.as_deref(), now);
    }
}

// MARK: Hook storm

/// 1k hook notifications per synthetic second for 10 s: each lands on the
/// local owner (the daemon's copy-and-install path) and, as an integration
/// item, on the mirror, with a frame tick every 16 ms. To keep up, an item
/// must cost less than its 1 ms arrival interval; the budget is a tenth.
#[test]
#[ignore = "stress: run in release with --run-ignored only --no-capture (perf-hot-benches.json feed-mirror-commit)"]
fn hook_storm_keeps_up_and_stays_bounded() {
    const RATE_PER_S: usize = 1_000;
    const SECONDS: usize = 10;
    const BUDGET_P95: Duration = Duration::from_micros(100);
    let mut feed = Feed::default();
    let mut owner = IntegrationOwner::new("device_1");
    let mut mirror = Mirror::new("device_1");
    mirror.cloud_snapshot("user_1", Vec::new(), NOW);
    let mut samples = Vec::with_capacity(RATE_PER_S * SECONDS);
    let (mut local, mut integration, mut frame) = (Vec::new(), Vec::new(), Vec::new());
    let started = Instant::now();
    for i in 0..RATE_PER_S * SECONDS {
        let now = NOW + i as i64;
        let parts = [
            time(|| local_op(&mut feed, i)),
            time(|| integration_op(&mut owner, &mut mirror, i, now)),
            time(|| {
                if i.is_multiple_of(16) {
                    mirror.tick(now);
                }
                std::hint::black_box(mirror.counts().badge());
            }),
        ];
        local.push(parts[0]);
        integration.push(parts[1]);
        frame.push(parts[2]);
        samples.push(parts.iter().sum());
    }
    let wall = started.elapsed();
    for (stage, stage_samples) in
        [("local post", local), ("integration -> mirror", integration), ("tick + badge", frame)]
    {
        let stage_cost = cost(stage_samples);
        eprintln!(
            "stress   storm stage {stage:<22} p50={:>9.2?} p95={:>9.2?}",
            stage_cost.p50, stage_cost.p95
        );
    }
    let storm = cost(samples);
    eprintln!(
        "stress {:<28} N={:>7} p50={:>9.2?} p95={:>9.2?} wall={wall:.2?} for {SECONDS} s of hooks",
        "hook storm 1k/s x 10 s",
        RATE_PER_S * SECONDS,
        storm.p50,
        storm.p95,
    );
    assert!(feed.items().len() <= MAX_ITEMS);
    assert!(owner.len() <= MAX_ITEMS);
    assert!(mirror.timeline().count() <= MAX_ITEMS);
    assert!(
        storm.p95 <= BUDGET_P95,
        "a hook costs {:?} at p95, over the {BUDGET_P95:?} budget (arrivals are 1 ms apart)",
        storm.p95,
    );
}
