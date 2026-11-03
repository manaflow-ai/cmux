//! DIAG (not for merge, HOT PATH AUDIT area D, agent hpa-state): measures the
//! daemon side of one state change at scale and prints `HPADIAG` lines. It
//! asserts nothing; the numbers go to handoff/hot-path-audit/state/AUDIT.md.

use super::tests::{captured_writer, test_mux};
use super::*;

fn run(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, request: Value) -> Option<Value> {
    let command: Command = match serde_json::from_value(request.clone()) {
        Ok(command) => command,
        Err(error) => {
            println!("HPADIAG parse-error {request} {error}");
            return None;
        }
    };
    match handle_command(mux, client, command, writer) {
        Ok(value) => Some(value),
        Err(error) => {
            println!("HPADIAG command-error {request} {error:#}");
            None
        }
    }
}

fn quantiles(mut values: Vec<f64>) -> String {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let at = |q: f64| values[((values.len() as f64 - 1.0) * q).round() as usize];
    format!(
        "n={} p50={:.3} p95={:.3} p99={:.3} max={:.3}",
        values.len(),
        at(0.5),
        at(0.95),
        at(0.99),
        at(1.0)
    )
}

/// Lines the subscriber got within a bounded wait (no sleep: yields until the
/// stream is quiet for `quiet`).
fn drain(outbound: &BoundedOutbound, quiet: Duration) -> Vec<String> {
    let mut lines = Vec::new();
    let mut last = Instant::now();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && last.elapsed() < quiet {
        if let Some(line) = outbound.try_pop() {
            lines.push(line);
            last = Instant::now();
        } else {
            std::thread::yield_now();
        }
    }
    lines
}

fn kind(line: &str) -> String {
    serde_json::from_str::<Value>(line)
        .ok()
        .and_then(|value| {
            value
                .get("event")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or_else(|| value.get("id").map(|_| "reply".to_string()))
        })
        .unwrap_or_else(|| "other".to_string())
}

fn grow(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, to: usize, panes: &mut Vec<PaneId>) {
    let have = mux.with_state(|state| state.workspaces.len());
    for _ in have..to {
        let first = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        panes.push(pane);
        run(mux, client, writer, json!({"cmd": "new-tab", "pane": pane}));
        run(mux, client, writer, json!({"cmd": "split", "pane": pane, "dir": "right"}));
    }
}

