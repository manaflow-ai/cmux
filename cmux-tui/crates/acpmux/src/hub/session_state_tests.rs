use super::*;

const NOW: u64 = 1_800_000_000_000;
const MIN: u64 = 60_000;

fn st(row: Value) -> &'static str {
    of_row(&row, NOW, None).state.as_str()
}

#[test]
fn every_status_reads_one_of_four() {
    for status in [
        "idle",
        "ready",
        "running",
        "waiting",
        "disconnected",
        "closed",
        "unreachable",
        "failed",
        "",
        "something-new",
    ] {
        let s = st(json!({"status": status, "lastSeen": NOW - 30 * MIN}));
        assert!(["working", "waiting", "done", "errored"].contains(&s), "{status}: {s}");
    }
}

#[test]
fn local_rows() {
    assert_eq!(st(json!({"status": "running", "turn": {"startedAt": 1}})), "working");
    assert_eq!(st(json!({"status": "idle"})), "waiting");
    assert_eq!(st(json!({"status": "ready", "lastTurn": {"status": "completed"}})), "waiting");
    assert_eq!(st(json!({"status": "closed"})), "done");
    assert_eq!(st(json!({"status": "disconnected"})), "errored");
    assert_eq!(st(json!({"status": "ready", "lastTurn": {"status": "failed"}})), "errored");
    let w = of_row(&json!({"status": "waiting", "waitingOn": "question"}), NOW, None);
    assert_eq!((w.state, w.on.as_str()), (State::Waiting, "question"));
}

#[test]
fn unreachable_waits_then_resolves() {
    let row = |ago: u64, turn: Value| {
        json!({"status": "unreachable", "stale": true, "peer": "h", "lastSeen": NOW - ago,
               "turn": turn, "lastTurn": {"status": "completed"}})
    };
    let fresh = of_row(&row(5 * MIN, Value::Null), NOW, None);
    assert_eq!(fresh.state, State::Waiting);
    assert_eq!(fresh.until, Some(NOW - 5 * MIN + HOST_GRACE_MS));
    assert_eq!(st(row(20 * MIN, Value::Null)), "waiting", "answered: waits on the person");
    assert_eq!(st(row(20 * MIN, json!({"startedAt": 1}))), "errored", "mid-turn");
    let paused = of_row(&row(20 * MIN, json!({"startedAt": 1})), NOW, Some("retired"));
    assert_eq!(paused.state, State::Waiting);
    // No lastSeen at all: waits on the host, never unknown.
    assert_eq!(st(json!({"status": "unreachable"})), "waiting");
}

#[test]
fn json_names_the_decision() {
    let mut row = json!({"status": "disconnected"});
    set(&mut row, NOW);
    assert_eq!(row["sessionState"]["state"], "errored");
    assert_eq!(row["sessionState"]["decision"], "continue elsewhere or drop");
}
