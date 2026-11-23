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

fn busy(machine: Option<&str>) -> Facts {
    Facts {
        busy: Some(Busy {
            over: "over its budget (load1 29.8 >= 15)".into(),
            machine: machine.map(Into::into),
        }),
        ..person("/w/app")
    }
}

fn when_busy(value: &str) -> Options {
    Options::from_settings(&json!({"whenThisMacIsBusy": value}))
}

#[test]
fn when_busy_reads_its_three_values_and_stays_for_anything_else() {
    assert_eq!(when_busy("ownMachine").when_busy, WhenBusy::OwnMachine);
    assert_eq!(when_busy("ownMachineOrCloud").when_busy, WhenBusy::OwnMachineOrCloud);
    for other in ["stay", "cloud", "", "OWNMACHINE"] {
        assert_eq!(when_busy(other).when_busy, WhenBusy::Stay, "{other}");
    }
    assert_eq!(Options::default().when_busy, WhenBusy::Stay);
}

#[test]
fn off_by_default_a_busy_mac_keeps_its_new_workspace() {
    for facts in [busy(Some("ssh-gcp-3")), busy(None)] {
        let placement = decide(&Options::default(), &facts);
        assert_eq!(placement.target, Target::ThisMac);
        assert_eq!(placement.why, "Run New Workspaces in Cloud is off");
    }
}

#[test]
fn a_busy_mac_sends_its_new_workspace_to_your_machine_with_room() {
    for options in [when_busy("ownMachine"), when_busy("ownMachineOrCloud")] {
        let placement = decide(&options, &busy(Some("ssh-gcp-3")));
        assert_eq!(placement.target, Target::Machine("ssh-gcp-3".into()));
        assert_eq!(placement.refusal, None);
        assert!(
            placement.why.starts_with("this Mac is busy (over its budget"),
            "{}",
            placement.why
        );
    }
    // Not busy: here, whatever the setting.
    assert_eq!(decide(&when_busy("ownMachineOrCloud"), &person("/w/app")).target, Target::ThisMac);
}

#[test]
fn with_no_machine_with_room_cloud_takes_it_only_when_allowed_and_cloud_can() {
    let placement = decide(&when_busy("ownMachine"), &busy(None));
    assert_eq!(placement.target, Target::ThisMac);
    assert_eq!(placement.refusal, None);
    assert_eq!(
        decide(&when_busy("ownMachineOrCloud"), &busy(None)).target,
        Target::NewCloudMachine
    );
    // Cloud's own refusals and the cap still hold, and say why.
    let signed_out = Facts { signed_in: false, ..busy(None) };
    assert_eq!(
        decide(&when_busy("ownMachineOrCloud"), &signed_out).refusal,
        Some(Refusal::SignedOut)
    );
    let capped = Options { machine_cap: Some(1), ..when_busy("ownMachineOrCloud") };
    let at_cap = Facts { running_machines: 1, ..busy(None) };
    assert_eq!(decide(&capped, &at_cap).refusal, Some(Refusal::MachineCap { running: 1, cap: 1 }));
}

#[test]
fn a_pin_the_toggle_and_a_named_run_win_over_busy() {
    let options = Options::from_settings(&json!({
        "whenThisMacIsBusy": "ownMachineOrCloud", "workspacePins": {"/w/app": "thisMac"}}));
    assert_eq!(decide(&options, &busy(Some("ssh-gcp-3"))).target, Target::ThisMac);
    let on = Options { in_cloud: true, ..when_busy("ownMachine") };
    assert_eq!(decide(&on, &busy(Some("ssh-gcp-3"))).target, Target::NewCloudMachine);
    let script = Facts { by_person: false, ..busy(Some("ssh-gcp-3")) };
    assert_eq!(decide(&when_busy("ownMachine"), &script).target, Target::ThisMac);
}

mod cached_verdict {
    use super::super::busy::{MAX_AGE_MS, OwnMachine, from_cache};
    use super::*;

    const NOW: u64 = 1_000_000_000;

    fn mine() -> Vec<OwnMachine> {
        vec![
            OwnMachine {
                id: "ssh-a".into(),
                names: vec!["Lab box".into(), "leo@lab.tail.ts.net:2222".into()],
            },
            OwnMachine { id: "server-b".into(), names: vec!["gcp-3".into()] },
        ]
    }

    fn cache(at: u64, verdict: Value) -> Value {
        json!({"at": at, "verdict": verdict})
    }

    fn over(pick: &str) -> Value {
        json!({"pick": pick, "local": false, "overloaded": false, "room": 5.0,
               "localOver": "over its budget (load1 29.8 >= 15)"})
    }

    #[test]
    fn a_fresh_over_budget_verdict_names_your_machine_by_label_or_ssh_host() {
        let busy = from_cache(&cache(NOW - 1_000, over("gcp-3")), NOW, &mine()).unwrap();
        assert_eq!(busy.over, "over its budget (load1 29.8 >= 15)");
        assert_eq!(busy.machine.as_deref(), Some("server-b"));
        let by_host = from_cache(&cache(NOW, over("LAB")), NOW, &mine()).unwrap();
        assert_eq!(by_host.machine.as_deref(), Some("ssh-a"));
    }

    #[test]
    fn busy_with_no_own_machine_when_the_pick_is_unknown_full_overloaded_or_here() {
        let cases = [
            over("fleet-only-host"),
            json!({"pick": "gcp-3", "local": false, "overloaded": true, "room": 0.0, "localOver": "x"}),
            json!({"pick": "gcp-3", "local": false, "overloaded": false, "room": 0.5, "localOver": "x"}),
            json!({"pick": "gcp-3", "local": false, "overloaded": false, "room": null, "localOver": "x"}),
            json!({"pick": "gcp-3", "local": true, "overloaded": false, "room": 3, "localOver": "x"}),
            json!({"pick": null, "localOver": "x"}),
        ];
        for verdict in cases {
            let busy = from_cache(&cache(NOW, verdict.clone()), NOW, &mine());
            assert_eq!(busy.map(|b| b.machine), Some(None), "{verdict}");
        }
    }

    #[test]
    fn not_busy_stale_future_or_malformed_says_nothing() {
        let room = json!({"pick": "gcp-3", "local": false, "room": 5, "localOver": null});
        assert_eq!(from_cache(&cache(NOW, room), NOW, &mine()), None);
        let blank = json!({"pick": "gcp-3", "localOver": "  "});
        assert_eq!(from_cache(&cache(NOW, blank), NOW, &mine()), None);
        assert_eq!(from_cache(&cache(NOW - MAX_AGE_MS - 1, over("gcp-3")), NOW, &mine()), None);
        assert!(from_cache(&cache(NOW - MAX_AGE_MS, over("gcp-3")), NOW, &mine()).is_some());
        assert_eq!(from_cache(&cache(NOW + MAX_AGE_MS + 1, over("gcp-3")), NOW, &mine()), None);
        for bad in
            [json!(null), json!({"verdict": over("gcp-3")}), json!({"at": "x"}), json!({"at": NOW})]
        {
            assert_eq!(from_cache(&bad, NOW, &mine()), None, "{bad}");
        }
    }
}
