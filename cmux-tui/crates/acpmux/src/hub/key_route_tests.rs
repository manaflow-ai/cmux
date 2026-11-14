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
    let row = RemoteSession {
        peer: peer.into(),
        summary: json!({"sessionId": id, "name": format!("{peer}/{name}"), "status": status})
            .into(),
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
    hub.set_status(&old, SessionStatus::Closed);
    list(&hub, "hb", "0199dddd-4444", "fixer", "idle");
    assert_eq!(hub.key_route("fixer").unwrap().as_deref(), Some("hb/0199dddd-4444"));
    // Only closed ones: still one to name, so `session info` reads a finished lane.
    list(&hub, "hb", "0199eeee-5555", "done", "closed");
    assert_eq!(hub.key_route("done").unwrap().as_deref(), Some("hb/0199eeee-5555"));
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
