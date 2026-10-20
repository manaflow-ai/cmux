//! Budget guards (design section 8): per-keystroke latency at 100
//! workspaces with large scrollback, resident memory per GB of text,
//! incremental appends that never rescan, and zero idle CPU.

use std::time::{Duration, Instant};

use cmux_search::{
    Doc, EngineConfig, Kind, NameDoc, Query, SearchEngine, SyntheticCorpus, TargetContext,
};

const NOW: i64 = 1_900_000_000_000;
/// Scrollback across the 100 workspaces (sealed to disk, as the daemon runs).
const SCROLLBACK_BYTES: usize = 512 << 20;
/// First results of each keystroke, the user's budget.
const KEYSTROKE_BUDGET: Duration = Duration::from_millis(16);
/// Resident memory per GiB of indexed text, in MiB.
const RESIDENT_MIB_PER_GIB: f64 = 64.0;

/// 100 workspaces, 6 tabs each with a terminal, 20,000 file names, and
/// `SCROLLBACK_BYTES` of scrollback spread over the terminals.
fn hundred_workspaces(dir: &std::path::Path) -> SearchEngine {
    let mut engine = SearchEngine::open(dir, EngineConfig::default()).unwrap();
    let groups = ["Performance", "Agents & routing", "Sidebar & tabs", "Nightly & CI", "Web"];
    for workspace in 0..100 {
        let ws = format!("ws_{workspace}");
        let ws_name = format!(
            "project {workspace} {}",
            ["api", "web", "infra", "cmux", "docs"][workspace % 5]
        );
        engine.upsert_name(NameDoc {
            key: ws.clone(),
            kind: Kind::Workspace,
            target: ws.clone(),
            title: ws_name.clone(),
            subtitle: groups[workspace % 5].to_owned(),
            at_ms: NOW - workspace as i64 * 60_000,
        });
        for tab in 0..6 {
            let target = format!("term:{}", workspace * 6 + tab);
            let title = ["zsh", "claude", "codex", "server", "logs", "vim"][tab].to_owned();
            engine.upsert_name(NameDoc {
                key: format!("tab:{target}"),
                kind: Kind::Tab,
                target: target.clone(),
                title: title.clone(),
                subtitle: ws_name.clone(),
                at_ms: NOW - (workspace * 6 + tab) as i64 * 10_000,
            });
            engine.set_context(
                &target,
                TargetContext {
                    workspace_id: ws.clone(),
                    workspace: ws_name.clone(),
                    group: groups[workspace % 5].to_owned(),
                    title,
                    cwd: format!("~/code/project-{workspace}"),
                    branch: format!("feature-{}", workspace % 17),
                    agent: String::new(),
                },
            );
        }
    }
    for file in 0..20_000 {
        let path = format!("src/module{}/sub{}/file_{file}_handler.rs", file % 97, file % 13);
        engine.upsert_name(NameDoc {
            key: path.clone(),
            kind: Kind::File,
            target: path.clone(),
            title: path,
            subtitle: String::new(),
            at_ms: NOW - file as i64 * 1000,
        });
    }
    for (index, mut doc) in SyntheticCorpus::with_bytes(99, SCROLLBACK_BYTES).enumerate() {
        doc.target = format!("term:{}", index % 600);
        doc.source = doc.target.clone();
        engine.append(doc);
    }
    engine
}

