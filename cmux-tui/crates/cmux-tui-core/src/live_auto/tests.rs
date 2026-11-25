//! classify + route, receipts, and the watcher's trigger latency under a burst.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::route::{Action, FFI_REASON, Layer, Live, NO_RUST, NO_WEB};
use super::rules::{FfiClosure, Kind, Rules, Status};
use super::*;

/// For tests: a watcher with its own emit and state folder.
fn test_watch(root: &Path, state: Option<PathBuf>, emit: Emit, live: Live) -> Watch {
    Watch {
        root: root.to_path_buf(),
        emit,
        stats: Arc::new(Mutex::new(Stats::default())),
        error: Arc::new(Mutex::new(None)),
        state,
        file: Arc::new(Mutex::new(())),
        probe: Arc::new(move |_| live),
        ffi: Some(FfiClosure::default()),
    }
}

/// For tests: run a watcher on `root` until the returned sender stops it.
fn test_spawn(watch: Watch) -> Sender<Wake> {
    let (sender, wakes) = channel();
    let wake = sender.clone();
    std::thread::Builder::new()
        .name("live-auto-test".into())
        .spawn(move || watch.run(wake, wakes))
        .expect("live auto test thread");
    sender
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn rules() -> Rules {
    let ffi = FfiClosure {
        inputs: vec!["cmux-tui/crates/cmux-app-ffi/".into(), "cmux-tui/crates/cmux-config/".into()],
        excluded: vec!["cmux-tui/crates/cmux-config/tests".into()],
    };
    Rules::load(&repo(), ffi).expect("the checkout's live-apply-rules.json")
}

fn kind(path: &str) -> Kind {
    rules().classify(Status::Modified, path, &[]).kind
}

fn swift(status: Status, path: &str, lines: &[(char, &str)]) -> (Kind, Vec<String>) {
    let lines: Vec<(char, String)> = lines.iter().map(|(s, t)| (*s, t.to_string())).collect();
    let verdict = rules().classify(status, path, &lines);
    (verdict.kind, verdict.reasons)
}

const LIVE_SWIFT: &str = "Packages/macOS/CmuxNext/Sources/CmuxNextShell/Sidebar.swift";

#[test]
fn classify_matches_live_apply_paths() {
    assert_eq!(kind("webviews/src/chat/Pane.tsx"), Kind::WebLive);
    assert_eq!(kind("clients/ts/cloud/src/generated.ts"), Kind::WebLive);
    assert_eq!(kind("cmux-tui/crates/cmux-tui-core/src/server.rs"), Kind::Daemon);
    assert_eq!(kind("cmux-tui/crates/acpmux/src/main.rs"), Kind::Daemon);
    assert_eq!(kind("cmux-tui/Cargo.lock"), Kind::Daemon);
    assert_eq!(kind("docs/rfd/0168-hot-swap-optimum.md"), Kind::NoApp);
    assert_eq!(kind("scripts/cmux-next/live_apply.py"), Kind::NoApp);
    assert_eq!(kind("webviews/src/chat/Pane.test.tsx"), Kind::NoApp);
    assert_eq!(kind("Resources/Localizable.xcstrings"), Kind::Strings);
    assert_eq!(kind("cmux-next-ios/App/Root.swift"), Kind::IosOnly);
    assert_eq!(kind("Packages/macOS/CmuxNext/Package.swift"), Kind::Rebuild);
    assert_eq!(kind("App/Info.plist"), Kind::Rebuild);
    assert_eq!(kind("README.txt"), Kind::NoApp);
    assert_eq!(kind("App/Thing.json"), Kind::Rebuild);
    assert_eq!(kind("design/icons/cmux.svg"), Kind::NoApp);
    assert_eq!(kind("vault/main.go"), Kind::NoApp);
    // A deleted file of no known kind is no-app, as live_apply.py says.
    assert_eq!(rules().classify(Status::Deleted, "OUTPUT", &[]).kind, Kind::NoApp);
}

#[test]
fn native_sources_rebuild_except_under_cmux_tui() {
    // The one rule live_apply.py wrote as a lookahead: split in the JSON.
    assert_eq!(kind("Native/Shim/shim.c"), Kind::Rebuild);
    assert_eq!(kind("App/Bridge.m"), Kind::Rebuild);
    assert_eq!(kind("cmux-tui/crates/ghostty-vt-sys/shim.c"), Kind::Daemon);
    assert_eq!(kind("cmux-tui/bindings/zig/cmux.zig"), Kind::Daemon);
}

#[test]
fn swift_body_edits_are_live_and_shape_edits_rebuild() {
    let body = [('-', "        return 1"), ('+', "        return 2")];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &body), (Kind::SwiftLive, vec![]));
    let stored = [('+', "    var count = 0")];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &stored).1, vec!["stored property".to_string()]);
    // A constant of no instance (#55251): the patch defines it and repoints its addressor.
    let constants = [('+', "    static let tint = Color.blue"), ('+', "private let inset = 4.0")];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &constants), (Kind::SwiftLive, vec![]));
    assert_eq!(
        swift(Status::Modified, LIVE_SWIFT, &[('+', "    static var tint = Color.blue")]).1,
        vec!["stored property".to_string()]
    );
    let sig = [
        ('-', "    func draw(_ rect: CGRect) {"),
        ('+', "    func draw(_ rect: CGRect, scale: Double) {"),
    ];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &sig).1, vec!["signature".to_string()]);
    let ty = [('+', "struct Badge: View {")];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &ty).1, vec!["type or conformance".to_string()]);
    let case = [('+', "    case narrow")];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &case).1, vec!["enum case".to_string()]);
    let comment = [('+', "    // why the badge waits")];
    assert_eq!(swift(Status::Modified, LIVE_SWIFT, &comment).0, Kind::SwiftLive);
    // A new file is new symbols the patch carries; a new entry point is not.
    assert_eq!(swift(Status::Added, LIVE_SWIFT, &[('+', "struct New {}")]).0, Kind::SwiftLive);
    assert_eq!(
        swift(Status::Added, LIVE_SWIFT, &[('+', "@main")]).1,
        vec!["new entry point".to_string()]
    );
    let main = "Packages/macOS/CmuxNext/Sources/CmuxNextShell/main.swift";
    assert_eq!(swift(Status::Added, main, &[]).1, vec!["new entry point".to_string()]);
    let outside = "Packages/macOS/Other/Sources/OtherKit/File.swift";
    let (k, why) = swift(Status::Modified, outside, &body);
    assert_eq!(k, Kind::Rebuild);
    assert_eq!(why, vec!["outside the live code modules (OtherKit)".to_string()]);
    // A deleted file's code stays in the binary: nothing to rebuild.
    assert_eq!(swift(Status::Deleted, outside, &[]).0, Kind::SwiftLive);
}

