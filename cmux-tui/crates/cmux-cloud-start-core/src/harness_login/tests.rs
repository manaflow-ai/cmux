//! The harness login decision (moved from the app's `CloudStartChatLoginTests`).

use super::*;

fn inputs(gate: bool, provider: Option<Provider>, signed_in: bool) -> Inputs {
    Inputs { gate, provider, signed_in, ..Inputs::default() }
}

/// The app's common case: a signed-in Claude start on the caller's own `owner` guest with no login.
fn owner() -> Inputs {
    Inputs {
        caller_owns: Some(true),
        guest_kind: Some("owner".into()),
        machine_login: Some(MachineLogin::None),
        ..inputs(true, Some(Provider::Claude), true)
    }
}

fn cached(mut d: Inputs) -> Inputs {
    d.cached = true;
    d
}

#[test]
fn a_cached_login_installs_silently_and_the_first_one_asks_once() {
    let d = decide(&cached(owner()));
    assert_eq!((d.step, d.reason), (Step::Install, Reason::InstallCached));
    let d = decide(&owner());
    assert_eq!((d.step, d.reason), (Step::ConfirmThenInstall, Reason::ConfirmFirst));
    // A rejected login is replaced like a missing one; no login read yet counts as missing.
    let rejected = Inputs { machine_login: Some(MachineLogin::Rejected), ..cached(owner()) };
    assert_eq!(decide(&rejected).step, Step::Install);
    let unread = Inputs { machine_login: None, ..cached(owner()) };
    assert_eq!(decide(&unread).step, Step::Install);
}

#[test]
fn every_skip_has_its_own_reason() {
    // A production build, a harness whose login stays per machine, no signed-in user, a machine the
    // caller does not own (a teammate's), a guest with no known kind, a guest whose kind could not be
    // read, or a login there that stays.
    let skips = [
        (Inputs { gate: false, ..cached(owner()) }, Reason::BuildGateOff),
        (Inputs { provider: Some(Provider::Codex), ..cached(owner()) }, Reason::NoTransfer),
        (Inputs { provider: None, ..owner() }, Reason::NoTransfer),
        (Inputs { signed_in: false, ..cached(owner()) }, Reason::SignedOut),
        (Inputs { caller_owns: Some(false), ..cached(owner()) }, Reason::CallerNotOwner),
        (Inputs { caller_owns: None, ..cached(owner()) }, Reason::CallerNotOwner),
        (Inputs { guest_kind: Some(String::new()), ..cached(owner()) }, Reason::GuestNotOwner),
        (Inputs { guest_kind: Some("shared".into()), ..cached(owner()) }, Reason::GuestNotOwner),
        (Inputs { guest_kind: None, ..cached(owner()) }, Reason::GuestUnread),
        (
            Inputs { machine_login: Some(MachineLogin::Working), ..cached(owner()) },
            Reason::MachineLoginKept,
        ),
        (
            Inputs { machine_login: Some(MachineLogin::Cached), ..cached(owner()) },
            Reason::MachineLoginKept,
        ),
        (
            Inputs { machine_login: Some(MachineLogin::Session), ..cached(owner()) },
            Reason::MachineLoginKept,
        ),
    ];
    for (d, reason) in skips {
        let decision = decide(&d);
        assert_eq!((decision.step, decision.reason), (Step::Skip, reason), "{d:?}");
    }
}

#[test]
fn the_creators_team_guest_takes_the_login() {
    // Leo, 2026-11-01: "team or no team the thing should just work"; a teammate's never does
    // (the platform does not answer owner).
    let team = Inputs { guest_kind: Some("team".into()), ..owner() };
    assert_eq!(decide(&cached(team.clone())).step, Step::Install);
    assert_eq!(decide(&team).step, Step::ConfirmThenInstall);
    assert!(decide(&team).guest_takes_login && decide(&owner()).guest_takes_login);
    assert!(!decide(&Inputs { guest_kind: Some(String::new()), ..owner() }).guest_takes_login);
    let teammate = Inputs { caller_owns: Some(false), ..cached(team) };
    assert_eq!(decide(&teammate).reason, Reason::CallerNotOwner);
}