#[test]
fn cmux_search_budget_keystrokes_memory_and_incremental_appends() {
    let dir = tempfile::tempdir().unwrap();
    let started = Instant::now();
    let mut engine = hundred_workspaces(dir.path());
    // Seal the tail so memory is measured on sealed segments (the live
    // segment is a fixed cap, at most `segment_bytes` of text).
    engine.seal();
    let build = started.elapsed();
    let stats = engine.stats();

    // Every prefix of what a user types, each a fresh query (no caching).
    let typed = [
        "migration failed",
        "cmux-next error",
        "project 42 server",
        "file_1234",
        "deploy staging",
        "mismatched types",
        "\"cargo test\"",
        "infra logs timeout",
        "qqzv unseen",
        "release nightly",
    ];
    let mut times = Vec::new();
    let mut slowest = (Duration::ZERO, String::new());
    for text in typed {
        for end in 1..=text.len() {
            let prefix = &text[..end];
            let mut query = Query::new(prefix, NOW);
            query.budget = Some(Duration::from_millis(10));
            query.workspace_id = Some("ws_7".to_owned());
            let begin = Instant::now();
            let result = engine.search(&query);
            let took = begin.elapsed();
            std::hint::black_box(result.hits.len());
            if took > slowest.0 {
                slowest = (took, prefix.to_owned());
            }
            times.push(took);
        }
    }
    times.sort();
    let p50 = times[times.len() / 2];
    let p99 = times[times.len() * 99 / 100];

    // Incremental: appending to a 512 MiB index costs what it costs on an
    // empty one (no rescans), and new text is searchable at once.
    let append_rate = |engine: &mut SearchEngine| {
        let docs: Vec<Doc> = SyntheticCorpus::with_bytes(5, 8 << 20).collect();
        let bytes: usize = docs.iter().map(|doc| doc.text.len()).sum();
        let begin = Instant::now();
        for doc in docs {
            engine.append(doc);
        }
        bytes as f64 / begin.elapsed().as_secs_f64()
    };
    let full_rate = append_rate(&mut engine);
    let mut fresh = SearchEngine::new(EngineConfig::default());
    let empty_rate = append_rate(&mut fresh);
    engine.append(Doc {
        kind: Kind::Scrollback,
        source: "term:1".into(),
        target: "term:1".into(),
        position: Some(1),
        title: "zsh".into(),
        text: "just printed zqxjv-unique-line".into(),
        at_ms: NOW,
        key: None,
    });
    assert_eq!(engine.search(&Query::new("zqxjv-unique", NOW)).hits.len(), 1);

    let mib_per_gib = (stats.resident_bytes as f64 / (1 << 20) as f64)
        / (stats.text_bytes as f64 / (1 << 30) as f64);
    eprintln!(
        "search budgets: {} MiB text, {} names, build {:?}; keystroke p50 {:?}, p99 {:?}, slowest {:?} ({:?}); resident {:.1} MiB = {:.1} MiB per GiB of text; index on disk {:.3}x text; append {:.0} MiB/s on 512 MiB vs {:.0} MiB/s empty",
        stats.text_bytes >> 20,
        stats.names,
        build,
        p50,
        p99,
        slowest.0,
        slowest.1,
        stats.resident_bytes as f64 / (1 << 20) as f64,
        mib_per_gib,
        stats.index_bytes as f64 / stats.text_bytes as f64,
        full_rate / (1 << 20) as f64,
        empty_rate / (1 << 20) as f64,
    );
    assert!(p99 <= KEYSTROKE_BUDGET, "keystroke p99 {p99:?} is over {KEYSTROKE_BUDGET:?}");
    assert!(
        slowest.0 <= KEYSTROKE_BUDGET * 2,
        "slowest keystroke {:?} ({:?}) is over twice the budget",
        slowest.0,
        slowest.1
    );
    assert!(mib_per_gib <= RESIDENT_MIB_PER_GIB, "resident {mib_per_gib:.1} MiB per GiB of text");
    assert!(
        full_rate >= empty_rate * 0.5,
        "appends slow down with index size: {full_rate} vs {empty_rate}"
    );
}

#[test]
fn cmux_search_budget_idle_engine_uses_no_cpu() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    for doc in SyntheticCorpus::with_bytes(3, 16 << 20) {
        engine.append(doc);
    }
    let before = thread_cpu();
    // A measurement window, not a synchronization: the engine owns no
    // threads or timers, so nothing may run while it sits idle.
    std::thread::sleep(Duration::from_millis(500));
    let used = thread_cpu().saturating_sub(before);
    std::hint::black_box(engine.stats());
    eprintln!("search idle: {used:?} CPU in 500 ms");
    assert!(used < Duration::from_millis(5), "idle engine used {used:?} of CPU");
}

fn thread_cpu() -> Duration {
    // SAFETY: getrusage fills the zeroed struct we pass and nothing else.
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        usage
    };
    let micros = |time: libc::timeval| time.tv_sec as u64 * 1_000_000 + time.tv_usec as u64;
    Duration::from_micros(micros(usage.ru_utime) + micros(usage.ru_stime))
}
