//! Bench (off unless CMUX_LIST_WORKSPACES_BENCH=<lists per case>): the real
//! daemon's `list-workspaces` with 1, 100, 1,000 and 4,000 workspaces
//! (hq#8813; the daemon holds at most 4,096), each workspace holding one
//! terminal tab with no process behind it, on a persistent registry.
//! Per size: the whole reply (what every phone list costs today), the
//! `known` reply of a client whose tree is current, and the first screen
//! (`limit: 50`), and a paired phone's list without and with `known`, from the command to the
//! serialized line, p50 and p95, with the line's bytes; then the first whole
//! list after a restart of the daemon on the same registry. Prints
//! LIST-WORKSPACES-BENCH lines and writes them to
//! $FAST_CHECKS_OUT/list-workspaces-bench.txt when that is set.
//!
//! cargo test -p cmux-tui-core --release --lib -- list_workspaces_bench --nocapture
//! (with CMUX_LIST_WORKSPACES_BENCH=50)

use super::super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: &Value) -> String {
    run_as(mux, mux.local_test_client(0), request)
}

fn run_as(mux: &Arc<Mux>, client: u64, request: &Value) -> String {
    let command: Command = serde_json::from_value(request.clone()).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, client, command, &writer).unwrap().to_string()
}

/// The time of one request to its serialized reply, in ms, and the reply.
fn timed(mux: &Arc<Mux>, request: &Value) -> (f64, String) {
    timed_as(mux, mux.local_test_client(0), request)
}

fn timed_as(mux: &Arc<Mux>, client: u64, request: &Value) -> (f64, String) {
    let started = Instant::now();
    let line = run_as(mux, client, request);
    (started.elapsed().as_secs_f64() * 1000.0, line)
}

/// A paired phone's connection: the Mac lane marks its `set-client-info`
/// `remote: true` (incognito_remote.rs), so it is answered as a remote device.
fn phone(mux: &Arc<Mux>) -> u64 {
    let (writer, _) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    run_as(
        mux,
        client,
        &json!({"cmd": "set-client-info", "name": "iPhone", "kind": "ios",
                "device_id": "bench-phone", "remote": true}),
    );
    assert!(incognito_remote::is_remote_device(mux, client), "the bench phone is not remote");
    client
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

/// The rows a phone's first screen shows, with room to scroll.
const FIRST_SCREEN: usize = 50;

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
        let (mut whole_times, mut known_times, mut first_times) =
            (Vec::new(), Vec::new(), Vec::new());
        let (mut whole_bytes, mut known_bytes, mut first_bytes) = (0, 0, 0);
        // Warm the caches (git HEADs, short ids) the way a running daemon has them.
        let first = run(&mux, &json!({"cmd": "list-workspaces", "known": {}}));
        let known = json!({"cmd": "list-workspaces", "known": known_of(&first)});
        let screen = json!({"cmd": "list-workspaces", "limit": FIRST_SCREEN});
        for round in 0..runs {
            // Each arm runs first, second and third in turn.
            for arm in (0..3).map(|offset| (round + offset) % 3) {
                match arm {
                    0 => {
                        let (ms, line) = timed(&mux, &whole);
                        whole_bytes = line.len();
                        whole_times.push(ms);
                    }
                    1 => {
                        let (ms, line) = timed(&mux, &known);
                        assert!(
                            line.contains("\"unchanged\":true"),
                            "{}",
                            &line[..200.min(line.len())]
                        );
                        known_bytes = line.len();
                        known_times.push(ms);
                    }
                    _ => {
                        let (ms, line) = timed(&mux, &screen);
                        first_bytes = line.len();
                        first_times.push(ms);
                    }
                }
            }
        }
        lines_out.push(format!(
            "LIST-WORKSPACES-BENCH {profile} workspaces={count} lists={runs} seed_ms={seed_ms}: \
             whole {whole_bytes} bytes, {}; known unchanged {known_bytes} bytes, {}; \
             first screen (limit {FIRST_SCREEN}) {first_bytes} bytes, {}",
            percentiles(&mut whole_times),
            percentiles(&mut known_times),
            percentiles(&mut first_times),
        ));

        // The phone path (hq#10926): a paired phone's connection, before (the list it sent
        // with no `known`: the whole tree each time) and after (its `known`, answered
        // `unchanged`).
        let client = phone(&mux);
        let phone_first = run_as(&mux, client, &json!({"cmd": "list-workspaces", "known": {}}));
        let phone_known = json!({"cmd": "list-workspaces", "known": known_of(&phone_first)});
        let (mut before_times, mut after_times) = (Vec::new(), Vec::new());
        let (mut before_bytes, mut after_bytes) = (0, 0);
        for round in 0..runs {
            for arm in (0..2).map(|offset| (round + offset) % 2) {
                if arm == 0 {
                    let (ms, line) = timed_as(&mux, client, &whole);
                    before_bytes = line.len();
                    before_times.push(ms);
                } else {
                    let (ms, line) = timed_as(&mux, client, &phone_known);
                    assert!(
                        line.contains("\"unchanged\":true"),
                        "{}",
                        &line[..200.min(line.len())]
                    );
                    after_bytes = line.len();
                    after_times.push(ms);
                }
            }
        }
        lines_out.push(format!(
            "LIST-WORKSPACES-BENCH {profile} workspaces={count} phone: before (no known) \
             {before_bytes} bytes, {}; after (known, unchanged) {after_bytes} bytes, {}",
            percentiles(&mut before_times),
            percentiles(&mut after_times),
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
        let (first_screen_ms, screen_line) = timed(&mux, &screen);
        let (first_known_ms, known_line) = timed(&mux, &known);
        let unchanged = known_line.contains("\"unchanged\":true");
        lines_out.push(format!(
            "LIST-WORKSPACES-BENCH {profile} workspaces={count} restart: open {open_ms:.1} ms; \
             first whole list {first_whole_ms:.3} ms; first screen {first_screen_ms:.3} ms \
             ({} bytes); first list with the old known {first_known_ms:.3} ms ({} bytes, \
             unchanged={unchanged})",
            screen_line.len(),
            known_line.len(),
        ));
        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(&root);
        for line in &lines_out[lines_out.len() - 3..] {
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
