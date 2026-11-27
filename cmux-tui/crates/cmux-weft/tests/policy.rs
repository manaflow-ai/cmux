//! ACL policy: parsing, validation and compilation into per-node filters.

use cmux_weft::policy::{NodeIdentity, Policy, PortRange};

fn node(id: &str, user: Option<&str>, tags: &[&str]) -> NodeIdentity {
    NodeIdentity {
        id: id.to_owned(),
        user: user.map(str::to_owned),
        tags: tags.iter().map(|tag| (*tag).to_owned()).collect(),
    }
}

const POLICY: &str = r#"{
  "groups": { "group:eng": ["user:lawrence", "user:austin"] },
  "tagOwners": { "tag:fleet": ["group:eng"], "tag:vm": ["user:lawrence"] },
  "acls": [
    { "action": "accept", "src": ["group:eng"], "dst": ["tag:fleet:22,7319", "tag:vm:*"] },
    { "action": "accept", "src": ["tag:vm"], "dst": ["tag:fleet:7319"] }
  ]
}"#;

fn nodes() -> Vec<NodeIdentity> {
    vec![
        node("laptop", Some("lawrence"), &[]),
        node("austin-mac", Some("austin"), &[]),
        node("guest", Some("mallory"), &[]),
        node("mini", None, &["tag:fleet"]),
        node("vm", None, &["tag:vm"]),
    ]
}

#[test]
fn inbound_filter_lists_each_allowed_source_with_its_ports() {
    let policy = Policy::parse(POLICY).unwrap();
    let all = nodes();
    let mini = &all[3];
    let inbound = policy.inbound_for(mini, &all);
    assert_eq!(
        inbound.get("laptop").unwrap(),
        &vec![PortRange { first: 22, last: 22 }, PortRange { first: 7319, last: 7319 }]
    );
    assert!(inbound.contains_key("austin-mac"));
    assert_eq!(inbound.get("vm").unwrap(), &vec![PortRange { first: 7319, last: 7319 }]);
    assert!(!inbound.contains_key("guest"), "a user outside the group gets nothing");
    assert!(!inbound.contains_key("mini"), "no rule lets the mini reach itself");
}

#[test]
fn wildcard_ports_cover_every_port() {
    let policy = Policy::parse(POLICY).unwrap();
    let all = nodes();
    let inbound = policy.inbound_for(&all[4], &all);
    assert_eq!(inbound.get("laptop").unwrap(), &vec![PortRange { first: 1, last: 65535 }]);
    assert!(!inbound.contains_key("mini"));
}

#[test]
fn peers_are_both_directions_and_nothing_else() {
    let policy = Policy::parse(POLICY).unwrap();
    let all = nodes();
    let laptop_peers = policy.peers_of(&all[0], &all);
    assert_eq!(laptop_peers.into_iter().collect::<Vec<_>>(), vec!["mini", "vm"]);
    let vm_peers = policy.peers_of(&all[4], &all);
    assert_eq!(vm_peers.into_iter().collect::<Vec<_>>(), vec!["austin-mac", "laptop", "mini"]);
    assert!(policy.peers_of(&all[2], &all).is_empty(), "guest sees nobody");
}

#[test]
fn a_tagged_node_is_owned_by_its_tags_not_a_user() {
    // A tagged node that also carries a user id must not match `user:` or `group:`.
    let policy = Policy::parse(POLICY).unwrap();
    let mut all = nodes();
    all.push(node("tagged-laptop", Some("lawrence"), &["tag:vm"]));
    let mini = all[3].clone();
    let inbound = policy.inbound_for(&mini, &all);
    assert_eq!(inbound.get("tagged-laptop").unwrap(), &vec![PortRange { first: 7319, last: 7319 }]);
}

#[test]
fn empty_policy_denies_everything() {
    let policy = Policy::parse("{}").unwrap();
    let all = nodes();
    for target in &all {
        assert!(policy.inbound_for(target, &all).is_empty());
        assert!(policy.peers_of(target, &all).is_empty());
    }
}

#[test]
fn tag_owners_follow_groups() {
    let policy = Policy::parse(POLICY).unwrap();
    assert!(policy.may_own_tag("austin", "tag:fleet"));
    assert!(!policy.may_own_tag("austin", "tag:vm"));
    assert!(policy.may_own_tag("lawrence", "tag:vm"));
    assert!(!policy.may_own_tag("mallory", "tag:fleet"));
    assert!(!policy.may_own_tag("lawrence", "tag:unknown"));
}

#[test]
fn invalid_policies_are_rejected_with_a_reason() {
    let cases = [
        (r#"{"acls":[{"action":"deny","src":["*"],"dst":["*:*"]}]}"#, "action"),
        (r#"{"acls":[{"action":"accept","src":["group:nope"],"dst":["*:*"]}]}"#, "group:nope"),
        (r#"{"acls":[{"action":"accept","src":["*"],"dst":["tag:nope:22"]}]}"#, "tag:nope"),
        (r#"{"acls":[{"action":"accept","src":["*"],"dst":["*"]}]}"#, "port"),
        (r#"{"acls":[{"action":"accept","src":["*"],"dst":["*:0"]}]}"#, "port"),
        (r#"{"acls":[{"action":"accept","src":["*"],"dst":["*:90-80"]}]}"#, "port"),
        (r#"{"acls":[{"action":"accept","src":["*"],"dst":["*:70000"]}]}"#, "port"),
        (r#"{"acls":[{"action":"accept","src":["bogus"],"dst":["*:*"]}]}"#, "bogus"),
        (r#"{"groups":{"group:a":["group:a"]}}"#, "group:a"),
        (r#"{"unknown":1}"#, "unknown"),
    ];
    for (text, needle) in cases {
        let error = Policy::parse(text).expect_err(text).to_string();
        assert!(error.contains(needle), "{text}: {error} should mention {needle}");
    }
}

#[test]
fn port_ranges_merge_and_contain() {
    let policy = Policy::parse(
        r#"{"acls":[
            {"action":"accept","src":["*"],"dst":["*:10-20,15-30"]},
            {"action":"accept","src":["*"],"dst":["*:31,100"]}
        ]}"#,
    )
    .unwrap();
    let all = vec![node("a", Some("u"), &[]), node("b", Some("v"), &[])];
    let inbound = policy.inbound_for(&all[1], &all);
    let ranges = inbound.get("a").unwrap();
    assert_eq!(
        ranges,
        &vec![PortRange { first: 10, last: 31 }, PortRange { first: 100, last: 100 }]
    );
    assert!(PortRange::any_contains(ranges, 31));
    assert!(!PortRange::any_contains(ranges, 32));
}
