use super::*;

fn down(error: Option<&str>) -> Evidence<'_> {
    Evidence {
        link: MachineLink::Reconnecting,
        carrier: None,
        cause: Some(DownCause::PeerDown),
        reason: None,
        error,
        last_seen: Some(1_000),
        attempts: 3,
    }
}

fn first(e: &Evidence<'_>) -> (Step, NextAction) {
    let d = diagnose("huge-blue", e, 61_000).expect("a down link is diagnosed");
    (d.failed_step, d.action)
}

/// Each of the cases the teardown names (client offline, host offline or asleep, auth or link
/// refusal, transport failure, missing daemon) is its own first failed step and action.
#[test]
fn each_failure_names_its_own_first_step_and_one_action() {
    let local = Evidence {
        cause: Some(DownCause::LocalNetwork),
        ..down(Some("IO error: Network is unreachable (os error 51)"))
    };
    assert_eq!(first(&local), (Step::Client, NextAction::CheckNetwork));

    let refused =
        Evidence { link: MachineLink::AuthFailed, cause: Some(DownCause::Auth), ..down(None) };
    assert_eq!(first(&refused), (Step::Account, NextAction::SignIn));

    let key = Evidence {
        carrier: Some(Carrier::Ssh),
        ..down(Some("ssh: user@box: Permission denied (publickey)."))
    };
    assert_eq!(first(&key), (Step::Account, NextAction::AuthorizeKey));

    let changed = down(Some(
        "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @ Host key verification failed.",
    ));
    assert_eq!(first(&changed), (Step::Transport, NextAction::VerifyHostKey));
    assert_eq!(first(&down(Some("Host key verification failed."))).1, NextAction::VerifyHostKey);

    let ssh_off = Evidence {
        carrier: Some(Carrier::Ssh),
        ..down(Some("ssh: connect to host box port 22: Connection refused"))
    };
    assert_eq!(first(&ssh_off), (Step::Transport, NextAction::EnableSsh));

    let tunnel = down(Some("channel 0: open failed: connect failed: Connection refused"));
    assert_eq!(first(&tunnel), (Step::HostDaemon, NextAction::StartDaemon));

    let direct = Evidence {
        carrier: Some(Carrier::Direct),
        ..down(Some("IO error: Connection refused (os error 61)"))
    };
    assert_eq!(first(&direct), (Step::HostDaemon, NextAction::StartDaemon));

    let asleep = down(Some("connect timed out after 5s"));
    assert_eq!(first(&asleep), (Step::Transport, NextAction::WakeMachine));

    let stopped = Evidence {
        link: MachineLink::Offline,
        reason: Some(OfflineReason::MachineStopped),
        ..down(Some("relay refused: vm.agent_stopping"))
    };
    assert_eq!(first(&stopped), (Step::HostDaemon, NextAction::StartMachine));

    let disk = Evidence { reason: Some(OfflineReason::DiskFull), ..down(None) };
    assert_eq!(first(&disk), (Step::HostDaemon, NextAction::FreeDisk));
}

/// A link that is up or on its way has nothing failed: no diagnosis, never a guess.
#[test]
fn a_link_that_is_up_or_on_its_way_has_no_diagnosis() {
    for link in [
        MachineLink::Connected,
        MachineLink::Connecting,
        MachineLink::Degraded,
        MachineLink::Restarting,
        MachineLink::Paused,
    ] {
        assert_eq!(diagnose("box", &Evidence { link, ..down(Some("x")) }, 0), None, "{link:?}");
    }
}

/// Steps before the failed one are ok, after it unknown; the provider is never claimed ready
/// from a link that is down.
#[test]
fn steps_after_the_failed_one_are_unknown_never_ok() {
    let d = diagnose("box", &down(Some("channel 0: open failed")), 0).unwrap();
    let statuses: Vec<_> = d.steps.iter().map(|r| (r.step, r.status)).collect();
    assert_eq!(
        statuses,
        vec![
            (Step::Client, StepStatus::Ok),
            (Step::Account, StepStatus::Ok),
            (Step::Transport, StepStatus::Ok),
            (Step::HostDaemon, StepStatus::Failed),
            (Step::Provider, StepStatus::Unknown),
        ]
    );
    assert!(d.needs_person);
    let quiet = diagnose("box", &down(Some("connect timed out")), 0).unwrap();
    assert!(!quiet.needs_person, "a machine that does not answer heals by itself");
}

/// The copyable detail never carries the attempt's error text, a URL, a token or a path, by
/// construction: only fixed words, counts and the machine's safe name.
#[test]
fn the_detail_carries_no_secret_url_or_error_text() {
    const SECRET: &str = "sk-live-SECRET123";
    let error = format!(
        "WebSocket error at wss://user:{SECRET}@private.example.internal:7444/peer?token={SECRET}: \
         403 Forbidden; key at /Users/leo/.ssh/id_ed25519"
    );
    let name = format!("box@{SECRET}/x?token={SECRET}");
    let d = diagnose(&name, &down(Some(&error)), 61_000).unwrap();
    let wire = serde_json::to_string(&d).unwrap();
    for leak in [SECRET, "private.example", "wss://", "/Users", "id_ed25519", "token="] {
        assert!(!wire.contains(leak), "{leak} leaked: {wire}");
    }
    assert_eq!(d.machine, "box");
    assert_eq!(d.failed_step, Step::Account);
    assert!(d.detail.contains("machine: box\n"), "{}", d.detail);
    assert!(d.detail.contains("last seen: 60s ago"), "{}", d.detail);
    assert!(d.detail.contains("next: signIn"), "{}", d.detail);
    assert_eq!(safe_name("//"), "unknown");
}

/// The wire words the app reads.
#[test]
fn the_wire_words_are_camel_case() {
    let d = diagnose("box", &down(Some("Connection refused")), 0).unwrap();
    let v = serde_json::to_value(&d).unwrap();
    assert_eq!(v["failedStep"], "hostDaemon");
    assert_eq!(v["action"], "startDaemon");
    assert_eq!(v["needsPerson"], true);
    assert_eq!(v["steps"][0]["step"], "client");
    assert_eq!(v["steps"][0]["status"], "ok");
    for step in Step::ALL {
        assert_eq!(serde_json::to_value(step).unwrap(), serde_json::json!(step.as_str()));
    }
}
