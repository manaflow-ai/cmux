//! Bench (off unless CMUX_OPEN_PERSISTENT_BENCH=1): the daemon's start on a
//! persistent registry with 1, 100, 1,000 and 4,000 workspaces (the daemon
//! holds at most 4,096), and the creates that fill it, for two kinds of
//! workspace. `chat`: an empty workspace with one agent session tab in it
//! (`create_empty_workspace` and `new-conversation-tab`), as a God session
//! holds them, opened with `Mux::open_persistent`. `terminal`: a workspace
//! with one terminal tab (`new_workspace`), on the test surface runtime so
//! no PTY runs (as the list-workspaces bench).
//! The creates and the restart run on the test thread, which skips the unit tests' check of
//! each tree entity against the whole tree (the daemon never runs it).
//! Per size: the whole seed, the p50 of the first and of the last 100
//! creates (a constant create cost has the two equal), then the
//! `Mux::open_persistent` of a restart on the same registry with its
//! slowest laps. Prints OPEN-PERSISTENT-BENCH lines and writes them to
//! $FAST_CHECKS_OUT/open-persistent-bench.txt when that is set.
//!
//! cargo test -p cmux-tui-core --release --lib -- open_persistent_bench --nocapture
//! (with CMUX_OPEN_PERSISTENT_BENCH=1; CMUX_OPEN_PERSISTENT_BENCH_SIZES=1,100 picks sizes,
//! CMUX_OPEN_PERSISTENT_BENCH_KINDS=chat,terminal the kinds)

use super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;

const SESSION: &str = "open-persistent-bench";

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

fn p50(times: &mut [f64]) -> f64 {
    if times.is_empty() {
        return 0.0;
    }
    times.sort_by(f64::total_cmp);
    times[times.len() / 2]
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Chat,
    Terminal,
}

fn open(kind: Kind, root: &Path) -> Arc<Mux> {
    match kind {
        Kind::Chat => Mux::open_persistent(SESSION, SurfaceOptions::default(), root).unwrap(),
        Kind::Terminal => {
            let registry =
                crate::workspace_registry::WorkspaceRegistry::open(root, SESSION).unwrap();
            Mux::from_workspace_registry(
                SESSION.to_string(),
                SurfaceOptions::default(),
                registry,
                crate::mux::ProviderWorkspaceState::default(),
                true,
            )
            .unwrap()
        }
    }
}

/// One workspace: as the app makes a chat's (an empty workspace, then an
/// agent session tab in it), or with one terminal tab.
fn create(kind: Kind, mux: &Arc<Mux>, index: usize) {
    if kind == Kind::Terminal {
        mux.new_workspace(Some(format!("Workspace {index}")), Some((80, 24)))
            .unwrap_or_else(|error| panic!("workspace {index}: {error:#}"));
        return;
    }
    let placement = mux
        .create_empty_workspace(Some(format!("Workspace {index}")), None, None)
        .unwrap_or_else(|error| panic!("workspace {index}: {error:#}"));
    run(
        mux,
        json!({"cmd": "new-conversation-tab", "workspace": placement.workspace,
               "agent_session": {"host": "install:bench", "harness": "claude",
                                 "session": format!("bench-{index}")}}),
    );
}

#[test]
fn open_persistent_bench() {
    if std::env::var("CMUX_OPEN_PERSISTENT_BENCH").map_or(true, |value| value != "1") {
        return;
    }
    let profile = if cfg!(debug_assertions) { "dev-profile" } else { "release" };
    // Unit tests check each tree entity against the whole tree, which the daemon never
    // does; CMUX_OPEN_PERSISTENT_BENCH_ENTITY_CHECK=1 keeps it (to compare with a bench
    // that timed it).
    let entity_check =
        std::env::var("CMUX_OPEN_PERSISTENT_BENCH_ENTITY_CHECK").is_ok_and(|v| v == "1");
    if !entity_check {
        tree_json::skip_entity_check_on_this_thread_for_bench();
    }
    let profile =
        if entity_check { format!("{profile} entity-check") } else { profile.to_string() };
    let sizes = std::env::var("CMUX_OPEN_PERSISTENT_BENCH_SIZES").ok().map_or_else(
        || vec![1usize, 100, 1_000, 4_000],
        |sizes| sizes.split(',').filter_map(|size| size.trim().parse().ok()).collect(),
    );
    let kinds = std::env::var("CMUX_OPEN_PERSISTENT_BENCH_KINDS").ok().map_or_else(
        || vec![Kind::Chat, Kind::Terminal],
        |kinds| {
            kinds
                .split(',')
                .filter_map(|kind| match kind.trim() {
                    "chat" => Some(Kind::Chat),
                    "terminal" => Some(Kind::Terminal),
                    _ => None,
                })
                .collect()
        },
    );
    let mut lines_out = Vec::new();
    for (kind, count) in
        kinds.iter().flat_map(|kind| sizes.iter().map(move |count| (*kind, *count)))
    {
        let label = if kind == Kind::Chat { "chat" } else { "terminal" };
        let root = std::env::temp_dir().join(format!(
            "cmux-open-persistent-bench-{label}-{count}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = open(kind, &root);
        let seeded = Instant::now();
        let (mut first, mut last) = (Vec::new(), Vec::new());
        for index in 0..count {
            let started = Instant::now();
            create(kind, &mux, index);
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            if index < 100 {
                first.push(ms);
            }
            if index + 100 >= count {
                last.push(ms);
            }
            if index > 0 && index % 1_000 == 0 {
                eprintln!(
                    "OPEN-PERSISTENT-BENCH {label} seeding {index} of {count}: {} ms",
                    seeded.elapsed().as_millis()
                );
            }
        }
        let seed_ms = seeded.elapsed().as_millis();
        lines_out.push(format!(
            "OPEN-PERSISTENT-BENCH {profile} {label} workspaces={count} create: seed {seed_ms} ms; \
             first 100 p50 {:.3} ms; last 100 p50 {:.3} ms",
            p50(&mut first),
            p50(&mut last),
        ));
        mux.shutdown();
        drop(mux);

        let reopened = Instant::now();
        let mux = open(kind, &root);
        let open_ms = reopened.elapsed().as_secs_f64() * 1000.0;
        let listed = run(&mux, json!({"cmd": "list-workspaces"}));
        assert_eq!(listed["workspaces"].as_array().map(Vec::len), Some(count));
        let mut laps = mux
            .take_startup_timings()
            .map(|timings| {
                timings
                    .steps()
                    .into_iter()
                    .map(|(step, took)| (step.to_string(), took))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        laps.sort_by_key(|(_, took)| std::cmp::Reverse(*took));
        let slowest = laps
            .iter()
            .take(8)
            .map(|(step, took)| format!("{step} {:.1} ms", took.as_secs_f64() * 1000.0))
            .collect::<Vec<_>>()
            .join(", ");
        lines_out.push(format!(
            "OPEN-PERSISTENT-BENCH {profile} {label} workspaces={count} restart: open {open_ms:.1} ms; \
             slowest: {slowest}"
        ));
        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(&root);
        for line in &lines_out[lines_out.len() - 2..] {
            eprintln!("{line}");
        }
    }
    if let Ok(dir) = std::env::var("FAST_CHECKS_OUT") {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            Path::new(&dir).join("open-persistent-bench.txt"),
            lines_out.join("\n") + "\n",
        )
        .unwrap();
    }
}
