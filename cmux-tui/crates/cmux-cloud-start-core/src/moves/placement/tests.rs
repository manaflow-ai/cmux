//! Where a person's New Workspace runs: pins, the toggle, the machine cap.

use super::*;
use serde_json::json;

fn person(cwd: &str) -> Facts {
    Facts { cwd: Some(cwd.into()), ..anywhere() }
}

/// A person's gesture, signed in, in a window, with Cloud available.
fn anywhere() -> Facts {
    Facts { by_person: true, signed_in: true, has_window: true, ..Facts::default() }
}

#[test]
fn the_options_read_from_cmux_json_and_skip_what_they_cannot_read() {
    let options = Options::from_settings(&json!({
        "newWorkspacesInCloud": true,
        "workspacePins": {
            "/w/app/": "thisMac",
            "/w/app/infra": "cloud",
            "/w/big": "machine: m_123 ",
            "relative/x": "cloud",
            "/w/odd": "somewhere",
            "/w/empty": "machine:",
            "/w/num": 3,
        },
        "autoMachineCap": 2,
    }));
    assert!(options.in_cloud);
    assert_eq!(options.machine_cap, Some(2));
    let mut pins = options.pins.clone();
    pins.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        pins,
        [
            ("/w/app".to_owned(), Pin::ThisMac),
            ("/w/app/infra".to_owned(), Pin::Cloud),
            ("/w/big".to_owned(), Pin::Machine("m_123".into())),
        ]
    );
    // Missing, zero or malformed values are their defaults: toggle off, no pins, the plan's cap.
    for cloud in [
        json!({}),
        json!(null),
        json!({"newWorkspacesInCloud": "yes", "workspacePins": [], "autoMachineCap": 0}),
        json!({"autoMachineCap": -1}),
    ] {
        assert_eq!(Options::from_settings(&cloud), Options::default(), "{cloud}");
    }
}

#[test]
fn the_deepest_pinned_folder_decides_and_a_sibling_name_never_matches() {
    let options = Options::from_settings(&json!({"workspacePins": {
        "/w/app": "thisMac", "/w/app/infra": "cloud", "/": "machine:m_root"}}));
    assert_eq!(options.pin_for("/w/app/infra/tf").map(|p| p.0), Some("/w/app/infra"));
    assert_eq!(options.pin_for("/w/app/src/../infra").map(|p| p.0), Some("/w/app/infra"));
    assert_eq!(options.pin_for("/w/app").map(|p| p.0), Some("/w/app"));
    // `/w/application` is not inside `/w/app`: only the root pin holds it.
    assert_eq!(options.pin_for("/w/application").map(|p| p.0), Some("/"));
    assert_eq!(options.pin_for("relative"), None);
}

#[test]
fn the_toggle_decides_a_folder_no_pin_names() {
    let off = Options::default();
    let on = Options { in_cloud: true, ..Options::default() };
    assert_eq!(decide(&off, &person("/w/app")).target, Target::ThisMac);
    assert_eq!(decide(&on, &person("/w/app")).target, Target::NewCloudMachine);
    // No folder known: still the toggle.
    let no_cwd = anywhere();
    assert_eq!(decide(&on, &no_cwd).target, Target::NewCloudMachine);
    assert_eq!(decide(&on, &person("/w/app")).why, "Run New Workspaces in Cloud is on");
}

#[test]
fn a_pin_wins_over_the_toggle_both_ways() {
    let pins = json!({"/w/app": "thisMac", "/w/infra": "cloud", "/w/big": "machine:m_9"});
    let on = Options::from_settings(&json!({"newWorkspacesInCloud": true, "workspacePins": pins}));
    let off = Options::from_settings(&json!({"workspacePins": pins}));
    for options in [&on, &off] {
        assert_eq!(decide(options, &person("/w/app/src")).target, Target::ThisMac);
        assert_eq!(decide(options, &person("/w/infra")).target, Target::NewCloudMachine);
        let big = decide(options, &person("/w/big/x"));
        assert_eq!(big.target, Target::Machine("m_9".into()));
        assert_eq!(big.why, "/w/big is pinned to m_9");
    }
}

#[test]
fn a_run_that_is_not_the_persons_or_names_its_place_stays_where_it_asked() {
    let options = Options::from_settings(
        &json!({"newWorkspacesInCloud": true, "workspacePins": {"/w": "machine:m_1"}}),
    );
    let script = Facts { by_person: false, ..person("/w/app") };
    let named = Facts { names_machine_or_command: true, ..person("/w/app") };
    for facts in [script, named] {
        let placement = decide(&options, &facts);
        assert_eq!(placement.target, Target::ThisMac);
        assert_eq!(placement.refusal, None);
    }
}

