//! Perf guard: a 32 MiB synthetic corpus, indexed and queried in-process.
//! Fails when the median query or the index size regresses past the
//! budgets below (design section 8). The cmux-search package builds at
//! opt-level 3 in test profiles (cmux-tui/Cargo.toml), as the daemon runs it.

use std::time::{Duration, Instant};

use cmux_search::{EngineConfig, Query, SearchEngine, SyntheticCorpus};

const CORPUS_BYTES: usize = 32 << 20;
/// Median query budget. The first fleet run sets the real number; this
/// leaves room for a loaded worker.
const P50_BUDGET: Duration = Duration::from_millis(3);
/// Postings + tables over text.
const INDEX_RATIO_BUDGET: f64 = 1.0;

#[test]
fn cmux_search_search_perf_guard_median_query_and_index_size() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    let started = Instant::now();
    for doc in SyntheticCorpus::with_bytes(42, CORPUS_BYTES) {
        engine.append(doc);
    }
    engine.seal();
    let build = started.elapsed();
    let stats = engine.stats();
    let ratio = stats.index_bytes as f64 / stats.text_bytes as f64;

    let queries = [
        "error",
        "mismatched types",
        "request id=",
        "\"cargo test\"",
        "migration",
        "zzqx",
        "FAILED",
        "deploy staging",
        "sidebar",
        "mig",
        "dep",
        "latency benchmark",
        "\"took 12ms\"",
        "Compiling",
        "socket timeout",
        "release nightly",
        "qqzv unseen",
        "workspace",
        "palette render",
        "4f2a",
    ];
    let now = 1_900_000_000_000;
    let mut times: Vec<Duration> = Vec::new();
    for _ in 0..3 {
        for text in queries {
            let started = Instant::now();
            let result = engine.search(&Query::new(text, now));
            times.push(started.elapsed());
            assert!(!result.partial);
        }
    }
    times.sort();
    let p50 = times[times.len() / 2];
    let p99 = times[times.len() * 99 / 100];
    eprintln!(
        "search perf guard: {} MiB text, {} docs, {} blocks, index {:.3}x, build {:?} ({:.0} MiB/s), p50 {:?}, p99 {:?}",
        stats.text_bytes >> 20,
        stats.docs,
        stats.blocks,
        ratio,
        build,
        (stats.text_bytes as f64 / (1 << 20) as f64) / build.as_secs_f64(),
        p50,
        p99
    );
    assert!(p50 <= P50_BUDGET, "median query {p50:?} is over {P50_BUDGET:?}");
    assert!(
        ratio <= INDEX_RATIO_BUDGET,
        "index is {ratio:.3}x the text, over {INDEX_RATIO_BUDGET}x"
    );
}