#[test]
fn change_classes_come_from_the_checkout() {
    let rules = rules();
    let class = |p| rules.change_class(p).map(|c| (c.name.clone(), c.swap.clone()));
    assert_eq!(class("webviews/src/a.ts"), Some(("web-ui".into(), "live".into())));
    assert_eq!(class("cmux-tui/crates/x/src/lib.rs"), Some(("rust-core".into(), "live".into())));
    assert_eq!(class("App/x.entitlements"), Some(("signing-release".into(), "never".into())));
}

#[test]
fn heaviest_follows_the_rules_order() {
    let rules = rules();
    assert_eq!(rules.heaviest([Kind::WebLive, Kind::Daemon, Kind::NoApp]), Kind::Daemon);
    assert_eq!(rules.heaviest([Kind::SwiftLive, Kind::Rebuild]), Kind::Rebuild);
    assert_eq!(rules.heaviest([]), Kind::NoApp);
}

fn files(paths: &[&str]) -> Vec<SavedFile> {
    paths.iter().map(|p| (Status::Modified, p.to_string(), Vec::new())).collect()
}

const ALL: Live = Live { web: true, rust: true, swift: true };

#[test]
fn route_sends_each_layer_its_own_paths() {
    let out = plan(
        &rules(),
        &files(&[
            "webviews/src/a.tsx",
            "cmux-tui/crates/cmux-tui-core/src/server.rs",
            LIVE_SWIFT,
            "docs/x.md",
            "App/Info.plist",
        ]),
        ALL,
    );
    let layers: Vec<(Layer, Action, Vec<String>)> =
        out.iter().map(|d| (d.layer, d.action.clone(), d.paths.clone())).collect();
    assert_eq!(
        layers,
        vec![
            (Layer::Web, Action::Observed, vec!["webviews/src/a.tsx".into()]),
            (
                Layer::Daemon,
                Action::HandOff,
                vec!["cmux-tui/crates/cmux-tui-core/src/server.rs".into()]
            ),
            (Layer::Swift, Action::Observed, vec![LIVE_SWIFT.into()]),
            (Layer::NeedsBuild, Action::Report, vec!["App/Info.plist".into()]),
        ]
    );
    assert!(out.iter().all(|d| d.layer == Layer::NeedsBuild || d.state_kept));
    assert_eq!(out[3].reason.as_deref(), Some("resource or manifest"));
}