#[test]
fn hpa_state_probe_daemon_side_of_one_change() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    run(
        &mux,
        client,
        &writer,
        json!({"cmd": "set-client-info", "name": "hpa probe",
        "capabilities": ["tree-selection-deltas-v1", "subscribe-scroll-on-attach-v1"]}),
    );
    run(&mux, client, &writer, json!({"cmd": "subscribe", "tree_events": "deltas"}));

    let mut panes = Vec::new();
    for size in [100usize, 400] {
        grow(&mux, client, &writer, size, &mut panes);
        drain(&outbound, Duration::from_millis(300));
        let tabs = mux.with_state(|state| state.panes.len());
        println!("HPADIAG scale workspaces={size} panes={tabs}");

        // One full-tree read: the time under Mux::state, the whole reply and its bytes.
        let (mut held, mut whole, mut bytes) = (Vec::new(), Vec::new(), 0usize);
        for _ in 0..30 {
            let decorations = mux.tree_decorations();
            let start = Instant::now();
            let tree =
                mux.with_state(|state| super::tree_json::workspaces_json(state, &decorations));
            held.push(start.elapsed().as_secs_f64() * 1000.0);
            drop(tree);
            let start = Instant::now();
            let reply = list_workspaces_reply(&mux).unwrap();
            let line = serde_json::to_vec(&reply).unwrap();
            whole.push(start.elapsed().as_secs_f64() * 1000.0);
            bytes = line.len();
        }
        println!(
            "HPADIAG list-workspaces W={size} bytes={bytes} bytes_per_workspace={}",
            bytes / size
        );
        println!("HPADIAG list-workspaces W={size} state_lock_held_ms {}", quantiles(held));
        println!("HPADIAG list-workspaces W={size} build_and_serialize_ms {}", quantiles(whole));

        // A whole State clone (the rollback copy of `stage_checked`).
        let mut cloned = Vec::new();
        for _ in 0..30 {
            let start = Instant::now();
            let copy = mux.with_state(|state| state.clone());
            cloned.push(start.elapsed().as_secs_f64() * 1000.0);
            drop(copy);
        }
        println!("HPADIAG state-clone W={size} ms {}", quantiles(cloned));
        let mut decorations = Vec::new();
        for _ in 0..30 {
            let start = Instant::now();
            let made = mux.tree_decorations();
            decorations.push(start.elapsed().as_secs_f64() * 1000.0);
            drop(made);
        }
        println!("HPADIAG tree-decorations W={size} ms {}", quantiles(decorations));

        // One change of each kind: handler time, then what one delta subscriber gets.
        let ids = mux.with_state(|state| {
            state
                .workspaces
                .iter()
                .map(|w| (serde_json::to_value(&w.id).unwrap(), w.key.clone()))
                .collect::<Vec<_>>()
        });
        let middle = ids[size / 2].clone();
        let _ = &middle.1;
        let pane = panes[size / 2];
        let changes: Vec<(&str, Value)> = vec![
            (
                "rename-workspace",
                json!({"cmd": "rename-workspace", "workspace": middle.0, "name": "probe"}),
            ),
            ("move-workspace", json!({"cmd": "move-workspace", "workspace": middle.0, "index": 0})),
            (
                "move-workspace-back",
                json!({"cmd": "move-workspace", "workspace": middle.0, "index": size / 2}),
            ),
            ("select-tab", json!({"cmd": "select-tab", "pane": pane, "index": 0})),
            ("select-tab-again", json!({"cmd": "select-tab", "pane": pane, "index": 1})),
            ("new-tab", json!({"cmd": "new-tab", "pane": pane})),
            ("split", json!({"cmd": "split", "pane": pane, "dir": "down"})),
        ];
        crate::mux::HPA_PHASES_ON.store(size == 400, std::sync::atomic::Ordering::Relaxed);
        for (name, request) in changes {
            let mut times = Vec::new();
            let mut last = Vec::new();
            for round in 0..10 {
                let mut request = request.clone();
                if name == "rename-workspace" {
                    request["name"] = json!(format!("probe-{round}"));
                }
                let start = Instant::now();
                run(&mux, client, &writer, request);
                times.push(start.elapsed().as_secs_f64() * 1000.0);
                last = drain(&outbound, Duration::from_millis(150));
            }
            let mut kinds: BTreeMap<String, (usize, usize)> = BTreeMap::new();
            for line in &last {
                let entry = kinds.entry(kind(line)).or_default();
                entry.0 += 1;
                entry.1 += line.len();
            }
            let summary = kinds
                .iter()
                .map(|(k, (n, b))| format!("{k}:{n}/{b}B"))
                .collect::<Vec<_>>()
                .join(" ");
            println!(
                "HPADIAG change W={size} {name} handler_ms {} lines_last_round [{summary}]",
                quantiles(times)
            );
        }
    }

    // Fan-out: the cost of one emit with N `All` subscribers (each gets a clone).
    for subscribers in [1usize, 8, 32] {
        let receivers = (0..subscribers).map(|_| mux.subscribe()).collect::<Vec<_>>();
        let entity = mux.with_state(|state| {
            super::tree_json::workspaces_json(state, &mux.tree_decorations_in_state(state))
        });
        let one = entity["workspaces"][0].clone();
        let mut times = Vec::new();
        for _ in 0..200 {
            let start = Instant::now();
            mux.emit(crate::mux::MuxEvent::Status(one.to_string()));
            times.push(start.elapsed().as_secs_f64() * 1000.0);
            for receiver in &receivers {
                while receiver.try_recv().is_ok() {}
            }
        }
        println!(
            "HPADIAG emit subscribers={subscribers} event_bytes={} ms {}",
            one.to_string().len(),
            quantiles(times)
        );
    }
    mux.shutdown();
    // nextest prints a test's output only when it fails.
    panic!("HPADIAG done: this DIAG test fails on purpose so its output prints");
}
