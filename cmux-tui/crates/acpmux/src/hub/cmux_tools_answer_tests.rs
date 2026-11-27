use super::*;
use crate::server::ConnAuth;

#[test]
fn a_forwarded_chat_of_a_switched_off_agent_carries_off() {
    let settings = Some(r#"{"agents": {"cmuxMcp": "on", "cmuxMcpCodex": false}}"#);
    let codex = json!({"_meta": {"acpmux": {"harness": "codex-acp"}}});
    assert_eq!(here_for(settings, &codex), "off");
    assert_eq!(here_for(settings, &json!({"harness": "claude"})), "on");
    assert_eq!(here_for(settings, &json!({})), "on", "no harness: the answer");
    assert_eq!(here_for(Some("{}"), &codex), "on", "on by default");
    assert_eq!(
        here_for(Some(r#"{"agents": {"cmuxMcp": "off"}}"#), &json!({"harness": "claude"})),
        "off"
    );
}

#[test]
fn only_a_peer_daemon_brings_an_answer() {
    let p = json!({"_meta": {"acpmux": {"cmuxTools": "on"}}});
    assert_eq!(asked(ConnAuth::PeerToken, &p), Some("on"));
    assert_eq!(asked(ConnAuth::CarrierOwner, &p), Some("on"));
    for auth in [
        ConnAuth::None,
        ConnAuth::LocalSocket,
        ConnAuth::LocalApp,
        ConnAuth::ListenerToken,
        ConnAuth::Device,
        ConnAuth::ReadOnlyDevice,
        ConnAuth::CarrierTeam,
    ] {
        assert_eq!(asked(auth, &p), None, "{auth:?}");
    }
    // A peer daemon or the Cloud carrier forwarding for its Web client.
    let for_web = json!({"_meta": {"acpmux": {"cmuxTools": "on", "via": "web"}}});
    assert_eq!(asked(ConnAuth::CarrierOwner, &for_web), None);
    assert_eq!(asked(ConnAuth::PeerToken, &for_web), None);
    let for_app = json!({"_meta": {"acpmux": {"cmuxTools": "on", "via": "app"}}});
    assert_eq!(asked(ConnAuth::CarrierOwner, &for_app), Some("on"));
    let other = json!({"_meta": {"acpmux": {"cmuxTools": "yes"}}});
    assert_eq!(asked(ConnAuth::PeerToken, &other), None);
    assert_eq!(asked(ConnAuth::PeerToken, &json!({})), None);
}

#[test]
fn a_forwarded_new_carries_this_daemons_answer_over_the_callers() {
    assert_eq!(here(Some(r#"{"agents": {"cmuxMcp": "on"}}"#)), "on");
    assert_eq!(here(Some(r#"{"agents": {"cmuxMcp": "ask"}}"#)), "on");
    assert_eq!(here(Some(r#"{"agents": {"cmuxMcp": "off"}}"#)), "off");
    assert_eq!(here(None), "on");
    let mut p = json!({"_meta": {"acpmux": {"cmuxTools": "on", "harness": "codex"}}});
    stamp(&mut p, "off");
    assert_eq!(p["_meta"]["acpmux"]["cmuxTools"], "off");
    assert_eq!(p["_meta"]["acpmux"]["harness"], "codex");
}

#[test]
fn a_fork_keeps_its_parents_answer_unless_it_sets_one() {
    let parent = BTreeMap::from([(TOOLS_ANSWER_ENV.to_owned(), "off".to_owned())]);
    let kept = inherited(BTreeMap::new(), &parent);
    assert_eq!(kept.get(TOOLS_ANSWER_ENV).map(String::as_str), Some("off"));
    let own = BTreeMap::from([(TOOLS_ANSWER_ENV.to_owned(), "on".to_owned())]);
    assert_eq!(inherited(own, &parent).get(TOOLS_ANSWER_ENV).map(String::as_str), Some("on"));
    assert!(inherited(BTreeMap::new(), &BTreeMap::new()).is_empty());
}
