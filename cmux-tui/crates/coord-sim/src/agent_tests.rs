use super::*;

#[test]
fn tags_round_trip_inside_json() {
    let t = tag(3, 1234, 7, 1_700_000_000_000_000);
    let v = update_json("tool_call_update", &t, 2000, 9, "x");
    let line = serde_json::to_string(&v).unwrap();
    assert_eq!(find_tags(&line), vec![(3, 1234, 7, 1_700_000_000_000_000)]);
    assert!(line.len() >= 1700 && line.len() <= 2200, "{}", line.len());
    assert_eq!(
        find_tags("[[cs:1:2]] [[cs:a:b:c:d]] [[cs:1:2:3:4]] [[cs:1:2:3:4]]"),
        vec![(1, 2, 3, 4)]
    );
    let call = serde_json::to_string(&update_json("tool_call", &t, 900, 1, "x")).unwrap();
    assert_eq!(find_tags(&call).len(), 1);
}

#[test]
fn kinds_map_to_updates() {
    assert_eq!(update_for("in:tool_call_update"), Some("tool_call_update"));
    assert_eq!(update_for("in:tool_call.replay"), Some("tool_call"));
    assert_eq!(update_for("in:claude.assistant"), Some("agent_thought_chunk"));
    assert_eq!(update_for("mux:turn_started"), None);
    assert_eq!(update_for("out:session/prompt"), None);
}

#[test]
fn segments_cut_at_user_turns() {
    let ev = |seq, op| SimEvent { seq, at_ms: seq, bytes: 10, op };
    let k = || Op::Event { kind: "in:plan".into() };
    let s =
        segments(&[ev(1, k()), ev(2, Op::UserTurn), ev(3, k()), ev(4, k()), ev(5, Op::UserTurn)]);
    assert_eq!(s.iter().map(Vec::len).collect::<Vec<_>>(), vec![1, 2, 0]);
}

#[test]
fn rates_parse() {
    assert_eq!(parse_rate("10x").unwrap(), 10.0);
    assert_eq!(parse_rate("1").unwrap(), 1.0);
    assert!(parse_rate("0").is_err());
}
