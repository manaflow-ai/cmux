use super::*;

fn node(name: &str, cat: &str, start: i64, end: i64, deps: &[usize]) -> Node {
    Node { name: name.into(), cat: cat.into(), state: State::Tool, start, end, deps: deps.to_vec() }
}

/// a -> {b (long), c (short)} -> d: the short branch has no drag, the long one drags by its
/// lead over the short one.
#[test]
fn fork_join_drag() {
    let mut g = Graph::default();
    let a = g.push(node("a", "model", 0, 10, &[]));
    let b = g.push(node("b", "long", 10, 110, &[a]));
    let c = g.push(node("c", "short", 10, 40, &[a]));
    g.push(node("d", "model", 110, 120, &[b, c]));
    assert_eq!(g.elapsed(), 120);
    let path: Vec<&str> = g.critical_path().iter().map(|s| g.nodes[s.node].name.as_str()).collect();
    assert_eq!(path, ["a", "b", "d"]);
    let drag: BTreeMap<String, i64> = g.drag_by_cat().into_iter().map(|(c, d, _)| (c, d)).collect();
    assert_eq!(drag["long"], 70, "b's lead over c");
    assert_eq!(drag["model"], 20);
    assert!(!drag.contains_key("short"), "c is off the path");
}

/// A gap (a node starting after its waker ended) stays in the schedule, so zeroing the waker
/// still saves the waker's time, and the gap shows on the path as wait.
#[test]
fn gaps_are_kept_and_counted_as_wait() {
    let mut g = Graph::default();
    let a = g.push(node("a", "x", 0, 50, &[]));
    g.push(node("b", "y", 80, 100, &[a]));
    assert_eq!(g.elapsed(), 100);
    assert_eq!(g.makespan_with(|_, n| n.cat == "x"), 50);
    let st = g.path_by_state();
    assert_eq!(st[&State::Wait], 30);
    assert_eq!(st[&State::Tool], 70);
}

#[test]
fn roots_keep_their_arrival() {
    let mut g = Graph::default();
    g.push(node("early", "x", 0, 10, &[]));
    g.push(node("late", "y", 100, 130, &[]));
    assert_eq!(g.elapsed(), 130);
    assert_eq!(
        g.makespan_with(|_, n| n.cat == "x"),
        130,
        "zeroing a root that ends early saves nothing"
    );
    assert_eq!(g.drag_by_node()[0], (1, 30));
}

#[test]
fn spans_file_follows_links_any_order() {
    let text = r#"
{"run":"pr#1","id":"merge","name":"merge","cat":"queue","start":300,"end":310,"follows":["ci-mac","ci-linux"]}
{"run":"pr#1","id":"push","name":"push","cat":"ours","state":"ours","start":0,"end":5}
{"run":"pr#1","id":"ci-mac","name":"mac","cat":"ci:mac","start":20,"end":290,"follows":["push"]}
{"run":"pr#1","id":"ci-linux","name":"linux","cat":"ci:linux","start":10,"end":100,"follows":["push"]}
not json
"#;
    let (graphs, bad) = spans::parse(text);
    assert_eq!(bad, 1);
    assert_eq!(graphs.len(), 1);
    let g = &graphs[0];
    let path: Vec<&str> = g.critical_path().iter().map(|s| g.nodes[s.node].name.as_str()).collect();
    assert_eq!(path, ["push", "mac", "merge"]);
    let drag: BTreeMap<String, i64> = g.drag_by_cat().into_iter().map(|(c, d, _)| (c, d)).collect();
    assert_eq!(
        drag["ci:mac"], 190,
        "mac zeroed: linux (with its 5 ms gap) and the 10 ms gap before merge stay"
    );
}

