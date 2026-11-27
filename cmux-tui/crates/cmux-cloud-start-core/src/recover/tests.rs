use super::*;

fn failure(code: &str, retryable: bool, reruns: u32, elapsed_ms: u64) -> PaneFailure {
    PaneFailure { code: code.to_owned(), message: String::new(), retryable, reruns, elapsed_ms }
}

/// Every class has a row, and its name matches its variant (the CLI's fault injection reads it).
#[test]
fn every_class_has_a_row_and_a_name() {
    assert_eq!(Class::ALL.len(), Class::NAMES.len());
    for (class, name) in Class::ALL.iter().zip(Class::NAMES) {
        assert_eq!(format!("{class:?}"), *name);
        let _ = recovery(*class);
    }
}

#[test]
fn classify_reads_codes() {
    assert_eq!(classify(STUCK_CODE, "", false), Some(Class::MachineStuck));
    assert_eq!(classify("cloud.start_pending", "", false), Some(Class::StartPending));
    assert_eq!(classify("cloud.start_pending", "", true), None);
    assert_eq!(
        classify("unavailable", "No Cloud connection serves claude yet", false),
        Some(Class::NoConnection)
    );
    assert_eq!(classify("unavailable", "something else", false), None);
    assert_eq!(classify("auth.expired", "", false), Some(Class::AgentSignIn));
    assert_eq!(classify("auth.required", "", false), None);
    assert_eq!(classify("agent_session.untrusted", "", false), Some(Class::AgentRefused));
    assert_eq!(classify("cloud_start_failed", "", false), None);
}

/// The pane reruns a class whose action is a rerun, and a start that failed on its way whose card offers Retry.
#[test]
fn pane_reruns_what_the_table_and_retry_allow() {
    assert_eq!(
        pane_step(&failure("cloud.list_unread", false, 0, 0)),
        PaneStep::Rerun { pause_ms: 5_000, class: Some("ListUnread".to_owned()) }
    );
    assert_eq!(
        pane_step(&failure("cloud.start_pending", false, 1, 10_000)),
        PaneStep::Rerun { pause_ms: 10_000, class: Some("StartPending".to_owned()) }
    );
    assert_eq!(
        pane_step(&failure("", true, 0, 0)),
        PaneStep::Rerun { pause_ms: 5_000, class: None }
    );
    assert_eq!(
        pane_step(&failure("cloud_start_failed", true, 0, 0)),
        PaneStep::Rerun { pause_ms: 5_000, class: None }
    );
}

/// A person's class, a definitive refusal, an unknown code, a failure with no Retry, and a used-up or late
/// recovery all show the card.
#[test]
fn pane_surfaces_the_rest() {
    for code in [
        "cloud.signed_out",
        "cloud.spend_cap",
        "agent.limit_reached",
        "cloud.name_taken",
        "auth.expired",
    ] {
        assert_eq!(pane_step(&failure(code, true, 0, 0)), PaneStep::Surface, "{code}");
    }
    // The pane's cap card asks before freeing a machine; its fresh machine is not run from here.
    assert_eq!(pane_step(&failure("cloud.machine_cap", true, 0, 0)), PaneStep::Surface);
    assert_eq!(pane_step(&failure(STUCK_CODE, true, 0, 0)), PaneStep::Surface);
    // A specific code no class names (a disk refusal, an upload failure) is not rerun blind.
    assert_eq!(pane_step(&failure("upload_failed", true, 0, 0)), PaneStep::Surface);
    assert_eq!(pane_step(&failure("", false, 0, 0)), PaneStep::Surface);
    assert_eq!(pane_step(&failure("", true, PANE_RERUNS, 0)), PaneStep::Surface);
    let late = u64::try_from(PANE_BUDGET.as_millis()).unwrap() - 4_000;
    assert_eq!(pane_step(&failure("", true, 0, late)), PaneStep::Surface);
}

/// Every class, injected as the pane's failure, reruns exactly when the table's action is a rerun.
#[test]
fn pane_follows_the_table_for_every_class() {
    let code = |class: Class| match class {
        Class::MachineStuck => STUCK_CODE,
        Class::StartPending => "cloud.start_pending",
        Class::ListUnread => "cloud.list_unread",
        Class::MachineCap => "cloud.machine_cap",
        Class::SpendCap => "cloud.spend_cap",
        Class::SignedOut => "cloud.signed_out",
        Class::AccountChanged => "cloud.account_changed",
        Class::AppNotConnected => "cloud.app_not_connected",
        Class::NoConnection => "unavailable",
        Class::AgentSignIn => "auth.expired",
        Class::AgentLimit => "agent.limit_reached",
        Class::AgentRefused => "agent_session.refused",
        Class::StartFailed => "cloud.start_failed",
        Class::NameTaken => "cloud.name_taken",
        Class::MakeRoomFailed => "cloud.make_room_failed",
        Class::TurnFailed => "chat.turn_failed",
        Class::TurnTimeout => "chat.wait_timeout",
        Class::ChatUnreachable => "chat.lost",
        Class::SendFailed => "chat.send_failed",
        Class::PermissionWaiting => "chat.permission_waiting",
    };
    for class in Class::ALL {
        let mut sent = failure(code(*class), true, 0, 0);
        if *class == Class::NoConnection {
            sent.message = "No Cloud connection serves claude yet".to_owned();
        }
        assert_eq!(classify(&sent.code, &sent.message, false), Some(*class), "{class:?}");
        let reruns = matches!(recovery(*class), Some(Action::Rerun | Action::RerunOnMachine));
        assert_eq!(matches!(pane_step(&sent), PaneStep::Rerun { .. }), reruns, "{class:?}");
    }
}

/// The app reads the step as JSON (op `cloud_start_pane_recovery`).
#[test]
fn pane_step_json() {
    let step = serde_json::to_value(pane_step(&failure("cloud.list_unread", false, 0, 0))).unwrap();
    assert_eq!(step, serde_json::json!({"next": "rerun", "pauseMs": 5000, "class": "ListUnread"}));
    let step = serde_json::to_value(pane_step(&failure("cloud.signed_out", false, 0, 0))).unwrap();
    assert_eq!(step, serde_json::json!({"next": "surface"}));
    let read: PaneFailure =
        serde_json::from_value(serde_json::json!({"retryable": true, "reruns": 0, "elapsedMs": 0}))
            .unwrap();
    assert_eq!(read, failure("", true, 0, 0));
}