#[test]
fn only_a_decision_that_got_that_far_reads_the_machine() {
    assert!(decide(&owner()).reads_machine);
    assert!(!decide(&Inputs { caller_owns: Some(false), ..owner() }).reads_machine);
    assert!(!decide(&Inputs { gate: false, ..owner() }).reads_machine);
    assert!(!decide(&Inputs { provider: Some(Provider::Codex), ..owner() }).reads_machine);
    assert!(!decide(&Inputs { signed_in: false, ..owner() }).reads_machine);
}

/// The start's record (the log and `cloud.machines`' `harness_login`) names the step, the reason and every input.
#[test]
fn the_record_says_why_it_skipped() {
    let base = Inputs {
        caller_owns: Some(true),
        cached: true,
        ..inputs(true, Some(Provider::Claude), true)
    };
    let none = Inputs { guest_kind: Some(String::new()), ..base.clone() };
    assert_eq!(
        decide(&none).summary,
        "skip (guest-not-owner): gate on, provider claude, signed in yes, caller owns yes, guest (none), machine login -, cached yes"
    );
    let team = Inputs { guest_kind: Some("team".into()), ..base.clone() };
    assert_eq!(
        decide(&team).summary,
        "install (install-cached): gate on, provider claude, signed in yes, caller owns yes, guest team, machine login -, cached yes"
    );
    let installed = Inputs {
        guest_kind: Some("owner".into()),
        machine_login: Some(MachineLogin::Rejected),
        outcome: Some("installed".into()),
        ..base
    };
    let summary = decide(&installed).summary;
    assert!(summary.starts_with("install (install-cached): "), "{summary}");
    assert!(
        summary.ends_with("guest owner, machine login rejected, cached yes -> installed"),
        "{summary}"
    );
    let off = decide(&inputs(false, Some(Provider::Claude), true)).summary;
    assert!(off.starts_with("skip (build-gate-off): gate off"), "{off}");
    assert!(off.contains("caller owns -, guest -, machine login -, cached no"), "{off}");
    assert!(decide(&inputs(true, None, false)).summary.contains("provider -, signed in no"));
}

/// The creator's team guest is no longer skipped, so it never marks the chat's card a team machine.
#[test]
fn a_creators_team_guest_is_not_a_skipped_team_machine() {
    let owns = |kind: &str| Inputs {
        caller_owns: Some(true),
        guest_kind: Some(kind.into()),
        ..inputs(true, Some(Provider::Claude), true)
    };
    for kind in ["team", "", "owner", "shared"] {
        assert!(!decide(&owns(kind)).skipped_team_machine, "{kind}");
    }
    assert!(
        !decide(&Inputs {
            guest_kind: Some("team".into()),
            ..inputs(false, Some(Provider::Claude), true)
        })
        .skipped_team_machine
    );
    assert!(!decide(&Inputs { caller_owns: Some(false), ..owns("team") }).skipped_team_machine);
}

#[test]
fn harness_families_map_to_their_provider() {
    assert_eq!(login_provider(None), Some(Provider::Claude));
    assert_eq!(login_provider(Some("")), Some(Provider::Claude));
    assert_eq!(login_provider(Some("claude")), Some(Provider::Claude));
    assert_eq!(login_provider(Some("claude-sr2")), Some(Provider::Claude));
    assert_eq!(login_provider(Some("Claude_opus")), Some(Provider::Claude));
    assert_eq!(login_provider(Some("team/claude-sr2")), Some(Provider::Claude));
    assert_eq!(login_provider(Some("codex")), Some(Provider::Codex));
    assert_eq!(login_provider(Some("codex sol")), Some(Provider::Codex));
    assert_eq!(login_provider(Some("opencode")), None);
    assert_eq!(login_provider(Some("pi")), None);
    assert_eq!(login_provider(Some("claude/")), None);
}

/// The guest's kind comes after a marker, so an exec that ran is told from one that failed.
#[test]
fn the_guest_probe_reads_the_vm_kind() {
    assert!(GUEST_KIND_PROBE.contains("/etc/cmux/vm-kind"));
    assert_eq!(guest_kind("vm-kind:owner\n").as_deref(), Some("owner"));
    assert_eq!(guest_kind("motd\nvm-kind:team\n").as_deref(), Some("team"));
    assert_eq!(guest_kind("vm-kind: team \t\n").as_deref(), Some("team"));
    assert_eq!(guest_kind("vm-kind:\n").as_deref(), Some(""));
    assert_eq!(guest_kind(""), None);
    assert_eq!(guest_kind("motd\n"), None);
}