#[test]
fn route_acpmux_alone_is_its_own_layer() {
    let out = plan(&rules(), &files(&["cmux-tui/crates/acpmux/src/daemon.rs"]), ALL);
    assert_eq!(out.len(), 1);
    assert_eq!((out[0].layer, out[0].action.clone()), (Layer::Acpmux, Action::HandOff));
    let both = plan(
        &rules(),
        &files(&[
            "cmux-tui/crates/acpmux/src/daemon.rs",
            "cmux-tui/crates/cmux-tui-core/src/lib.rs",
        ]),
        ALL,
    );
    assert_eq!(both[0].layer, Layer::Daemon);
}

#[test]
fn route_ffi_inputs_need_a_build_with_the_reason() {
    let out = plan(&rules(), &files(&["cmux-tui/crates/cmux-app-ffi/src/lib.rs"]), ALL);
    // rust-live still swaps the daemons that link it; the app's copy waits for a build.
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].layer, Layer::Daemon);
    assert_eq!(out[1].layer, Layer::NeedsBuild);
    assert_eq!(out[1].reason.as_deref(), Some(FFI_REASON));
    // Under an excluded folder (tests/): not an FFI input.
    let tests = plan(&rules(), &files(&["cmux-tui/crates/cmux-config/tests/load.rs"]), ALL);
    assert!(tests.iter().all(|d| d.layer != Layer::NeedsBuild), "{tests:?}");
}

#[test]
fn route_reports_a_layer_that_is_not_running() {
    let off = Live::default();
    let out = plan(
        &rules(),
        &files(&["webviews/src/a.tsx", "cmux-tui/crates/cmux-tui/src/main.rs"]),
        off,
    );
    assert_eq!(out[0].action, Action::Report);
    assert_eq!(out[0].error.as_deref(), Some(NO_WEB));
    assert!(!out[0].state_kept);
    assert_eq!(out[1].error.as_deref(), Some(NO_RUST));
    let swift = plan(&rules(), &files(&[LIVE_SWIFT]), off);
    assert_eq!(swift[0].layer, Layer::Swift);
    assert!(swift[0].error.is_some());
}

#[test]
fn route_no_app_saves_dispatch_nothing() {
    assert!(
        plan(&rules(), &files(&["docs/a.md", "tests/test_x.py", "scripts/x.sh"]), ALL).is_empty()
    );
}

#[test]
fn needs_build_groups_by_reason() {
    let out = plan(
        &rules(),
        &files(&[
            "App/Info.plist",
            "Assets.xcassets/Contents.json",
            "Resources/x.xcstrings",
            "ios/x.swift",
        ]),
        ALL,
    );
    let reasons: Vec<(Option<String>, usize)> =
        out.iter().map(|d| (d.reason.clone(), d.paths.len())).collect();
    assert_eq!(reasons.len(), 3, "{reasons:?}");
    assert_eq!(reasons[0], (Some("resource or manifest".into()), 2));
}

