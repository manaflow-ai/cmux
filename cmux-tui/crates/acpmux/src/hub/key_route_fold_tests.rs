//! A name in another case, a prefix of it, or the name without its separators finds the one
//! session it names, here, on a peer and as `HOST/NAME`; several are refused with each one
//! (Leo, 2026-11-05: "stuff like that should work better yes").

use super::tests::{list, named, test_hub};
use super::*;

fn uses(e: &RpcError) -> Vec<String> {
    let data = e.data.clone().unwrap_or_default();
    assert_eq!(data["reason"], AMBIGUOUS, "{e:?}");
    data["choices"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|c| c["use"].as_str().map(str::to_owned))
        .collect()
}

#[tokio::test]
async fn a_name_in_another_case_finds_the_peers_one_session() {
    let hub = test_hub();
    list(&hub, "lanevm-7", "0199aaaa-1111", "td2-A", "idle");
    list(&hub, "lanevm-7", "0199bbbb-2222", "td2-B", "idle");
    assert_eq!(hub.key_route("td2-a").unwrap().as_deref(), Some("lanevm-7/0199aaaa-1111"));
    assert_eq!(hub.key_route("lanevm-7/td2-a").unwrap().as_deref(), Some("lanevm-7/0199aaaa-1111"));
    // The host in another case, or a unique prefix of it, too.
    assert_eq!(hub.key_route("LANEVM-7/td2-a").unwrap().as_deref(), Some("lanevm-7/0199aaaa-1111"));
    assert_eq!(hub.key_route("lanevm/TD2-B").unwrap().as_deref(), Some("lanevm-7/0199bbbb-2222"));
}

#[tokio::test]
async fn a_name_in_another_case_finds_the_one_session_here() {
    let hub = test_hub();
    let a = named(&hub, "td2-A").await;
    named(&hub, "td2-B").await;
    assert_eq!(hub.key_route("td2-a").unwrap().as_deref(), Some(a.id.as_str()));
    assert_eq!(hub.key_route("TD2_a").unwrap().as_deref(), Some(a.id.as_str()));
}

#[tokio::test]
async fn a_prefix_four_sessions_share_is_refused_with_all_four() {
    let hub = test_hub();
    for (id, name) in
        [("0199a", "td2-A"), ("0199b", "td2-B"), ("0199c", "td2-C"), ("0199d", "td2-D")]
    {
        list(&hub, "lanevm-7", id, name, "idle");
    }
    let e = hub.key_route("lanevm-7/td2").unwrap_err();
    let mut got = uses(&e);
    got.sort();
    assert_eq!(got, ["lanevm-7/td2-A", "lanevm-7/td2-B", "lanevm-7/td2-C", "lanevm-7/td2-D"]);
    for name in ["td2-A", "td2-B", "td2-C", "td2-D"] {
        assert!(e.message.contains(name), "{}", e.message);
    }
    // The same four here, by a bare prefix.
    let hub = test_hub();
    for name in ["td2-A", "td2-B", "td2-C", "td2-D"] {
        named(&hub, name).await;
    }
    let e = hub.key_route("td2").unwrap_err();
    assert_eq!(uses(&e).len(), 4, "{e:?}");
}

#[tokio::test]
async fn an_exact_name_wins_over_one_in_another_case() {
    let hub = test_hub();
    list(&hub, "lanevm-7", "0199aaaa-1111", "td2-A", "idle");
    list(&hub, "lanevm-8", "0199bbbb-2222", "td2-a", "idle");
    assert_eq!(hub.key_route("td2-a").unwrap().as_deref(), Some("lanevm-8/0199bbbb-2222"));
    assert_eq!(hub.key_route("td2-A").unwrap().as_deref(), Some("lanevm-7/0199aaaa-1111"));
    // A third spelling names both: refused, never guessed.
    assert_eq!(uses(&hub.key_route("TD2-a").unwrap_err()).len(), 2);
}

#[tokio::test]
async fn a_host_prefix_two_machines_share_is_refused_with_both() {
    let hub = test_hub();
    list(&hub, "lanevm-7", "0199aaaa-1111", "td2-A", "idle");
    list(&hub, "lanevm-8", "0199bbbb-2222", "td2-A", "idle");
    let mut got = uses(&hub.key_route("lanevm/td2-A").unwrap_err());
    got.sort();
    assert_eq!(got, ["lanevm-7/td2-A", "lanevm-8/td2-A"]);
}

