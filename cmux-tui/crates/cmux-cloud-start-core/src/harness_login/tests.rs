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
