//! `VisitStore::summaries` (the omnibox seed) sums every URL in one newest-first scan. The
//! `GROUP BY` with a title subquery per URL it replaced is the oracle: on random logs (repeat
//! URLs, null and empty titles, titles that change, agent visits) both answer the same rows in the same order
//! at every limit.

use std::time::Instant;

use proptest::prelude::*;

use super::*;

/// The query `summaries` ran before: one group per URL the person visited, its newest non-null
/// title by subquery.
fn summaries_oracle(store: &VisitStore, limit: usize) -> Vec<VisitSummary> {
    let mut statement = store
        .connection
        .prepare(
            "SELECT url, (SELECT title FROM visits v2 WHERE v2.url = v.url AND v2.title IS NOT NULL \
             AND v2.actor = 'person' ORDER BY visit_time_ms DESC LIMIT 1), COUNT(*), \
             MAX(visit_time_ms) FROM visits v WHERE v.actor = 'person' GROUP BY url \
             ORDER BY MAX(visit_time_ms) DESC LIMIT ?1",
        )
        .unwrap();
    statement
        .query_map(params![i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
            Ok(VisitSummary {
                url: row.get(0)?,
                title: row.get(1)?,
                visit_count: row.get::<_, i64>(2)?.unsigned_abs(),
                last_visit_ms: row.get(3)?,
            })
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Inserts `visits` (url, title) in one transaction, one second apart in a shuffled order, so
/// every visit time is distinct (the oracle's order among equal times is SQLite's choice) and
/// ids do not follow time.
fn fill(store: &VisitStore, visits: &[(String, Option<String>, bool)], order: &[usize]) {
    let transaction = store.connection.unchecked_transaction().unwrap();
    {
        let mut insert = transaction
            .prepare("INSERT INTO visits(url, title, visit_time_ms, actor) VALUES (?1, ?2, ?3, ?4)")
            .unwrap();
        for (slot, &at) in order.iter().enumerate() {
            let (url, title, agent) = &visits[slot];
            let actor = if *agent { "agent" } else { "person" };
            insert
                .execute(params![url, title, 1_700_000_000_000_i64 + at as i64 * 1_000, actor])
                .unwrap();
        }
    }
    transaction.commit().unwrap();
}

fn visit() -> impl Strategy<Value = (String, Option<String>, bool)> {
    (
        0..12_u8,
        prop_oneof![
            Just(None),
            Just(Some(String::new())),
            (0..4_u8).prop_map(|n| Some(format!("Title {n}")))
        ],
        // About one visit in four is an agent's, which summaries leave out.
        prop::bool::weighted(0.25),
    )
        .prop_map(|(page, title, agent)| (format!("https://example.com/{page}"), title, agent))
}

proptest! {
    #[test]
    fn summaries_match_the_group_by_on_random_logs(
        (visits, order) in prop::collection::vec(visit(), 0..80)
            .prop_flat_map(|visits| {
                let n = visits.len();
                (Just(visits), Just((0..n).collect::<Vec<_>>()).prop_shuffle())
            }),
        limit in 0..16_usize,
    ) {
        let store = VisitStore::open_in_memory().unwrap();
        fill(&store, &visits, &order);
        for limit in [limit, usize::MAX] {
            prop_assert_eq!(store.summaries(limit).unwrap(), summaries_oracle(&store, limit));
        }
    }
}

/// Before -> after in one harness: the omnibox seed (`history.visit.summaries`, limit 5000) of a
/// file-backed profile at 10k and 100k visits (the per-profile cap), one URL per ten visits.
/// Measured (fastest of 15 on a busy 32-core VM): 10k 9.2 ms -> 3.0 ms; 100k 303 ms -> 34 ms;
/// per-visit cost from 10k to 100k: 3.3x before, 1.14x after. Run:
/// `cargo test -p cmux-history --release --lib summaries_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn summaries_bench() {
    const LIMIT: usize = 5_000;
    let hosts = ["github.com", "docs.rs", "news.ycombinator.com", "stackoverflow.com", "crates.io"];
    let mut per_visit = Vec::new();
    for count in [10_000_usize, 100_000] {
        let directory = std::env::temp_dir()
            .join(format!("cmux-history-summaries-bench-{}-{count}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("bench.sqlite");
        let store = VisitStore::open(&path).unwrap();
        let visits: Vec<(String, Option<String>, bool)> = (0..count)
            .map(|index| {
                let page = (index * 7_919) % (count / 10);
                let host = hosts[page % hosts.len()];
                let title = (index % 7 != 0).then(|| format!("Page {page} on {host}"));
                // One visit in ten is an agent's.
                (format!("https://{host}/path/{page}/item"), title, index % 10 == 0)
            })
            .collect();
        let order: Vec<usize> = (0..count).collect();
        fill(&store, &visits, &order);
        let time = |run: &dyn Fn() -> Vec<VisitSummary>| {
            let mut samples: Vec<f64> = (0..15)
                .map(|_| {
                    let started = Instant::now();
                    assert!(!run().is_empty());
                    started.elapsed().as_secs_f64() * 1_000.0
                })
                .collect();
            samples.sort_by(f64::total_cmp);
            (samples[0], samples[7], samples[14])
        };
        let (old_min, old, old_max) = time(&|| summaries_oracle(&store, LIMIT));
        let (new_min, new, new_max) = time(&|| store.summaries(LIMIT).unwrap());
        println!(
            "summaries({LIMIT}) at {count} visits: min {old_min:.1} ms -> {new_min:.1} ms; \
             p50 {old:.1} ms -> {new:.1} ms; max {old_max:.1} ms -> {new_max:.1} ms"
        );
        // The ratio takes the fastest run: the least disturbed by a busy machine.
        per_visit.push((old_min / count as f64, new_min / count as f64));
        // Budget: the seed of a full profile answers in under 250 ms.
        assert!(new < 250.0, "summaries took {new:.1} ms at {count} visits");
        drop(store);
        let _ = std::fs::remove_dir_all(&directory);
    }
    let (old_ratio, new_ratio) = (per_visit[1].0 / per_visit[0].0, per_visit[1].1 / per_visit[0].1);
    println!("per-visit cost, 100k vs 10k: before {old_ratio:.2}x, after {new_ratio:.2}x");
    assert!(new_ratio < 2.0, "per-visit cost grew {new_ratio:.2}x from 10k to 100k visits");
}