#[test]
fn event_carries_the_wire_fields() {
    let out = plan(&rules(), &files(&["webviews/src/a.tsx"]), ALL);
    let value = event(Path::new("/w"), &out[0], 3.25);
    assert_eq!(
        value,
        json!({"event": "swap.done", "worktree": "/w", "layer": "web", "ms": 3.25, "trigger_ms": 3.25,
               "state_kept": true, "paths": ["webviews/src/a.tsx"]})
    );
    let failed = plan(&rules(), &files(&["webviews/src/a.tsx"]), Live::default());
    assert_eq!(event(Path::new("/w"), &failed[0], 1.0)["error"], json!(NO_WEB));
}

#[test]
fn relevant_skips_build_output_and_scratch_files() {
    let root = Path::new("/w");
    assert_eq!(
        relevant(root, Path::new("/w/webviews/src/a.ts")).as_deref(),
        Some("webviews/src/a.ts")
    );
    assert_eq!(relevant(root, Path::new("/w/cmux-tui/target/debug/x.rs")), None);
    assert_eq!(relevant(root, Path::new("/w/webviews/node_modules/x/a.js")), None);
    assert_eq!(relevant(root, Path::new("/w/.git/index")), None);
    assert_eq!(relevant(root, Path::new("/w/a.rs~")), None);
    assert_eq!(relevant(root, Path::new("/w/.a.swift.swp")), None);
    assert_eq!(relevant(root, Path::new("/elsewhere/a.rs")), None);
}

#[test]
fn parse_diff_reads_u0_hunks() {
    let diff = "diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-    let a = 1\n+    let a = 2\n";
    let parsed = parse_diff(diff);
    assert_eq!(
        parsed["A.swift"],
        vec![('-', "    let a = 1".to_string()), ('+', "    let a = 2".to_string())]
    );
}

fn pending(paths: &[&str], saved_at: f64) -> Pending {
    Pending {
        worktree: PathBuf::from("/w"),
        layer: "daemon".into(),
        paths: paths.iter().map(|p| p.to_string()).collect(),
        saved_at,
        dispatched_at: saved_at + 0.01,
        trigger_ms: 9.0,
    }
}

#[test]
fn settle_reports_rust_live_receipts() {
    let swapped = json!({"saved_at": 100.0, "files": ["crates/cmux-tui-core/src/server.rs"], "daemons": ["cmux-tui"],
                         "outcome": "swapped", "save_to_swapped_secs": 4.5, "swap": {"cmux-tui": "app handoff"}});
    let (events, waiting) = settle(
        vec![pending(&["cmux-tui/crates/cmux-tui-core/src/server.rs"], 100.0)],
        &swapped,
        105.0,
    );
    assert!(waiting.is_empty());
    assert_eq!(events[0]["layer"], "daemon");
    assert_eq!(events[0]["ms"], 4500.0);
    assert_eq!(events[0]["trigger_ms"], 9.0);
    assert_eq!(events[0]["state_kept"], true);
    assert!(events[0].get("error").is_none());

    let restart = json!({"saved_at": 100.0, "files": [], "daemons": ["cmux-tui"], "outcome": "swapped",
                         "save_to_swapped_secs": 4.0, "swap": {"cmux-tui": "server restart"}});
    assert_eq!(settle(vec![pending(&["x"], 99.0)], &restart, 105.0).0[0]["state_kept"], false);

    let acp = json!({"saved_at": 100.0, "files": ["crates/acpmux/src/a.rs"], "daemons": ["acpmux"], "outcome": "swapped",
                     "save_to_swapped_secs": 3.0, "swap": {"acpmux": "daemon restart"}});
    let (events, _) =
        settle(vec![pending(&["cmux-tui/crates/acpmux/src/a.rs"], 100.0)], &acp, 104.0);
    assert_eq!(
        (events[0]["layer"].clone(), events[0]["state_kept"].clone()),
        (json!("acpmux"), json!(true))
    );

    let failed = json!({"saved_at": 100.0, "files": ["crates/x/src/a.rs"], "daemons": ["cmux-tui"],
                        "outcome": "build_failed", "errors": ["error[E0308]: mismatched types"]});
    let (events, _) = settle(vec![pending(&["cmux-tui/crates/x/src/a.rs"], 100.0)], &failed, 130.0);
    assert_eq!(events[0]["error"], "build_failed: error[E0308]: mismatched types");
    assert_eq!(events[0]["state_kept"], false);
    assert_eq!(events[0]["ms"], 30000.0);
}