#[tokio::test]
async fn a_host_in_another_case_or_by_a_prefix_names_its_one_peer() {
    let hub = test_hub();
    list(&hub, "lanevm-7", "0199aaaa-1111", "td2-A", "idle");
    list(&hub, "lanevm-8", "0199bbbb-2222", "td2-B", "idle");
    assert_eq!(hub.host_route("LANEVM-7").unwrap().as_deref(), Some("lanevm-7"));
    assert_eq!(hub.host_route("lanevm_8").unwrap().as_deref(), Some("lanevm-8"));
    assert_eq!(hub.host_route("auto").unwrap(), None);
    assert_eq!(hub.host_route("nowhere").unwrap(), None);
    let e = hub.host_route("lanevm").unwrap_err();
    assert_eq!(e.data.clone().unwrap()["reason"], HOST_AMBIGUOUS, "{e:?}");
    assert!(e.message.contains("lanevm-7, lanevm-8"), "{}", e.message);
}

/// `resolve` (and `session stop|cancel|resume` through it) falls back to the same route.
#[tokio::test]
async fn resolve_finds_a_name_in_another_case_and_refuses_a_shared_prefix() {
    let hub = test_hub();
    let a = named(&hub, "td2-A").await;
    named(&hub, "td2-B").await;
    let found = hub.locate("td2_a", false, true).unwrap();
    assert_eq!(found["matches"].as_array().unwrap().len(), 1, "{found}");
    assert_eq!(found["session"]["sessionId"], a.id.as_str(), "{found}");
    let e = hub.locate("TD2", false, true).unwrap_err();
    assert_eq!(uses(&e).len(), 2, "{e:?}");
}

/// Review of #36878 (F1): a name in another case on a peer beats a longer name here that only
/// starts with the key, in `resolve` (and `session stop|cancel|resume`) as in every other command.
#[tokio::test]
async fn resolve_takes_a_name_in_another_case_over_a_longer_name_here() {
    let hub = test_hub();
    named(&hub, "td2-alpha").await;
    let a = named(&hub, "TD2-A").await;
    assert_eq!(hub.key_route("td2-a").unwrap().as_deref(), Some(a.id.as_str()));
    // `locate` reads only configured peers' rows (this test hub has none), so both are here;
    // its old case-sensitive prefix took `td2-alpha`.
    let found = hub.locate("td2-a", false, true).unwrap();
    assert_eq!(found["matches"].as_array().unwrap().len(), 1, "{found}");
    assert_eq!(found["session"]["sessionId"], a.id.as_str(), "{found}");
}

/// Review of #36878 (F2): a sub-session's short name in another case or without separators
/// finds it too, bare and as `HOST/SHORT`.
#[tokio::test]
async fn a_sub_sessions_short_name_in_another_case_finds_it() {
    let hub = test_hub();
    list(&hub, "lanevm-7", "0199aaaa-1111", "coord/td2-A", "idle");
    list(&hub, "lanevm-7", "0199bbbb-2222", "coord/td2-B", "idle");
    for key in ["td2-a", "td2_a", "lanevm-7/td2-a", "LANEVM-7/TD2A"] {
        assert_eq!(hub.key_route(key).unwrap().as_deref(), Some("lanevm-7/0199aaaa-1111"), "{key}");
    }
}

/// Review of #36919: a bead id one session carries finds that session in `resolve`, never
/// another session whose name only starts with the id.
#[tokio::test]
async fn resolve_takes_the_session_carrying_a_bead_over_a_name_it_starts() {
    let hub = test_hub();
    let carrier = named(&hub, "fixer").await;
    named(&hub, "cx-ab1.2-worker").await;
    let tags = json!({ crate::beads::tag_key("cx-ab1.2"): "1" });
    hub.set_tags(&carrier, tags.as_object(), &[], None);
    let found = hub.locate("cx-ab1.2", false, true).unwrap();
    assert_eq!(found["matches"].as_array().unwrap().len(), 1, "{found}");
    assert_eq!(found["session"]["sessionId"], carrier.id.as_str(), "{found}");
}

/// A configured peer that never runs, so `HOST/NAME` takes the configured-peer path
/// (`key_route`'s `self.peer(host)`), as `own_host.rs`'s tests add one.
fn add_peer(hub: &Hub, name: &str) {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer);
}

