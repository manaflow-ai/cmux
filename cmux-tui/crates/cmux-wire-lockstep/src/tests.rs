use super::*;

fn base() -> Manifest {
    let mut m = Manifest::new("demo", "initialize _meta.caps");
    m.legacy.insert("method:initialize".into());
    m.legacy.insert("method:status".into());
    m.capabilities.insert("usage-v1".into(), ["method:usage".to_owned()].into());
    m.versions.insert("frame".into(), 5);
    m
}

fn rules(findings: &[Finding]) -> Vec<(Rule, String)> {
    findings.iter().map(|f| (f.rule, f.subject.clone())).collect()
}

#[test]
fn no_base_yet_is_a_pass() {
    assert!(check(None, &base()).is_empty());
}

#[test]
fn same_revision_is_a_pass() {
    assert!(check(Some(&base()), &base()).is_empty());
}

#[test]
fn a_new_name_under_a_new_capability_passes() {
    let mut head = base();
    head.capabilities.insert("down-reason-v1".into(), ["field:peer#downReason".to_owned()].into());
    assert!(check(Some(&base()), &head).is_empty());
}

#[test]
fn a_new_name_with_no_capability_is_one_sided() {
    let mut head = base();
    head.legacy.insert("method:relay_first".into());
    let found = rules(&check(Some(&base()), &head));
    assert!(found.contains(&(Rule::UngatedName, "method:relay_first".into())), "{found:?}");
    assert!(found.contains(&(Rule::LegacyGrew, "method:relay_first".into())), "{found:?}");
}

#[test]
fn a_new_name_under_an_old_capability_changes_its_contract() {
    let mut head = base();
    head.capabilities.get_mut("usage-v1").unwrap().insert("param:usage#since".into());
    let found = rules(&check(Some(&base()), &head));
    assert!(found.contains(&(Rule::UngatedName, "param:usage#since".into())), "{found:?}");
    assert!(found.contains(&(Rule::ContractChanged, "usage-v1".into())), "{found:?}");
}

#[test]
fn a_dropped_capability_or_legacy_name_needs_retiring() {
    let mut head = base();
    head.capabilities.clear();
    head.legacy.remove("method:status");
    let found = rules(&check(Some(&base()), &head));
    assert!(found.contains(&(Rule::CapabilityDropped, "usage-v1".into())), "{found:?}");
    assert!(found.contains(&(Rule::LegacyDropped, "method:status".into())), "{found:?}");
    head.retired.insert("usage-v1".into(), "2026-11-24 replaced by usage-v2".into());
    head.retired.insert("method:status".into(), "2026-11-24 answered by status-v2".into());
    assert!(check(Some(&base()), &head).is_empty());
}

#[test]
fn moving_a_legacy_name_under_a_capability_is_not_a_drop() {
    let mut head = base();
    head.legacy.remove("method:status");
    head.capabilities.insert("status-v1".into(), ["method:status".to_owned()].into());
    assert!(check(Some(&base()), &head).is_empty());
}

#[test]
fn a_version_bump_must_still_decode_the_old_one() {
    let mut head = base();
    head.versions.insert("frame".into(), 6);
    let found = rules(&check(Some(&base()), &head));
    assert_eq!(found, vec![(Rule::VersionBroken, "frame".into())]);
    head.accepts.insert("frame".into(), [5, 6].into());
    assert!(check(Some(&base()), &head).is_empty());
}

#[test]
fn malformed_names_are_reported() {
    let mut head = base();
    head.legacy.insert("initialize".into());
    head.capabilities.insert("empty-v1".into(), BTreeSet::new());
    let found = rules(&check(None, &head));
    assert_eq!(found.len(), 2, "{found:?}");
    assert!(found.iter().all(|(rule, _)| *rule == Rule::Malformed));
}

