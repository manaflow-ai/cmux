use super::*;

fn ask(redirect: bool, person: bool, local: bool, peers: bool) -> Ask<'static> {
    Ask { force: false, can_force: true, person, name: None, who: "test", local, peers, redirect }
}

#[test]
fn only_an_asking_agent_caller_on_a_lane_host_with_no_room_moves() {
    let agent = ask(true, false, true, true);
    assert_eq!(considered(&agent, true, true, false), Some(Reason::OverCap));
    assert_eq!(considered(&agent, true, false, true), Some(Reason::Busy));
    assert_eq!(considered(&agent, true, false, false), None, "room here: it stays");
    assert_eq!(considered(&agent, false, true, true), None, "no lanes entry: not a lane host");
    assert_eq!(considered(&ask(false, false, true, true), true, true, false), None, "old client");
    assert_eq!(considered(&ask(true, true, true, true), true, true, false), None, "a person");
    assert_eq!(considered(&ask(true, false, false, true), true, true, false), None, "Web");
    assert_eq!(considered(&ask(true, false, true, false), true, true, false), None, "a peer");
}

#[test]
fn a_create_tied_to_this_machine_never_moves() {
    let plain = json!({"cwd": "/w", "mcpServers": [], "_meta": {"acpmux": {
        "name": "r", "harness": "codex", "createKey": "k", "argv": ["acpmux"], FIELD: 1,
    }}});
    assert!(asked(&plain));
    assert!(movable(&plain));
    let without = json!({"cwd": "/w", "_meta": {"acpmux": {"name": "r"}}});
    assert!(!asked(&without) && !movable(&without), "no opt-in: an old client");
    for key in ["worktree", "env", "ephemeral", "workspaceId", "adopt", "credentials", "reportTo"] {
        let mut p = plain.clone();
        p["_meta"]["acpmux"][key] = json!(true);
        assert!(!movable(&p), "{key} ties it here");
    }
    let mut servers = plain.clone();
    servers["mcpServers"] = json!([{"name": "x"}]);
    assert!(!movable(&servers), "an MCP server of this machine");
}

#[test]
fn the_pick_must_have_room_and_no_shadow_defer() {
    let verdict = json!({"pick": "far", "why": "far: 4 cores free", "hosts": []});
    let room = |v: &Value| pick(v, Reason::OverCap, 13, Some(12));
    let p = room(&verdict).expect("a pick with room");
    assert_eq!((p.host.as_str(), p.why.as_str()), ("far", "placed on far: 4 cores free"));
    let full = json!({"pick": "far", "overloaded": true, "why": "every host is full"});
    assert_eq!(room(&full), None);
    let mut deferring = verdict.clone();
    deferring["shadow"] = json!({"would_defer": true});
    assert_eq!(room(&deferring), None);
}

#[test]
fn the_forward_names_the_peer_and_keeps_no_folder_or_opt_in() {
    let placed = Placed {
        host: "far".into(),
        why: "placed on far".into(),
        reason: Reason::OverCap,
        live: 13,
        max: Some(12),
    };
    let p = json!({"cwd": "/here", "mcpServers": [], "_meta": {"acpmux": {"name": "r", FIELD: 1}}});
    let f = forwarded(&p, &placed);
    assert_eq!(f.get("cwd"), None);
    assert_eq!(f.pointer("/_meta/acpmux/peer"), Some(&json!("far")));
    assert_eq!(f.pointer(&format!("/_meta/acpmux/{FIELD}")), None);
    assert_eq!(
        f.pointer("/_meta/acpmux/ifNameTaken"),
        Some(&json!(super::super::SUFFIX_TAKEN_NAME))
    );
    let a = answer(json!({"sessionId": "s1", "peer": "far"}), &placed);
    assert_eq!(a.pointer("/_meta/acpmux/placedOn"), Some(&json!("far")));
    assert_eq!(a.pointer("/_meta/acpmux/placement/version"), Some(&json!(VERSION)));
    assert_eq!(a.pointer("/_meta/acpmux/placement/reason"), Some(&json!("over-cap")));
}