#[test]
fn command_words() {
    assert_eq!(acpmux::command_word("cd /x && cargo test -p a").as_deref(), Some("cargo"));
    assert_eq!(
        acpmux::command_word("FOO=1 /usr/local/bin/glaeda-gh wait pr 1").as_deref(),
        Some("glaeda-gh")
    );
    assert_eq!(acpmux::command_word("  ").as_deref(), None);
    assert_eq!(acpmux::command_word("timeout 30 gh pr view 1").as_deref(), Some("gh"));
    assert_eq!(
        acpmux::command_word("for f in a b; do nice -n 10 rg x $f; done").as_deref(),
        Some("rg")
    );
}

/// A turn from real event shapes: queued, dequeued, started, a stall with nothing running, the
/// write, a first token, two parallel tool calls, the end.
#[test]
fn acpmux_turn_with_stall_and_parallel_tools() {
    let dir = std::env::temp_dir().join(format!("critpath-test-{}", std::process::id()));
    let events = dir.join("s1/events");
    std::fs::create_dir_all(&events).unwrap();
    let now = std::time::SystemTime::now();
    let t0 = now.duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64 - 60_000;
    let tool = |at: i64, id: &str, status: &str, cmd: &str| {
        format!(
            r#"{{"seq":1,"at":{at},"dir":"in","kind":"tool_call_update","msg":{{"params":{{"update":{{"_meta":{{"claude":{{"tool":"Bash"}}}},"toolCallId":"{id}","status":"{status}","rawInput":{{"command":"{cmd}"}}}}}}}}}}"#
        )
    };
    let lines = [
        format!(r#"{{"seq":1,"at":{t0},"dir":"mux","kind":"queued","msg":{{"promptId":"p1"}}}}"#),
        format!(
            r#"{{"seq":2,"at":{},"dir":"mux","kind":"dequeued","msg":{{"promptId":"p1"}}}}"#,
            t0 + 100
        ),
        format!(
            r#"{{"seq":3,"at":{},"dir":"mux","kind":"turn_started","msg":{{"promptId":"p1"}}}}"#,
            t0 + 102
        ),
        format!(r#"{{"seq":4,"at":{},"dir":"mux","kind":"inbox","msg":{{}}}}"#, t0 + 5_102),
        format!(
            r#"{{"seq":5,"at":{},"dir":"out","kind":"session/prompt","msg":{{}}}}"#,
            t0 + 5_103
        ),
        format!(
            r#"{{"seq":6,"at":{},"dir":"in","kind":"agent_message_chunk","msg":{{}}}}"#,
            t0 + 7_103
        ),
        tool(t0 + 8_000, "a", "pending", "cargo build"),
        tool(t0 + 8_010, "b", "pending", "ls"),
        tool(t0 + 8_500, "b", "completed", "ls"),
        tool(t0 + 18_000, "a", "completed", "cargo build"),
        format!(r#"{{"seq":9,"at":{},"dir":"mux","kind":"turn_end","msg":{{}}}}"#, t0 + 20_000),
    ];
    std::fs::write(events.join("000001.ndjson"), lines.join("\n") + "\n").unwrap();
    let report = acpmux::read(&dir, 1.0, now);
    std::fs::remove_dir_all(&dir).ok();
    assert_eq!(report.graphs.len(), 1);
    assert_eq!(report.stalls.len(), 1);
    assert_eq!(report.stalls[0].ms, 5_001);
    assert_eq!(report.stalls[0].waker, "mux:inbox");
    assert_eq!(report.stalls[0].released_by, "event", "the write came 1 ms after the inbox event");
    let g = &report.graphs[0];
    assert_eq!(g.elapsed(), 20_000);
    let drag: BTreeMap<String, i64> = g.drag_by_cat().into_iter().map(|(c, d, _)| (c, d)).collect();
    assert_eq!(drag["acpmux:stall"], 5_001);
    assert_eq!(drag["tool:Bash:cargo"], 9_500, "cargo ends 9.5 s after ls");
    assert!(!drag.contains_key("tool:Bash:ls"));
    assert_eq!(drag["model:first-token"], 2_000);
}
