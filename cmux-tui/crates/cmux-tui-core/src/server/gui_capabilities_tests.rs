//! The app's capability catalog (cmux-tui/spec/gui-capabilities.json, which the Mac build turns into
//! `enum DaemonCapability`) against what this daemon serves with nothing installed at startup: every
//! `required` entry is served, and no `unservedByBundledDaemon` entry is (it moves to `optional` once the
//! daemon half lands). The runtime-only capabilities (cloud transport, WebSocket listener, ...) stay with
//! scripts/cmux-next/check-daemon-capabilities.sh, which asks a running daemon.

use std::collections::BTreeSet;

const CATALOG: &str = include_str!("../../../../spec/gui-capabilities.json");

fn catalog() -> Vec<(String, String, String)> {
    let value: serde_json::Value =
        serde_json::from_str(CATALOG).expect("gui-capabilities.json is JSON");
    value["capabilities"]
        .as_array()
        .expect("a capabilities array")
        .iter()
        .map(|entry| {
            let field = |key: &str| {
                entry[key].as_str().unwrap_or_else(|| panic!("{key} in {entry}")).to_owned()
            };
            (field("case"), field("wire"), field("tier"))
        })
        .collect()
}

fn tier(name: &str) -> BTreeSet<String> {
    catalog().into_iter().filter(|(_, _, tier)| tier == name).map(|(_, wire, _)| wire).collect()
}

#[test]
fn every_entry_has_one_known_tier_and_a_unique_case_and_wire() {
    let entries = catalog();
    assert!(!entries.is_empty());
    let cases: BTreeSet<_> = entries.iter().map(|(case, _, _)| case.as_str()).collect();
    let wires: BTreeSet<_> = entries.iter().map(|(_, wire, _)| wire.as_str()).collect();
    assert_eq!(cases.len(), entries.len(), "a case is listed twice");
    assert_eq!(wires.len(), entries.len(), "a wire name is listed twice");
    for (case, _, tier) in &entries {
        assert!(
            ["required", "optional", "unservedByBundledDaemon"].contains(&tier.as_str()),
            "{case}: unknown tier {tier}"
        );
    }
}

#[test]
fn the_daemon_serves_every_required_capability_with_nothing_installed() {
    let served: BTreeSet<&str> = super::static_capabilities().into_iter().collect();
    let missing: Vec<_> =
        tier("required").into_iter().filter(|wire| !served.contains(wire.as_str())).collect();
    assert!(
        missing.is_empty(),
        "the app refuses a daemon without these, and this one lacks them: {missing:?}"
    );
}

#[test]
fn no_unserved_capability_is_served() {
    let served: BTreeSet<&str> = super::static_capabilities().into_iter().collect();
    let served_now: Vec<_> = tier("unservedByBundledDaemon")
        .into_iter()
        .filter(|wire| served.contains(wire.as_str()))
        .collect();
    assert!(
        served_now.is_empty(),
        "move these to optional in gui-capabilities.json: {served_now:?}"
    );
}
