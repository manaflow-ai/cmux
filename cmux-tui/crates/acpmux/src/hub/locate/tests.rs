use super::*;

fn link(text: &str) -> AgentLink {
    crate::agent_link::find(text).unwrap().unwrap()
}

fn rows() -> Vec<Value> {
    vec![
        json!({"sessionId": "m1", "qualifiedSessionId": "local/m1", "agentSessionId": "a1",
                   "name": "review", "family": "claude", "harness": "claude"}),
        json!({"sessionId": "m2", "qualifiedSessionId": "hb/m2", "agentSessionId": "a2",
                   "name": "hb/builder", "family": "codex", "harness": "codex", "peer": "hb"}),
        json!({"sessionId": "m3", "qualifiedSessionId": "hb/m3", "agentSessionId": "a1",
                   "name": "hb/review", "family": "claude", "harness": "claude", "peer": "hb",
                   "tags": {"bead:cx-ab1.2": "1"}}),
    ]
}

fn ids(found: &[&Value]) -> Vec<String> {
    found.iter().map(|s| s["sessionId"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn a_link_finds_its_harness_session_on_the_host_it_names_first() {
    let rows = rows();
    let here = link("https://cmux.com/deeplink/agent?harness=claude&session=a1");
    assert_eq!(ids(&by_link(&rows, &here, "big-red")), ["m1", "m3"]);
    let on_hb = link("https://cmux.com/deeplink/agent?harness=claude&session=a1&host=hb");
    assert_eq!(ids(&by_link(&rows, &on_hb, "big-red")), ["m3", "m1"]);
    // The link's harness must be the session's family, or an older peer's harness.
    let wrong = link("https://cmux.com/deeplink/agent?harness=codex&session=a1");
    assert!(by_link(&rows, &wrong, "big-red").is_empty());
    let old = [
        json!({"sessionId": "o1", "agentSessionId": "a7", "name": "x", "harness": "codex"}),
        json!({"sessionId": "o2", "agentSessionId": "a7", "name": "y", "harness": "claude"}),
    ];
    let claude = link("https://cmux.com/deeplink/agent?harness=claude&session=a7");
    assert_eq!(ids(&by_link(&old, &claude, "big-red")), ["o2"]);
}

/// A peer's connection reads a card's session text masked, as it reads a summary's.
#[test]
fn a_card_reads_masked_on_a_peers_connection() {
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let summary = json!({
        "sessionId": "m1", "harness": "claude", "lastSeq": 3, "name": "deploy",
        "title": format!("rotate {token}"), "lastPrompt": format!("push {token}"),
        "lastMessage": {"role": "agent", "text": format!("used {token}")},
        "lastTurn": {"status": "failed", "errorText": format!("bad {token}")},
    });
    let reply = json!({"session": card(&summary, Some("big-red")), "matches": [card(&summary, Some("big-red"))]});
    let msg = crate::rpc::Message::ok(json!(1), reply);
    let Some(crate::rpc::Message::Response { result: Some(masked), .. }) =
        crate::server::peer_text::masked(&msg)
    else {
        panic!("a card with a secret is not masked for a peer");
    };
    assert!(!masked.to_string().contains("ghp_"), "{masked}");
    assert_eq!(masked["session"]["lastMessage"]["text"], "used [GitHub Personal Access Token]");
    assert_eq!(masked["session"]["name"], "deploy");
}

#[test]
fn a_link_to_a_moved_chat_leads_to_where_it_runs_now() {
    // m1 ran on desk-mac and moved to gcp-1, keeping its ids (`transfer_in.rs`).
    let rows = vec![
        json!({"sessionId": "m1", "agentSessionId": "a1", "name": "fix", "family": "codex",
                   "harness": "codex", "status": "closed",
                   "movedTo": {"host": "gcp-1", "sessionId": "m1", "cwd": "/home/cmux/w"}}),
        json!({"sessionId": "m1", "agentSessionId": "a1", "name": "gcp-1/fix",
                   "family": "codex", "harness": "codex", "peer": "gcp-1", "status": "idle"}),
    ];
    let footer = link("https://cmux.com/deeplink/agent?harness=codex&session=a1&host=desk-mac");
    let found = follow_moves(by_link(&rows, &footer, "desk-mac"), &rows, "desk-mac");
    assert_eq!(found[0]["peer"], "gcp-1", "the live copy first: {found:?}");
    assert!(found[1]["movedTo"].is_object());
    // By id or name too, and the target joins even when only the moved copy matched.
    let found = follow_moves(by_key(&rows, "desk-mac/fix", "desk-mac"), &rows, "desk-mac");
    assert_eq!(found.len(), 2, "{found:?}");
    assert_eq!(found[0]["peer"], "gcp-1");
    // A target not listed (its peer is gone): the moved copy answers, saying where it went.
    let alone = &rows[..1];
    let found = follow_moves(by_key(alone, "m1", "desk-mac"), alone, "desk-mac");
    assert_eq!(found.len(), 1);
    assert_eq!(card(found[0], Some("desk-mac"))["movedTo"]["host"], "gcp-1");
}

#[test]
fn a_key_finds_by_id_then_host_and_name_then_bare_name() {
    let rows = rows();
    assert_eq!(ids(&by_key(&rows, "hb/m2", "big-red")), ["m2"]);
    assert_eq!(ids(&by_key(&rows, "a2", "big-red")), ["m2"]);
    assert_eq!(ids(&by_key(&rows, "review", "big-red")), ["m1", "m3"]);
    assert_eq!(ids(&by_key(&rows, "big-red/review", "big-red")), ["m1"]);
    assert_eq!(ids(&by_key(&rows, "builder", "big-red")), ["m2"]);
    assert!(by_key(&rows, "nobody", "big-red").is_empty());
}

#[test]
fn locate_prefers_a_closed_exact_name_over_a_live_prefix() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    for (id, name, status) in [("closed", "review", "closed"), ("live", "review-2", "idle")] {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA,
            "id": id,
            "name": name,
            "harness": "claude",
            "family": "claude",
            "cwd": "/tmp",
            "status": status,
            "createdAt": 1,
            "updatedAt": 1
        }))
        .unwrap();
        hub.insert_test_session(meta);
    }
    let found = hub.locate("review", false, false).unwrap();
    assert_eq!(found["session"]["sessionId"], "closed");
}