/// The probe runs under a plain `sh`: on a host with no `/etc/cmux/vm-kind` it still answers, with an empty kind.
#[cfg(unix)]
#[test]
fn the_guest_probe_answers_without_a_kind_file() {
    if std::path::Path::new("/etc/cmux/vm-kind").exists() {
        return;
    }
    let ran = std::process::Command::new("/bin/sh")
        .args(["-c", GUEST_KIND_PROBE])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .output()
        .expect("sh runs");
    assert!(ran.status.success());
    assert_eq!(guest_kind(&String::from_utf8_lossy(&ran.stdout)).as_deref(), Some(""));
}

#[test]
fn the_wire_is_the_apps_shape() {
    let request: Inputs = serde_json::from_str(
        r#"{"gate":true,"provider":"claude","signedIn":true,"callerOwns":true,"guestKind":"owner","machineLogin":"rejected","cached":true}"#,
    )
    .unwrap();
    assert_eq!(request.machine_login, Some(MachineLogin::Rejected));
    let reply = serde_json::to_value(decide(&request)).unwrap();
    assert_eq!(reply["step"], "install");
    assert_eq!(reply["reason"], "install-cached");
    assert_eq!(reply["readsMachine"], true);
    assert_eq!(reply["guestTakesLogin"], true);
    assert_eq!(reply["skippedTeamMachine"], false);
    // Absent fields are the start's "not asked yet".
    let bare: Inputs = serde_json::from_str("{}").unwrap();
    assert_eq!(decide(&bare).reason, Reason::BuildGateOff);
    let reply = serde_json::to_value(decide(&inputs(true, Some(Provider::Claude), true))).unwrap();
    assert_eq!(reply["step"], "skip");
    assert_eq!(reply["reason"], "caller-not-owner");
}

/// Only DEV and dogfood builds pass a login; the setting can turn it off there and never turns it
/// on in Release (moved from the app's `CloudStartChatLoginTests.theSettingWinsElseOnlyDogfoodBuildsPassALogin`).
#[test]
fn the_setting_wins_else_only_dogfood_builds_pass_a_login() {
    assert!(passes_harness_login(true, None));
    assert!(!passes_harness_login(false, None));
    // `defaults write ... cmux.cloud.passHarnessLogin -bool YES` in Release passes nothing.
    assert!(!passes_harness_login(false, Some(true)));
    assert!(passes_harness_login(true, Some(true)));
    // `defaults write ... cmux.cloud.passHarnessLogin -bool NO`: a DEV build behaves as production.
    assert!(!passes_harness_login(true, Some(false)));
    assert!(!passes_harness_login(false, Some(false)));
    // The one call resolves the gate from the build and its setting, over a `gate` sent with them.
    let d = |dogfood, setting| Inputs {
        dogfood: Some(dogfood),
        setting,
        gate: !dogfood,
        ..cached(owner())
    };
    assert_eq!(decide(&d(true, None)).step, Step::Install);
    assert!(decide(&d(true, None)).gate);
    assert_eq!(decide(&d(true, Some(false))).reason, Reason::BuildGateOff);
    assert_eq!(decide(&d(false, None)).reason, Reason::BuildGateOff);
    assert_eq!(decide(&d(false, Some(true))).reason, Reason::BuildGateOff);
}

