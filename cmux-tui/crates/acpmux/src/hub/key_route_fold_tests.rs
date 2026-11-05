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