#[test]
fn json_round_trips_byte_for_byte() {
    let text = base().to_json();
    assert_eq!(Manifest::from_json(&text).unwrap().to_json(), text);
    assert!(text.ends_with("}\n"));
    assert!(Manifest::from_json(&text.replace("\"format\": 1", "\"format\": 2")).is_err());
}

#[test]
fn the_tap_finds_one_sided_messages() {
    let mut head = base();
    head.capabilities.insert("down-reason-v1".into(), ["notify:peer_down".to_owned()].into());
    let old = OldPeer::new(base());
    assert!(old.lists("usage-v1") && !old.lists("down-reason-v1"));

    let tap = Tap::new();
    tap.record(Dir::Sent, "method:initialize");
    tap.record(Dir::Received, "method:usage");
    tap.assert_lockstep(&head, &old);

    tap.record(Dir::Sent, "notify:peer_down");
    tap.record(Dir::Received, "method:undeclared");
    tap.refused(Dir::Sent, "method:usage");
    let problems = tap.one_sided(&head, &old);
    assert_eq!(problems.len(), 3, "{problems:#?}");
    assert!(
        problems.iter().any(|p| p.contains("notify:peer_down") && p.contains("down-reason-v1"))
    );
    assert!(problems.iter().any(|p| p.contains("method:undeclared") && p.contains("not in")));
    assert!(problems.iter().any(|p| p.contains("refused")));
}

#[test]
fn two_kinds_sharing_a_number_are_malformed() {
    let mut head = base();
    head.legacy.insert("frame:open=0".into());
    head.capabilities.insert("relay-v1".into(), ["frame:link-relay=4".to_owned()].into());
    head.capabilities.insert("sequenced-v1".into(), ["frame:sequenced=4".to_owned()].into());
    // Another space may reuse a number: lanes count apart from frame types.
    head.legacy.insert("frame:lane/bulk=4".into());
    let found = check(None, &head);
    assert_eq!(found.len(), 1, "{found:#?}");
    assert_eq!(found[0].rule, Rule::Malformed);
    assert!(
        found[0].detail.contains("frame 4") && found[0].detail.contains("link-relay and sequenced")
    );
}

#[test]
fn a_number_keeps_its_meaning() {
    let mut old = base();
    old.legacy.insert("frame:ping=3".into());
    let mut head = old.clone();
    head.legacy.remove("frame:ping=3");
    head.legacy.insert("frame:ping=6".into());
    head.retired.insert("frame:ping=3".into(), "moved".into());
    let found = rules(&check(Some(&old), &head));
    assert!(found.contains(&(Rule::CodeChanged, "frame ping".into())), "{found:?}");

    let mut head = old.clone();
    head.legacy.remove("frame:ping=3");
    head.retired.insert("frame:ping=3".into(), "gone".into());
    head.capabilities.insert("relay-v1".into(), ["frame:relay=3".to_owned()].into());
    let found = rules(&check(Some(&old), &head));
    assert!(found.contains(&(Rule::CodeChanged, "frame 3".into())), "{found:?}");
}

#[test]
fn two_open_changes_claiming_one_number_collide() {
    let mut old = base();
    old.legacy.insert("frame:open=0".into());
    let mut a = old.clone();
    a.capabilities.insert("link-relay-v1".into(), ["frame:link-relay=4".to_owned()].into());
    let mut b = old.clone();
    b.capabilities.insert("link-relay-v1".into(), ["frame:relay-data=4".to_owned()].into());
    assert!(check(Some(&old), &a).is_empty() && check(Some(&old), &b).is_empty());
    let found = collisions(Some(&old), &a, &b, "origin/lane/b");
    assert_eq!(rules(&found), vec![(Rule::CodeCollision, "frame 4".into())]);
    assert!(found[0].detail.contains("link-relay") && found[0].detail.contains("relay-data"));
    // The same claim in both (one rebased on the other's numbering) is no collision.
    assert!(collisions(Some(&old), &a, &a.clone(), "x").is_empty());
}