/// The chat's harness, the guest probe's output and the machine probe's output go into the one
/// call (cmux#32416): it resolves them, so the app has no other FFI call whose failure would read
/// as `no-transfer-for-harness` or `guest-kind-unread`.
#[test]
fn the_one_call_resolves_the_harness_and_the_probes() {
    let raw = |harness: &str, guest: Option<&str>, probe: Option<(i64, &str)>| Inputs {
        harness: Some(harness.into()),
        provider: None,
        guest_stdout: guest.map(str::to_owned),
        guest_kind: None,
        machine_probe: probe.map(|(exit_code, stdout)| crate::machine_login::Probe {
            exit_code,
            stdout: stdout.into(),
        }),
        machine_login: None,
        ..cached(owner())
    };
    let d = decide(&raw("", Some("vm-kind:owner\n"), Some((0, "none\n"))));
    assert_eq!((d.step, d.reason), (Step::Install, Reason::InstallCached));
    assert_eq!(d.provider, Some(Provider::Claude));
    assert_eq!(d.guest_kind.as_deref(), Some("owner"));
    assert_eq!(d.machine_login, Some(MachineLogin::None));
    assert_eq!(
        decide(&raw("claude-sr2", Some("motd\nvm-kind:team\n"), None)).guest_kind.as_deref(),
        Some("team")
    );
    // A harness with no transfer, and Codex, which keeps its broker flow.
    let pi = decide(&raw("pi", None, None));
    assert_eq!((pi.reason, pi.provider), (Reason::NoTransfer, None));
    assert!(!pi.reads_machine);
    assert_eq!(decide(&raw("codex", None, None)).provider, Some(Provider::Codex));
    // A probe that printed no marker, or one that never ran.
    assert_eq!(decide(&raw("", Some("motd\n"), None)).reason, Reason::GuestUnread);
    assert_eq!(decide(&raw("", None, None)).reason, Reason::GuestUnread);
    assert_eq!(decide(&raw("", Some("vm-kind:\n"), None)).reason, Reason::GuestNotOwner);
    // The machine probe's word, else its exit code.
    let kept = decide(&raw("", Some("vm-kind:owner\n"), Some((0, "session\n"))));
    assert_eq!(
        (kept.reason, kept.machine_login),
        (Reason::MachineLoginKept, Some(MachineLogin::Session))
    );
    assert_eq!(
        decide(&raw("", Some("vm-kind:owner\n"), Some((0, "")))).reason,
        Reason::MachineLoginKept
    );
    assert_eq!(decide(&raw("", Some("vm-kind:owner\n"), Some((1, "")))).step, Step::Install);
    assert_eq!(
        decide(&raw("", Some("vm-kind:owner\n"), Some((0, "rejected")))).step,
        Step::Install
    );
    // The record names the resolved values.
    let summary = decide(&raw("codex", None, None)).summary;
    assert!(
        summary.starts_with("skip (no-transfer-for-harness): gate on, provider codex,"),
        "{summary}"
    );
}

/// The probe to run comes back on the decision, so the app asks nothing else before it reads the guest.
#[test]
fn the_decision_carries_the_guest_probe() {
    let d = decide(&Inputs { guest_kind: None, ..owner() });
    assert!(d.reads_machine);
    assert_eq!(d.guest_kind_probe, GUEST_KIND_PROBE);
    let reply = serde_json::to_value(&d).unwrap();
    assert!(reply["guestKindProbe"].as_str().unwrap().contains("/etc/cmux/vm-kind"));
    assert_eq!(reply["provider"], "claude");
    assert_eq!(reply["guestKind"], serde_json::Value::Null);
    assert_eq!(reply["gate"], true);
    let request: Inputs = serde_json::from_str(
        r#"{"dogfood":true,"harness":"","signedIn":true,"callerOwns":true,"guestStdout":"vm-kind:team\n","machineProbe":{"exitCode":0,"stdout":"rejected\n"},"cached":true}"#,
    )
    .unwrap();
    let reply = serde_json::to_value(decide(&request)).unwrap();
    assert_eq!(reply["step"], "install");
    assert_eq!(reply["guestKind"], "team");
    assert_eq!(reply["machineLogin"], "rejected");
}

/// A machine that already has a working login is used as it is, whatever the choice (Leo,
/// 2026-11-02: "didn't we have like the daemon or whatever on your machine is able to have the token").
#[test]
fn a_working_machine_login_is_used_whatever_the_choice() {
    for login in [MachineLogin::Session, MachineLogin::Cached, MachineLogin::Working] {
        for requested in [None, Some(Choice::Pass), Some(Choice::Machine)] {
            let d = Inputs { machine_login: Some(login), requested, headless: true, ..owner() };
            assert_eq!(
                (decide(&d).step, decide(&d).reason),
                (Step::Skip, Reason::MachineLoginKept),
                "{login:?} {requested:?}"
            );
        }
    }
}