/// Review of #36919 (F1): `HOST/SHORT` naming a sub-session's short name exactly reaches that
/// child, never a sibling whose short name differs only in case, live or not; the loose steps
/// apply only when no short name matches exactly.
#[tokio::test]
async fn an_exact_short_name_beats_a_sibling_in_another_case() {
    let hub = test_hub();
    add_peer(&hub, "hb");
    list(&hub, "hb", "0199aaaa-1111", "coord/td2-A", "idle");
    list(&hub, "hb", "0199bbbb-2222", "coord/td2-a", "idle");
    let exact = hub.key_route("hb/td2-A").unwrap();
    assert_ne!(exact.as_deref(), Some("hb/0199bbbb-2222"));
    let lower = hub.key_route("hb/td2-a").unwrap();
    assert_ne!(lower.as_deref(), Some("hb/0199aaaa-1111"));
    // The exact child closed: still that child, not the live one in another case.
    let hub = test_hub();
    add_peer(&hub, "hb");
    list(&hub, "hb", "0199aaaa-1111", "coord/td2-A", "closed");
    list(&hub, "hb", "0199bbbb-2222", "coord/td2-a", "idle");
    assert_ne!(hub.key_route("hb/td2-A").unwrap().as_deref(), Some("hb/0199bbbb-2222"));
    // Only a loose match: it finds the one child.
    let hub = test_hub();
    add_peer(&hub, "hb");
    list(&hub, "hb", "0199aaaa-1111", "coord/td2-A", "idle");
    list(&hub, "hb", "0199cccc-3333", "coord/td3-B", "idle");
    assert_eq!(hub.key_route("hb/td2_a").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
}

/// Review of #36919: a bare key naming a sub-session's short name in another case reaches that
/// child ahead of a sibling it names only without separators, live or not.
#[tokio::test]
async fn a_bare_short_name_in_another_case_beats_one_without_separators() {
    for first in ["idle", "closed"] {
        let hub = test_hub();
        add_peer(&hub, "hb");
        list(&hub, "hb", "0199aaaa-1111", "coord/td2-A", first);
        list(&hub, "hb", "0199bbbb-2222", "coord/td2_a", "idle");
        let found = hub.key_route("TD2-A").unwrap();
        assert_eq!(found.as_deref(), Some("hb/0199aaaa-1111"), "first child {first}");
    }
}

/// Review of #36919: a key that is a session's whole name finds that session before `HOST/NAME`
/// is read as a peer and a name on it, as `by_key` reads it: a local `coord/lane` is never
/// mistaken for peer `coord`'s `lane-extra`.
#[tokio::test]
async fn resolve_takes_a_whole_name_before_a_peer_named_like_its_parent() {
    let hub = test_hub();
    let child = named(&hub, "coord/lane").await;
    add_peer(&hub, "coord");
    list(&hub, "coord", "0199dddd-4444", "lane-extra", "idle");
    let found = hub.locate("coord/lane", false, true).unwrap();
    assert_eq!(found["session"]["sessionId"], child.id.as_str(), "{found}");
}

/// Review of #36919: `HOST/ID`, a peer session's qualified id, names that session before a
/// session whose whole name is the same text.
#[tokio::test]
async fn resolve_takes_a_qualified_id_before_a_whole_name_like_it() {
    let hub = test_hub();
    let lookalike = named(&hub, "hb/0199eeee-5555").await;
    add_peer(&hub, "hb");
    list_as_peers_do(&hub, "hb", "0199eeee-5555", "worker");
    let found = hub.locate("hb/0199eeee-5555", false, true).unwrap();
    assert_ne!(found["session"]["sessionId"], lookalike.id.as_str(), "{found}");
    assert_eq!(found["session"]["qualifiedSessionId"], "hb/0199eeee-5555", "{found}");
    // A loose key `key_route` sends to that peer session is read back as its qualified id, never
    // as the local name like it.
    let found = hub.locate("WORKER", false, true).unwrap();
    assert_eq!(found["session"]["qualifiedSessionId"], "hb/0199eeee-5555", "{found}");
}

/// Peer `peer`'s session `id` named `name`, with the summary a peer's list gives it
/// (`Hub::remote_summary`: its `peer/` name, qualified id and receipt).
fn list_as_peers_do(hub: &Hub, peer: &str, id: &str, name: &str) {
    let summary =
        Hub::remote_summary(peer, json!({"sessionId": id, "name": name, "status": "idle"}));
    let receipt = crate::session_identity::SessionReceipt::new(peer, id, None, 1);
    let row = RemoteSession { peer: peer.into(), summary, receipt };
    hub.remote_sessions.write().insert(format!("{peer}/{id}"), row);
}