#[test]
fn a_bead_id_finds_the_sessions_that_carry_it() {
    let rows = rows();
    assert_eq!(ids(&by_key(&rows, "cx-ab1.2", "big-red")), ["m3"]);
    assert!(by_key(&rows, "cx-ab1", "big-red").is_empty());
    // A session named like the bead wins a plain lookup, never a bead-only one.
    let mut named = rows.clone();
    named.push(json!({"sessionId": "m4", "name": "cx-ab1.2", "harness": "claude"}));
    assert_eq!(ids(&by_key(&named, "cx-ab1.2", "big-red")), ["m4"]);
    assert_eq!(ids(&by_bead(&named, "cx-ab1.2")), ["m3"]);
    assert_eq!(card(&rows[2], Some("big-red"))["beads"], json!(["cx-ab1.2"]));
    assert_eq!(card(&rows[0], Some("big-red"))["beads"], json!([]));
}

/// A sub-session (`PARENT/SHORT`) is found by its short name, here or on a peer, on a `/`
/// boundary only, and only when no whole name matches.
#[test]
fn a_sub_session_is_found_by_its_short_name() {
    let mut rows = rows();
    rows.push(json!({"sessionId": "m5", "name": "claude-sr2/mac-ci-3", "harness": "claude"}));
    rows.push(json!({"sessionId": "m6", "name": "hb/claude-sr2/mac-ci-4", "peer": "hb",
                         "harness": "claude"}));
    assert_eq!(ids(&by_key(&rows, "mac-ci-3", "mac-a")), ["m5"]);
    assert_eq!(ids(&by_key(&rows, "mac-ci-4", "mac-a")), ["m6"]);
    assert_eq!(ids(&by_key(&rows, "hb/mac-ci-4", "mac-a")), ["m6"]);
    assert_eq!(ids(&by_key(&rows, "mac-a/mac-ci-3", "mac-a")), ["m5"]);
    assert!(by_key(&rows, "ci-3", "mac-a").is_empty());
    rows.push(json!({"sessionId": "m7", "name": "mac-ci-3", "harness": "claude"}));
    assert_eq!(ids(&by_key(&rows, "mac-ci-3", "mac-a")), ["m7"], "a whole name wins");
}

/// Review of #27791: a host-qualified key keeps that host's exact name first, and a short
/// name never crosses to another host.
#[test]
fn a_host_qualified_short_name_stays_on_its_host_after_its_exact_names() {
    let rows = vec![
        json!({"sessionId": "m1", "name": "lane", "harness": "claude"}),
        json!({"sessionId": "m2", "name": "parent/hb/lane", "harness": "claude"}),
        json!({"sessionId": "m3", "name": "cg/parent/hb/x", "peer": "cg", "harness": "claude"}),
        json!({"sessionId": "m4", "name": "a/x", "harness": "claude"}),
    ];
    assert_eq!(ids(&by_key(&rows, "hb/lane", "hb")), ["m1"]);
    assert!(by_key(&rows, "nohost/x", "hb").is_empty());
    assert_eq!(ids(&by_key(&rows, "hb/x", "hb")), ["m4"], "on host hb only, not cg's m3");
    assert_eq!(ids(&by_key(&rows, "x", "hb")), ["m3", "m4"], "a bare one: both, a tie");
    // A prefix still wins, as before short names.
    let mut rows = rows;
    rows.push(json!({"sessionId": "m5", "name": "xy", "harness": "claude"}));
    assert_eq!(ids(&by_key(&rows, "x", "hb")), ["m5"]);
}

#[test]
fn a_card_carries_the_sessions_own_link() {
    let rows = rows();
    let card = card(&rows[2], Some("big-red"));
    assert_eq!(card["host"], "hb");
    assert_eq!(
        card["link"],
        "https://cmux.com/deeplink/agent?harness=claude&session=a1&host=hb&name=review"
    );
    let none = card_without_agent_id();
    assert_eq!(none["link"], Value::Null);
}

fn card_without_agent_id() -> Value {
    card(&json!({"sessionId": "m9", "name": "new one", "harness": "claude"}), Some("big-red"))
}
