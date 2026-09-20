use cmux_v3_authority::*;
use cmux_v3_grants::{LeasePolicy, OfflineAccess};
use libp2p_identity::{Keypair, PeerId};

fn peer() -> PeerId {
    Keypair::generate_ed25519().public().to_peer_id()
}
fn device(peer: PeerId, owner: &str, tags: &[&str], lease: LeasePolicy) -> Device {
    Device {
        peer,
        owner: owner.into(),
        tags: tags.iter().map(|s| (*s).into()).collect(),
        active: true,
        lease,
    }
}
fn team(devices: Vec<Device>, policy: &str) -> TeamPolicy {
    TeamPolicy::new("team-a".into(), 3, 1000, 1100, devices, policy).unwrap()
}

#[test]
fn team_default_allows_both_directions_but_not_unknown_devices() {
    let a = peer();
    let b = peer();
    let t = team(
        vec![
            device(a, "alice", &[], LeasePolicy::default()),
            device(b, "bob", &[], LeasePolicy::default()),
        ],
        DEFAULT_POLICY,
    );
    assert!(t.authorize(a, b, "connect", 1001).is_ok());
    assert!(t.authorize(b, a, "connect", 1001).is_ok());
    assert!(t.authorize(peer(), b, "connect", 1001).is_err());
    assert!(t.authorize(a, peer(), "connect", 1001).is_err());
    assert!(t.authorize(a, b, "undefined_action", 1001).is_err());
}

#[test]
fn directional_acl_and_actions_are_enforced_using_server_tags() {
    let a = peer();
    let b = peer();
    let policy = r#"permit(principal, action == Action::"terminal_read", resource)
        when { principal.tags.contains("support") && resource.tags.contains("dev") };"#;
    let t = team(
        vec![
            device(a, "alice", &["support"], LeasePolicy::default()),
            device(b, "bob", &["dev"], LeasePolicy::default()),
        ],
        policy,
    );
    assert!(t.authorize(a, b, "terminal_read", 1001).is_ok());
    assert!(t.authorize(b, a, "terminal_read", 1001).is_err());
    assert!(t.authorize(a, b, "terminal_write", 1001).is_err());
}

#[test]
fn unlimited_requires_an_explicit_additional_permission_for_the_selected_user() {
    let a = peer();
    let b = peer();
    let infinite = LeasePolicy {
        offline: OfflineAccess::UntilRevoked {},
        renew_every_seconds: 30,
    };
    let make = || {
        vec![
            device(a, "alice", &[], infinite),
            device(b, "bob", &[], LeasePolicy::default()),
        ]
    };
    assert!(team(make(), DEFAULT_POLICY)
        .authorize(a, b, "connect", 1001)
        .is_err());
    let policy = format!(
        r#"{DEFAULT_POLICY}
        permit(principal, action == Action::"offline_unlimited", resource) when {{ principal.owner == "alice" }};"#
    );
    let t = team(make(), &policy);
    assert_eq!(t.authorize(a, b, "connect", 1001).unwrap().exp, None);
    assert_eq!(t.authorize(b, a, "connect", 1001).unwrap().exp, Some(1300));
    assert!(t.authorize(a, b, "offline_unlimited", 1001).is_err());
    assert!(t.authorize(a, b, "connect", 1100).is_err());
}

#[test]
fn disabling_device_and_forbid_override_broad_allow() {
    let a = peer();
    let b = peer();
    let make = || {
        vec![
            device(a, "alice", &[], LeasePolicy::default()),
            device(b, "bob", &[], LeasePolicy::default()),
        ]
    };
    let policy = format!(
        r#"{DEFAULT_POLICY} forbid(principal, action, resource) when {{ principal.owner == "alice" }};"#
    );
    assert!(team(make(), &policy)
        .authorize(a, b, "connect", 1001)
        .is_err());
    let mut devices = make();
    devices[1].active = false;
    assert!(team(devices, DEFAULT_POLICY)
        .authorize(a, b, "connect", 1001)
        .is_err());
}

#[test]
fn malformed_policy_and_duplicate_device_fail_loading() {
    let a = peer();
    assert!(TeamPolicy::new("team".into(), 1, 1000, 1100, vec![], "permit whatever").is_err());
    assert!(TeamPolicy::new(
        "team".into(),
        1,
        1000,
        1100,
        vec![],
        r#"permit(principal, action, resource) when { principal.typo == "x" };"#
    )
    .is_err());
    assert!(TeamPolicy::new(
        "team".into(),
        1,
        1000,
        1100,
        vec![
            device(a, "alice", &[], LeasePolicy::default()),
            device(a, "alice", &[], LeasePolicy::default())
        ],
        DEFAULT_POLICY
    )
    .is_err());
}