#[test]
fn at_the_cap_a_new_machine_is_not_made_and_the_person_is_told() {
    let options = Options::from_settings(&json!({
        "newWorkspacesInCloud": true, "autoMachineCap": 2, "workspacePins": {"/w/big": "machine:m_9"}}));
    let under = Facts { running_machines: 1, ..person("/w/app") };
    assert_eq!(decide(&options, &under).target, Target::NewCloudMachine);
    for running in [2, 5] {
        let at = Facts { running_machines: running, ..person("/w/app") };
        let placement = decide(&options, &at);
        assert_eq!(placement.target, Target::ThisMac);
        assert_eq!(placement.refusal, Some(Refusal::MachineCap { running, cap: 2 }));
    }
    // A pin to a machine that already runs makes nothing new: the cap does not hold it back.
    let pinned = Facts { running_machines: 5, ..person("/w/big") };
    assert_eq!(decide(&options, &pinned).target, Target::Machine("m_9".into()));
    // No cap of the person's: the plan's own limit is the server's to apply.
    let uncapped = Options { machine_cap: None, ..options };
    let many = Facts { running_machines: 50, ..person("/w/app") };
    assert_eq!(decide(&uncapped, &many).target, Target::NewCloudMachine);
}

#[test]
fn the_answer_the_app_reads() {
    let options =
        Options::from_settings(&json!({"newWorkspacesInCloud": true, "autoMachineCap": 1}));
    let at = Facts { running_machines: 1, ..person("/w/app") };
    assert_eq!(
        serde_json::to_value(decide(&options, &at)).unwrap(),
        json!({"target": {"kind": "thisMac"},
            "why": "Run New Workspaces in Cloud is on, but MachineCap { running: 1, cap: 1 }",
            "refusal": {"kind": "machineCap", "running": 1, "cap": 1}})
    );
    let pinned = Options::from_settings(&json!({"workspacePins": {"/w": "machine:m_1"}}));
    assert_eq!(
        serde_json::to_value(decide(&pinned, &person("/w"))).unwrap(),
        json!({"target": {"kind": "machine", "id": "m_1"}, "why": "/w is pinned to m_1"})
    );
    assert_eq!(
        serde_json::to_value(decide(&Options::default(), &person("/w"))).unwrap(),
        json!({"target": {"kind": "thisMac"}, "why": "Run New Workspaces in Cloud is off"})
    );
}

/// Cloud's own refusals keep a workspace the options sent there on this Mac, as before the
/// options: unavailable, signed out, or no window to show the machine's progress. A pin to
/// this Mac or a machine never asks Cloud, so none of them holds it.
#[test]
fn where_cloud_cannot_make_the_machine_the_workspace_opens_here_and_says_why() {
    let options = Options::from_settings(&json!({"newWorkspacesInCloud": true,
        "workspacePins": {"/w/big": "machine:m_9", "/w/here": "thisMac"}}));
    let cases = [
        (
            Facts {
                unavailable_reason: Some("Cloud is off for this team.".into()),
                ..person("/w")
            },
            Refusal::Unavailable { reason: "Cloud is off for this team.".into() },
        ),
        (Facts { signed_in: false, ..person("/w") }, Refusal::SignedOut),
        (Facts { has_window: false, ..person("/w") }, Refusal::NoWindow),
    ];
    for (facts, refusal) in cases {
        let placement = decide(&options, &facts);
        assert_eq!(placement.target, Target::ThisMac);
        assert_eq!(placement.refusal, Some(refusal));
        // Cloud's refusal comes first: the cap is not reached, and is not what the person is told.
        let capped = Options { machine_cap: Some(1), ..options.clone() };
        let at_cap = Facts { running_machines: 3, ..facts.clone() };
        assert_ne!(
            decide(&capped, &at_cap).refusal,
            Some(Refusal::MachineCap { running: 3, cap: 1 })
        );
        for pinned in ["/w/big", "/w/here"] {
            let pinned = Facts { cwd: Some(pinned.into()), ..facts.clone() };
            assert_eq!(decide(&options, &pinned).refusal, None);
        }
    }
    assert_eq!(
        serde_json::to_value(decide(&options, &Facts { signed_in: false, ..person("/w") }))
            .unwrap()["refusal"],
        json!({"kind": "signedOut"})
    );
}
