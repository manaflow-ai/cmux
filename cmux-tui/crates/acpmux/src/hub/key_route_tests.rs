use super::*;
use crate::session_identity::SessionReceipt;

pub(super) fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Peer `peer`'s session `id`, listed as peers list them: under `peer/id`, named `peer/name`.
pub(super) fn list(hub: &Hub, peer: &str, id: &str, name: &str, status: &str) {
    list_with_alias(hub, peer, id, name, status, None);
}

pub(super) fn list_with_alias(
    hub: &Hub,
    peer: &str,
    id: &str,
    name: &str,
    status: &str,
    alias: Option<&str>,
) {
    let mut summary = json!({"sessionId": id, "name": format!("{peer}/{name}"), "status": status});
    if let Some(alias) = alias {
        summary["tags"] = json!({"session.alias": alias});
    }
    let row = RemoteSession {
        peer: peer.into(),
        summary: summary.into(),
        receipt: SessionReceipt {
            host_id: peer.into(),
            mux_session_id: id.into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.write().insert(format!("{peer}/{id}"), row);
}

pub(super) async fn named(hub: &Arc<Hub>, name: &str) -> Arc<Session> {
    let start = NewRequest {
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        ..NewRequest::default()
    };
    hub.new_session(start).await.unwrap()
}

#[tokio::test]
async fn a_bare_name_only_a_peer_has_routes_to_that_peer() {
    let hub = test_hub();
    list(&hub, "hb", "0199aaaa-1111", "acpmux-owner", "idle");
    list(&hub, "cmux16", "0199bbbb-2222", "builder", "idle");
    assert_eq!(hub.key_route("acpmux-owner").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
    assert_eq!(hub.key_route("nobody").unwrap(), None);
    // `HOST/NAME` names it too (`hb` is no configured peer here, only a host its rows name, so
    // the key is routed rather than left to the exact lookup a configured peer gets).
    assert_eq!(hub.key_route("hb/acpmux-owner").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
}

#[tokio::test]
async fn a_name_on_this_machine_and_a_peer_is_refused_never_picked() {
    let hub = test_hub();
    let here = named(&hub, "review").await;
    list(&hub, "hb", "0199aaaa-1111", "review", "running");
    let e = hub.key_route("review").unwrap_err();
    let data = e.data.clone().unwrap();
    assert_eq!(data["reason"], AMBIGUOUS, "{e:?}");
    let routes: Vec<&str> =
        data["choices"].as_array().unwrap().iter().filter_map(|c| c["route"].as_str()).collect();
    assert!(routes.contains(&here.id.as_str()) && routes.contains(&"hb/0199aaaa-1111"), "{e:?}");
    assert!(e.message.contains("hb/review"), "{}", e.message);
    // The session's own id still names it alone.
    assert_eq!(hub.key_route(&here.id).unwrap(), None);
}

#[tokio::test]
async fn an_id_prefix_names_a_peers_session_or_one_here() {
    let hub = test_hub();
    list(&hub, "hb", "0199aaaa-1111-7000", "builder", "idle");
    list(&hub, "hb", "0199cccc-3333-7000", "other", "idle");
    assert_eq!(hub.key_route("0199aaaa").unwrap().as_deref(), Some("hb/0199aaaa-1111-7000"));
    let here = named(&hub, "lane").await;
    assert_eq!(hub.key_route(&here.id[..12]).unwrap().as_deref(), Some(here.id.as_str()));
    // A prefix several sessions share is refused like a shared name.
    assert_eq!(hub.key_route("0199").unwrap_err().data.unwrap()["reason"], AMBIGUOUS);
    // A prefix of a peer's name is no route there.
    assert_eq!(hub.key_route("build").unwrap(), None);
    // A name here and another session's id prefix are one tier: a tie, not the name.
    named(&hub, "0199aaaa").await;
    let e = hub.key_route("0199aaaa").unwrap_err();
    assert_eq!(e.data.unwrap()["choices"].as_array().unwrap().len(), 2);
}

/// A sub-session's short name is the last tier, on every host: one is routed, two tie with
/// each `HOST/NAME`, and a whole name or a name here starting with the key wins.
#[tokio::test]
async fn a_short_name_routes_to_its_one_sub_session_on_any_host() {
    let hub = test_hub();
    list(&hub, "hb", "0199aaaa-1111", "coord/lane-3", "idle");
    assert_eq!(hub.key_route("lane-3").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
    let here = named(&hub, "boss/lane-3").await;
    let e = hub.key_route("lane-3").unwrap_err();
    let uses: Vec<String> = e.data.unwrap()["choices"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|c| c["use"].as_str().map(str::to_owned))
        .collect();
    assert!(uses.contains(&"hb/coord/lane-3".to_owned()), "{uses:?}");
    assert!(uses.iter().any(|u| u.ends_with("/boss/lane-3")), "{uses:?} {}", here.id);
    // `ci-3` is no segment of either name.
    assert_eq!(hub.key_route("ci-3").unwrap(), None);
    let whole = named(&hub, "lane-3x").await;
    assert_eq!(hub.key_route("lane-3").unwrap().as_deref(), Some(whole.id.as_str()));
}

/// Review of #28000: a sub-session's whole name has a `/`, and is routed like any name.
#[tokio::test]
async fn a_sub_sessions_whole_name_is_routed_across_hosts_too() {
    let hub = test_hub();
    list(&hub, "hb", "0199aaaa-1111", "coord/lane", "idle");
    assert_eq!(hub.key_route("coord/lane").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
    // A prefix of it names nothing.
    assert_eq!(hub.key_route("coord/la").unwrap(), None);
    named(&hub, "coord/lane").await;
    let e = hub.key_route("coord/lane").unwrap_err();
    assert_eq!(e.data.unwrap()["choices"].as_array().unwrap().len(), 2);
    // `local/ID` and this machine's own `HOST/NAME` stay exact.
    assert_eq!(hub.key_route("local/0199aaaa").unwrap(), None);
}

#[tokio::test]
async fn closed_sessions_do_not_count_while_a_live_one_matches() {
    let hub = test_hub();
    list(&hub, "hb", "0199aaaa-1111", "deploy", "closed");
    list(&hub, "cmux16", "0199bbbb-2222", "deploy", "idle");
    assert_eq!(hub.key_route("deploy").unwrap().as_deref(), Some("cmux16/0199bbbb-2222"));
    let old = named(&hub, "fixer").await;
    hub.set_status(&old, NotWaiting::Closed);
    list(&hub, "hb", "0199dddd-4444", "fixer", "idle");
    assert_eq!(hub.key_route("fixer").unwrap().as_deref(), Some("hb/0199dddd-4444"));
    // Only closed ones: still one to name, so `session info` reads a finished lane.
    list(&hub, "hb", "0199eeee-5555", "done", "closed");
    assert_eq!(hub.key_route("done").unwrap().as_deref(), Some("hb/0199eeee-5555"));
}

/// 2026-11-21: `send HOST/claude` reached an unrelated session whose name
/// starts with `claude`. A harness's name no session has as its name or id is refused, on a
/// peer and here, with each session it might mean (name and id); a session that has it as
/// its whole name, and an id, still name it.
#[tokio::test]
async fn a_harness_name_is_refused_with_the_sessions_it_might_mean() {
    let hub = test_hub();
    let row = |id: &str, name: &str, harness: &str| RemoteSession {
        peer: "lane12".into(),
        summary: json!({"sessionId": id, "name": format!("lane12/{name}"), "status": "idle",
                        "harness": harness})
        .into(),
        receipt: SessionReceipt {
            host_id: "lane12".into(),
            mux_session_id: id.into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions
        .write()
        .insert("lane12/0199aaaa-1111".into(), row("0199aaaa-1111", "claude-sr2", "claude"));
    hub.remote_sessions
        .write()
        .insert("lane12/0199bbbb-2222".into(), row("0199bbbb-2222", "builder", "codex"));
    let e = hub.key_route("lane12/claude").unwrap_err();
    let data = e.data.clone().unwrap();
    assert_eq!(data["reason"], AMBIGUOUS, "{e:?}");
    assert_eq!(data["choices"][0]["route"], "lane12/0199aaaa-1111", "{e:?}");
    assert!(e.message.contains("lane12/claude-sr2 (lane12/0199aaaa-1111)"), "{}", e.message);
    assert!(e.message.contains("pass a session name or id"), "{}", e.message);
    // Bare, the same.
    assert_eq!(hub.key_route("claude").unwrap_err().data.unwrap()["reason"], AMBIGUOUS);
    // A harness only one session runs, its name sharing nothing with it: still no guess.
    let e = hub.key_route("lane12/codex").unwrap_err();
    assert!(e.message.contains("lane12/builder (lane12/0199bbbb-2222)"), "{}", e.message);
    // Here: `fake` is the test hub's harness, and `fake-1` starts with it.
    let here = named(&hub, "fake-1").await;
    let e = hub.key_route("fake").unwrap_err();
    assert!(e.message.contains(&format!("/fake-1 ({})", here.id)), "{}", e.message);
    // An exact name and an id still name their session; a name that is no harness is as before.
    let exact = named(&hub, "fake").await;
    assert_eq!(hub.key_route("fake").unwrap().as_deref(), Some(exact.id.as_str()));
    assert_eq!(
        hub.key_route("lane12/claude-sr2").unwrap().as_deref(),
        Some("lane12/0199aaaa-1111")
    );
    assert_eq!(hub.key_route("0199aaaa").unwrap().as_deref(), Some("lane12/0199aaaa-1111"));
    assert_eq!(hub.key_route("build").unwrap(), None);
}

fn c(host: &str, name: &str, route: &str, closed: bool) -> Candidate {
    Candidate { host: host.into(), name: name.into(), route: route.into(), closed }
}

#[test]
fn one_live_session_wins_over_closed_ones() {
    let found = [c("hb", "review", "hb/m3", false), c("mac-a", "review", "m1", true)];
    assert_eq!(pick("review", &found).unwrap().unwrap().route, "hb/m3");
    let closed = [c("mac-a", "review", "m1", true)];
    assert_eq!(pick("review", &closed).unwrap().unwrap().route, "m1");
    assert_eq!(pick("review", &[]).unwrap(), None);
}

#[test]
fn several_live_sessions_are_refused_with_each_host_and_name() {
    let found = [
        c("mac-a", "review", "m1", false),
        c("hb", "review", "hb/m3", false),
        c("hb", "review", "hb/m4", false),
        c("cmux16", "review", "cmux16/m5", true),
    ];
    let e = pick("review", &found).unwrap_err();
    assert_eq!(
        e.message,
        "\"review\" names 3 live sessions: mac-a/review, hb/m3, hb/m4; name one of them"
    );
    let data = e.data.unwrap();
    assert_eq!(data["reason"], AMBIGUOUS);
    assert_eq!(data["session"], "review");
    let uses: Vec<&str> =
        data["choices"].as_array().unwrap().iter().filter_map(|c| c["use"].as_str()).collect();
    assert_eq!(uses, ["mac-a/review", "hb/m3", "hb/m4"]);
    // The message names ten; the data lists every one.
    let many: Vec<Candidate> =
        (0..12).map(|i| c(&format!("h{i}"), "review", &format!("h{i}/m"), false)).collect();
    let e = pick("review", &many).unwrap_err();
    assert!(e.message.contains("h9/review, and 2 more"), "{}", e.message);
    assert_eq!(e.data.unwrap()["choices"].as_array().unwrap().len(), 12);
}