/// A CLI or agent run with no login, nothing cached and no choice stops at once, never on a prompt.
#[test]
fn a_headless_start_with_no_login_and_no_choice_refuses_at_once() {
    let d = decide(&Inputs { headless: true, ..owner() });
    assert_eq!((d.step, d.reason), (Step::Refuse, Reason::NeedsLoginChoice));
    // The app's own composer start still asks once.
    assert_eq!(decide(&owner()).step, Step::ConfirmThenInstall);
    // A cached login is the choice made once: every later machine takes it with no prompt.
    assert_eq!(decide(&Inputs { headless: true, ..cached(owner()) }).reason, Reason::InstallCached);
}

#[test]
fn the_flag_then_the_stored_choice_decide() {
    let headless = Inputs { headless: true, ..owner() };
    let none = Inputs { requested: Some(Choice::None), ..headless.clone() };
    let d = decide(&none);
    assert_eq!((d.step, d.reason, d.reads_machine), (Step::Skip, Reason::ChoseNone, false));
    let machine = Inputs { requested: Some(Choice::Machine), ..headless.clone() };
    assert_eq!(decide(&machine).reason, Reason::MachineLoginMissing);
    assert_eq!(decide(&machine).step, Step::Refuse);
    // The person's own --login pass is their confirm; an agent's is not.
    let person =
        Inputs { requested: Some(Choice::Pass), requested_by_person: true, ..headless.clone() };
    assert_eq!(decide(&person).reason, Reason::InstallChosen);
    let agent = Inputs { requested: Some(Choice::Pass), ..headless.clone() };
    assert_eq!(decide(&agent).reason, Reason::NeedsLoginChoice);
    // The stored choice stands in for a missing flag; the flag wins over it.
    let stored = Inputs { stored: Some(Choice::None), ..headless.clone() };
    assert_eq!(decide(&stored).reason, Reason::ChoseNone);
    let flag_wins =
        Inputs { requested: Some(Choice::Machine), stored: Some(Choice::None), ..headless };
    assert_eq!(decide(&flag_wins).reason, Reason::MachineLoginMissing);
    assert!(decide(&flag_wins).summary.contains(", login machine, headless"));
}

#[test]
fn a_kept_pass_is_the_persons_consent_and_none_reads_nothing() {
    let headless = Inputs { headless: true, ..owner() };
    // Sign in at most once per user: the pass they chose before installs on a later headless start.
    let kept = Inputs { stored: Some(Choice::Pass), ..headless.clone() };
    assert_eq!((decide(&kept).step, decide(&kept).reason), (Step::Install, Reason::InstallChosen));
    let agent_with_kept = Inputs { requested: Some(Choice::Pass), ..kept };
    assert_eq!(decide(&agent_with_kept).step, Step::Install);
    let agent_over_machine =
        Inputs { requested: Some(Choice::Pass), stored: Some(Choice::Machine), ..headless };
    assert_eq!(decide(&agent_over_machine).reason, Reason::NeedsLoginChoice);
    // A fresh `--login none` decides before the owner or the guest is read.
    let fresh = Inputs {
        gate: true,
        provider: Some(Provider::Claude),
        signed_in: true,
        requested: Some(Choice::None),
        headless: true,
        ..Inputs::default()
    };
    let d = decide(&fresh);
    assert_eq!((d.step, d.reason, d.reads_machine), (Step::Skip, Reason::ChoseNone, false));
}

#[test]
fn the_choice_is_on_the_wire() {
    let request: Inputs = serde_json::from_str(
        r#"{"gate":true,"provider":"claude","signedIn":true,"callerOwns":true,"guestKind":"owner","machineLogin":"none","requested":"pass","requestedByPerson":true,"headless":true}"#,
    )
    .unwrap();
    let reply = serde_json::to_value(decide(&request)).unwrap();
    assert_eq!(reply["step"], "install");
    assert_eq!(reply["reason"], "install-chosen");
    let refused = Inputs { requested: None, requested_by_person: false, ..request };
    let reply = serde_json::to_value(decide(&refused)).unwrap();
    assert_eq!(reply["step"], "refuse");
    assert_eq!(reply["reason"], "needs-login-choice");
}
