//! Bench (off unless CMUX_LIST_WORKSPACES_BENCH=<lists per case>): the real
//! daemon's `list-workspaces` with 1, 100, 1,000 and 4,000 workspaces
//! (hq#8813; the daemon holds at most 4,096), each workspace holding one
//! terminal tab with no process behind it, on a persistent registry.
//! Per size: the whole reply (what every phone list costs today) and the
//! `known` reply of a client whose tree is current, from the command to the
//! serialized line, p50 and p95, with the line's bytes; then the first whole
//! list after a restart of the daemon on the same registry. Prints
//! LIST-WORKSPACES-BENCH lines and writes them to
//! $FAST_CHECKS_OUT/list-workspaces-bench.txt when that is set.
//!
//! cargo test -p cmux-tui-core --release --lib -- list_workspaces_bench --nocapture
//! (with CMUX_LIST_WORKSPACES_BENCH=50)

use super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: &Value) -> String {
    let command: Command = serde_json::from_value(request.clone()).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap().to_string()
}

/// The time of one request to its serialized reply, in ms, and the reply.
fn timed(mux: &Arc<Mux>, request: &Value) -> (f64, String) {
    let started = Instant::now();
    let line = run(mux, request);
    (started.elapsed().as_secs_f64() * 1000.0, line)
}

fn percentiles(times: &mut [f64]) -> String {
    times.sort_by(f64::total_cmp);
    let at = |p: f64| times[((times.len() - 1) as f64 * p).round() as usize];
    format!("p50 {:.3} ms p95 {:.3} ms", at(0.5), at(0.95))
}

fn known_of(line: &str) -> Value {
    let reply: Value = serde_json::from_str(line).unwrap();
    json!({
        "registry_id": reply["registry_id"],
        "generation": reply["generation"],
        "workspace_revision": reply["workspace_revision"],
        "pane_revision": reply["pane_revision"],
        "terminal_revision": reply["terminal_revision"],
        "tree_revision": reply["tree_revision"],
    })
}

/// The owner on `root`'s registry, with the test surface runtime: each tab is a terminal tab
/// with no process behind it, so 5,000 of them cost no PTYs.
fn open(root: &Path) -> Arc<Mux> {
    let registry =
        crate::workspace_registry::WorkspaceRegistry::open(root, "list-workspaces-bench").unwrap();
    Mux::from_workspace_registry(
        "list-workspaces-bench".to_string(),
        SurfaceOptions::default(),
        registry,
        crate::mux::ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

#[test]
fn list_workspaces_bench() {
    let Some(runs) = std::env::var("CMUX_LIST_WORKSPACES_BENCH")
        .ok()
        .and_then(|runs| runs.parse::<usize>().ok())
        .filter(|runs| *runs > 0)
    else {
        return;
    };
    let profile = if cfg!(debug_assertions) { "dev-profile" } else { "release" };
    let whole = json!({"cmd": "list-workspaces"});
    let mut lines_out = Vec::new();
    // CMUX_LIST_WORKSPACES_BENCH_SIZES=1,100 picks the sizes.
    let sizes = std::env::var("CMUX_LIST_WORKSPACES_BENCH_SIZES").ok().map_or_else(
        || vec![1usize, 100, 1_000, 4_000],
        |sizes| sizes.split(',').filter_map(|size| size.trim().parse().ok()).collect(),
    );
    for count in sizes {
        let root = std::env::temp_dir().join(format!(
            "cmux-list-workspaces-bench-{count}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = open(&root);
        let seeded = Instant::now();
        for index in 0..count {
            mux.new_workspace(Some(format!("Workspace {index}")), Some((80, 24)))
                .unwrap_or_else(|error| panic!("workspace {index} of {count}: {error:#}"));
            if index > 0 && index % 1_000 == 0 {
                eprintln!(
                    "LIST-WORKSPACES-BENCH seeding {index} of {count}: {} ms",
                    seeded.elapsed().as_millis()
                );
            }
        }
        let seed_ms = seeded.elapsed().as_millis();
        let (mut whole_times, mut known_times) = (Vec::new(), Vec::new());
        let (mut whole_bytes, mut known_bytes) = (0, 0);
        // Warm the caches (git HEADs, short ids) the way a running daemon has them.
        let first = run(&mux, &json!({"cmd": "list-workspaces", "known": {}}));
        let known = json!({"cmd": "list-workspaces", "known": known_of(&first)});
        for round in 0..runs {
            let arms: [bool; 2] = if round % 2 == 0 { [false, true] } else { [true, false] };
            for since in arms {
                if since {
                    let (ms, line) = timed(&mux, &known);
                    assert!(
                        line.contains("\"unchanged\":true"),
                        "{}",
                        &line[..200.min(line.len())]
                    );
                    known_bytes = line.len();
                    known_times.push(ms);
                } else {
                    let (ms, line) = timed(&mux, &whole);
                    whole_bytes = line.len();
                    whole_times.push(ms);
                }
            }
        }
        lines_out.push(format!(
            "LIST-WORKSPACES-BENCH {profile} workspaces={count} lists={runs} seed_ms={seed_ms}: \
             whole {whole_bytes} bytes, {}; known unchanged {known_bytes} bytes, {}",
            percentiles(&mut whole_times),
            percentiles(&mut known_times),
        ));

        // Restart on the same registry: the first lists the new daemon answers.
        mux.shutdown();
        drop(mux);
        let reopened = Instant::now();
        let mux = open(&root);
        let open_ms = reopened.elapsed().as_secs_f64() * 1000.0;
        let (first_whole_ms, first_line) = timed(&mux, &whole);
        let listed: Value = serde_json::from_str(&first_line).unwrap();
        assert_eq!(listed["workspaces"].as_array().map(Vec::len), Some(count));
        let (first_known_ms, known_line) = timed(&mux, &known);
        let unchanged = known_line.contains("\"unchanged\":true");
        lines_out.push(format!(
            "LIST-WORKSPACES-BENCH {profile} workspaces={count} restart: open {open_ms:.1} ms; \
             first whole list {first_whole_ms:.3} ms; first list with the old known \
             {first_known_ms:.3} ms ({} bytes, unchanged={unchanged})",
            known_line.len(),
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
            Path::new(&dir).join("list-workspaces-bench.txt"),
            lines_out.join("\n") + "\n",
        )
        .unwrap();
    }
}