#[test]
fn settle_keeps_newer_saves_waiting_and_times_out() {
    let old = json!({"saved_at": 100.0, "files": ["crates/a/src/a.rs"], "daemons": ["cmux-tui"], "outcome": "swapped"});
    let (events, waiting) =
        settle(vec![pending(&["cmux-tui/crates/b/src/b.rs"], 200.0)], &old, 201.0);
    assert!(events.is_empty());
    assert_eq!(waiting.len(), 1);
    let (events, waiting) = settle(waiting, &old, 200.0 + 31.0 * 60.0);
    assert!(waiting.is_empty());
    assert_eq!(events[0]["error"], "rust-live made no receipt for this save");
}

#[test]
fn percentiles_are_nearest_rank() {
    let samples: Vec<f64> = (1..=100).map(f64::from).collect();
    assert_eq!(percentiles(&samples), (50.0, 95.0));
    assert_eq!(percentiles(&[]), (0.0, 0.0));
}

// ---------------------------------------------------------------- the watcher, live

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        // Only the folder this test made.
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch(name: &str) -> Scratch {
    let dir = std::env::temp_dir().join(format!("cmux-live-auto-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("scripts/cmux-next")).unwrap();
    std::fs::create_dir_all(dir.join(".github")).unwrap();
    std::fs::copy(repo().join(rules::RULES_FILE), dir.join(rules::RULES_FILE)).unwrap();
    std::fs::copy(repo().join(rules::CLASSES_FILE), dir.join(rules::CLASSES_FILE)).unwrap();
    for sub in
        ["webviews/src", "cmux-tui/crates/cmux-tui-core/src", "docs", "webviews/node_modules/x"]
    {
        std::fs::create_dir_all(dir.join(sub)).unwrap();
    }
    Scratch(std::fs::canonicalize(&dir).unwrap())
}

fn spawn(root: &Path, state: Option<PathBuf>, live: Live) -> (Sender<Wake>, Receiver<Value>) {
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    let emit: Emit = Arc::new(move |payload| {
        let _ = lock(&tx).send(payload);
    });
    let stop = test_spawn(test_watch(root, state, emit, live));
    // The watch arms on its own thread: let it.
    std::thread::sleep(Duration::from_millis(300));
    (stop, rx)
}

#[test]
fn watcher_routes_a_save_and_ignores_noise() {
    let dir = scratch("route");
    let (stop, events) = spawn(&dir.0, None, ALL);
    std::fs::write(dir.0.join("webviews/node_modules/x/a.js"), "noise").unwrap();
    std::fs::write(dir.0.join("docs/a.md"), "no app").unwrap();
    std::fs::write(dir.0.join("webviews/src/a.tsx"), "export const a = 1;\n").unwrap();
    let got = events.recv_timeout(Duration::from_secs(10)).expect("a swap.done for the web save");
    assert_eq!(got["event"], "swap.done");
    assert_eq!(got["layer"], "web");
    assert_eq!(got["paths"], json!(["webviews/src/a.tsx"]));
    assert!(got["trigger_ms"].as_f64().unwrap() >= 0.0);
    assert!(events.recv_timeout(Duration::from_millis(300)).is_err(), "noise made no event");
    let _ = stop.send(Wake::Stop);
}

#[test]
fn watcher_hands_off_daemon_saves_and_reports_the_receipt() {
    let dir = scratch("handoff");
    let state = dir.0.join(".state");
    let receipts = dir.0.join(".rust-live");
    std::fs::create_dir_all(&receipts).unwrap();
    // rust_live_dir reads the environment; this test's watcher is given the folder directly.
    let watch = test_watch(&dir.0, Some(state.clone()), Arc::new(|_| {}), ALL);
    let rel = "cmux-tui/crates/cmux-tui-core/src/lib.rs".to_string();
    std::fs::write(dir.0.join(&rel), "pub fn a() {}\n").unwrap();
    let trigger = watch.dispatch(&rules(), std::slice::from_ref(&rel), Instant::now());
    assert!(trigger.is_some());
    let saved = load_state(&state);
    assert_eq!(saved.pending.len(), 1);
    assert_eq!(saved.pending[0].layer, "daemon");
    // A later daemon (rust-live swapped this one) reads the receipt.
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    let next = test_watch(
        &dir.0,
        Some(state.clone()),
        Arc::new(move |v| {
            let _ = lock(&tx).send(v);
        }),
        ALL,
    );
    let entry = json!({"saved_at": saved.pending[0].saved_at, "files": ["crates/cmux-tui-core/src/lib.rs"],
                       "daemons": ["cmux-tui"], "outcome": "swapped", "save_to_swapped_secs": 2.0,
                       "swapped_at": saved.pending[0].saved_at + 2.0, "swap": {"cmux-tui": "app handoff"}});
    std::fs::write(receipts.join("last.json"), entry.to_string()).unwrap();
    next.check_receipt(Some(&receipts));
    let got = rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!((got["layer"].clone(), got["ms"].clone()), (json!("daemon"), json!(2000.0)));
    assert!(load_state(&state).pending.is_empty());
    // The same receipt again reports nothing.
    next.check_receipt(Some(&receipts));
    assert!(rx.recv_timeout(Duration::from_millis(100)).is_err());
}

/// The router's trigger latency (last save's mtime to dispatch) under a
/// burst of saves while other work loads the machine: busy threads and
/// writers saving into ignored folders, as other sessions' builds do.
/// Prints `live-auto trigger p50=.. p95=..` (run with --nocapture).
#[test]
fn trigger_latency_under_a_burst_with_other_sessions() {
    let dir = scratch("burst");
    let (stop, events) = spawn(&dir.0, None, ALL);
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut load = Vec::new();
    for n in 0..6 {
        let done = done.clone();
        let noise = dir.0.join(format!("webviews/node_modules/x/n{n}"));
        load.push(std::thread::spawn(move || {
            let mut i = 0u64;
            while !done.load(std::sync::atomic::Ordering::Relaxed) {
                // Half spin, half saves the router must drop.
                for _ in 0..20_000 {
                    i = i.wrapping_mul(6364136223846793005).wrapping_add(1);
                }
                let _ = std::fs::write(&noise, i.to_le_bytes());
            }
        }));
    }
    let mut samples = Vec::new();
    for round in 0..40 {
        // A burst: an editor's format-on-save and a multi-file save.
        for f in 0..5 {
            std::fs::write(
                dir.0.join(format!("webviews/src/f{f}.tsx")),
                format!("export const v = {round};\n"),
            )
            .unwrap();
        }
        let started = Instant::now();
        let mut seen = 0;
        while seen < 5 && started.elapsed() < Duration::from_secs(10) {
            let Ok(got) = events.recv_timeout(Duration::from_secs(10)) else { break };
            seen += got["paths"].as_array().map_or(0, Vec::len);
            samples.push(got["trigger_ms"].as_f64().unwrap());
        }
        assert_eq!(seen, 5, "round {round}: every save of the burst was routed");
        std::thread::sleep(Duration::from_millis(30));
    }
    done.store(true, std::sync::atomic::Ordering::Relaxed);
    for thread in load {
        let _ = thread.join();
    }
    let _ = stop.send(Wake::Stop);
    let (p50, p95) = percentiles(&samples);
    println!(
        "live-auto trigger p50={p50:.1}ms p95={p95:.1}ms n={} (quiet {QUIET:?}, max {MAX_BURST:?})",
        samples.len()
    );
    // Loose: the bound that matters is the PR's measured number; this only
    // catches a router that stopped coalescing or blocked on a slow step.
    assert!(p95 < 1000.0, "p95 {p95} ms");
}
