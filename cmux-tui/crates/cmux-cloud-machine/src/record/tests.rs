//! Reading a machine record (moved from the app's CloudMachineCapabilityTests,
//! CloudMachineTeamMetadataTests, CloudIdlePauseTests, CloudMachineChangeStateTests,
//! CloudMachineAgentInfrastructureTests and CloudPhoneDirectoryFactsTests).

use serde_json::{Value, json};

use super::*;

fn classic(text: &str) -> Machine {
    from_classic(&serde_json::from_str::<Value>(text).unwrap()).unwrap()
}

fn next(value: Value) -> Machine {
    from_next(&value).unwrap()
}

#[test]
fn a_classic_record_keeps_provider_capabilities() {
    let machine = classic(
        r#"{"id":"vm-1","provider":"freestyle","status":"running","capabilities":{"exec":true,"ports":true,"attachTransports":["cmux-remote"]}}"#,
    );
    let capabilities = machine.capabilities();
    assert!(capabilities.exec && capabilities.ports && !capabilities.desktop);
    assert_eq!(capabilities.attach_transports, ["cmux-remote"]);
    assert_eq!(capabilities.supported_operations(), [Operation::Exec, Operation::Ports]);
}

#[test]
fn an_older_record_uses_conservative_defaults_and_allows_every_action() {
    let machine = classic(r#"{"id":"vm-old"}"#);
    assert!(machine.declared_capabilities.is_none());
    assert!(machine.capabilities().supported_operations().is_empty());
    assert!(machine.capabilities().attach_transports.is_empty());
    for operation in Operation::ALL {
        assert!(machine.allows(operation), "{operation:?}");
    }
    // A create answer carries no status: the machine is coming up.
    assert_eq!(machine.status, Status::Provisioning);
    assert_eq!(machine.provider, "");
}

#[test]
fn explicitly_false_capabilities_refuse_their_actions() {
    let machine =
        classic(r#"{"id":"vm-1","capabilities":{"snapshot":false,"fork":false,"ports":true}}"#);
    assert!(!machine.allows(Operation::Snapshot));
    assert!(!machine.allows(Operation::Fork));
    assert!(!machine.allows(Operation::Sizing));
    assert!(machine.allows(Operation::Ports));
}

#[test]
fn a_capability_name_list_decodes() {
    let machine =
        classic(r#"{"id":"vm-2","capabilities":["exec","persistent_home","agent_session"]}"#);
    assert!(machine.declared_capabilities.is_some());
    assert_eq!(
        machine.capabilities().supported_operations(),
        [Operation::Exec, Operation::PersistentHome]
    );
    assert!(machine.allows(Operation::Exec));
    assert!(!machine.allows(Operation::Snapshot));
}

#[test]
fn next_records_keep_cloud_actions() {
    let machine =
        next(json!({"id": "m-1", "status": "running", "capabilities": ["agent_session"]}));
    assert!(machine.allows(Operation::Ports) && machine.allows(Operation::Fork));
    assert_eq!(machine.provider, "cmux-next");
}

#[test]
fn a_next_record_that_serves_desktop_opens_the_rd_viewer_for_its_creator() {
    let machine = next(json!({
        "id": "m-desk", "status": "running", "desktop": true,
        "creator": "user_u0000000000000000001", "capabilities": ["agent_session"],
    }));
    assert!(machine.serves_desktop);
    assert!(machine.capabilities().desktop);
    assert!(machine.allows(Operation::Desktop));
    assert_eq!(facts(&machine, Some("user_u0000000000000000001")).desktop_viewer, "rd");
    // The rd stream is the creator's alone: a teammate, or no signed-in user, keeps the noVNC page.
    assert_eq!(facts(&machine, Some("user_u0000000000000000002")).desktop_viewer, "web");
    assert_eq!(facts(&machine, None).desktop_viewer, "web");
    // Serving the desktop declares nothing else.
    assert!(machine.declared_capabilities.is_none());
    assert!(machine.allows(Operation::Ports) && machine.allows(Operation::Fork));
}

#[test]
fn a_next_record_without_desktop_keeps_the_web_viewer() {
    for record in [
        json!({"id": "m-old", "status": "running"}),
        json!({"id": "m-off", "status": "running", "desktop": false}),
    ] {
        let machine = next(record);
        assert!(!machine.serves_desktop && !machine.capabilities().desktop);
        assert_eq!(facts(&machine, Some("user_u0000000000000000001")).desktop_viewer, "web");
    }
    // A classic machine that declares desktop opens rd for anyone.
    let declared = classic(r#"{"id":"vm-d","capabilities":{"desktop":true}}"#);
    assert_eq!(facts(&declared, None).desktop_viewer, "rd");
}

#[test]
fn declared_capabilities_gain_desktop_when_the_record_serves_it() {
    let machine = next(json!({"id": "m-ops", "desktop": true, "provider_operations": ["exec"]}));
    assert!(machine.allows(Operation::Desktop) && machine.capabilities().desktop);
    assert!(machine.allows(Operation::Exec));
    assert!(!machine.allows(Operation::Snapshot));
    // A null newer spelling wins over an older one: no declared set.
    let null =
        next(json!({"id": "m", "provider_operations": null, "providerOperations": ["exec"]}));
    assert!(null.declared_capabilities.is_none());
    let object = next(json!({"id": "m", "providerOperations": {"exec": true}}));
    assert_eq!(object.capabilities().supported_operations(), [Operation::Exec]);
}

#[test]
fn the_classic_creator_reads_from_either_key_and_shape() {
    for key in ["createdByUserId", "createdBy"] {
        let machine = from_classic(
            &json!({"id": "vm-team", "provider": "freestyle", "status": "running", key: "user-a"}),
        )
        .unwrap();
        assert_eq!(machine.created_by.as_deref(), Some("user-a"));
    }
    let list: Vec<Machine> = [
        r#"{"id":"vm-a","provider":"freestyle","status":"running","displayName":"Shared box","slug":"calm-blue-sky","image":"devbox","imageVersion":null,"kind":"devbox","createdAt":1760000000000,"createdBy":{"userId":"user-a","displayName":"Ada Lovelace"},"address":{"ipv4":null,"ipv6":null}}"#,
        r#"{"id":"vm-b","provider":"freestyle","status":"paused","createdBy":{"userId":"user-b","displayName":null}}"#,
        r#"{"id":"vm-c","provider":"freestyle","status":"running","createdBy":null}"#,
    ]
    .into_iter()
    .map(classic)
    .collect();
    assert_eq!(
        list.iter().map(|m| m.created_by.as_deref()).collect::<Vec<_>>(),
        [Some("user-a"), Some("user-b"), None]
    );
    assert_eq!(list[0].created_at, Some(1_760_000_000_000.0));
    assert_eq!(classic(r#"{"id":"vm-new","provider":"freestyle","createdBy":{"userId":"user-a","displayName":"Ada"}}"#).created_by.as_deref(), Some("user-a"));
    assert_eq!(
        classic(r#"{"id":"vm-old","createdByUserId":null,"createdBy":null}"#).created_by,
        None
    );
}

#[test]
fn malformed_classic_fields_still_fail_the_record() {
    for text in [
        r#"{"id":42,"createdBy":{"userId":"user-a","displayName":null}}"#,
        r#"{"id":"vm-bad","createdBy":{"userId":42,"displayName":null}}"#,
        r#"{"id":"vm-bad","status":3}"#,
        r#"{"id":"vm-bad","displayName":true}"#,
        r#"{"id":"vm-bad","capabilities":{"exec":"yes"}}"#,
        r#"{"id":"vm-bad","capabilities":3}"#,
        r#"{"id":"vm-bad","size":{"cpu":"two"}}"#,
        r#"{"status":"running"}"#,
    ] {
        assert!(from_classic(&serde_json::from_str::<Value>(text).unwrap()).is_err(), "{text}");
    }
}

#[test]
fn next_records_carry_creator_and_team() {
    let machine = next(
        json!({"id": "vm-shared", "status": "running", "creator": "user-b", "team": "team_a", "created_at": 1_700_000_000_000_i64}),
    );
    assert_eq!(machine.created_by.as_deref(), Some("user-b"));
    assert_eq!(machine.team.as_deref(), Some("team_a"));
    assert_eq!(machine.created_at, Some(1_700_000_000_000.0));
    let old = next(json!({"id": "vm-old", "status": "running"}));
    assert_eq!(old.created_by, None);
    assert_eq!(
        classic(r#"{"id":"vm-old","provider":"freestyle","status":"running"}"#).created_by,
        None
    );
    assert!(from_next(&json!({"id": ""})).is_none());
    assert!(from_next(&json!({"status": "running"})).is_none());
}

#[test]
fn a_next_record_carries_when_a_paused_machine_is_deleted() {
    let paused = next(json!({"id": "vm_p", "status": "paused", "evict_at": 1_800_000_000_000_i64}));
    assert_eq!(paused.evict_at, Some(1_800_000_000_000.0));
    // Warn mode or an older server: null or absent; a malformed value drops only itself.
    for value in [json!(null), json!("soon"), json!(-1)] {
        assert_eq!(
            next(json!({"id": "vm_p", "status": "paused", "evict_at": value})).evict_at,
            None
        );
    }
    assert_eq!(next(json!({"id": "vm_p", "status": "paused"})).evict_at, None);
    // The app's JSON (CloudMachine.swift `evictAt`) keeps it.
    let text = serde_json::to_value(&paused).unwrap();
    assert_eq!(text["evictAt"], 1_800_000_000_000.0);
    assert_eq!(serde_json::from_value::<Machine>(text).unwrap(), paused);
}

#[test]
fn the_record_carries_why_it_is_paused_and_its_idle_timeout() {
    let idle =
        classic(r#"{"id":"vm-1","status":"paused","pauseReason":"idle","idlePauseMinutes":30}"#);
    assert_eq!((idle.pause_reason, idle.idle_pause_minutes), (Some(PauseReason::Idle), Some(30)));
    let user =
        classic(r#"{"id":"vm-2","status":"paused","pauseReason":"user","idlePauseMinutes":0}"#);
    assert_eq!((user.pause_reason, user.idle_pause_minutes), (Some(PauseReason::User), Some(0)));
    // An older server or an unknown reason reads as none, and a malformed value drops only itself.
    let old = classic(r#"{"id":"vm-old","status":"paused"}"#);
    assert_eq!((old.pause_reason, old.idle_pause_minutes), (None, None));
    let odd = classic(
        r#"{"id":"vm-odd","status":"paused","pauseReason":"billing","idlePauseMinutes":"x"}"#,
    );
    assert_eq!((odd.pause_reason, odd.idle_pause_minutes), (None, None));
}

#[test]
fn the_record_carries_idle_pause_diagnostics() {
    let diagnostics = r#"{"minutes":30,"lastCheckedAt":1700000000000,"idleSince":1699998000000,"lastApiActivityAt":1699999000000,"privateAddressKnown":true,"lastDecision":{"at":1700000000000,"outcome":"idle","reason":"idle","run":{"checked":8,"elapsedMs":120}}}"#;
    let machine =
        classic(&format!(r#"{{"id":"vm-diag","status":"running","idlePause":{diagnostics}}}"#));
    let idle = machine.idle_pause.unwrap();
    assert_eq!(idle.minutes, 30);
    assert_eq!(idle.last_checked_at, Some(1_700_000_000_000));
    assert_eq!(idle.idle_since, Some(1_699_998_000_000));
    assert_eq!(idle.last_api_activity_at, Some(1_699_999_000_000));
    assert!(idle.private_address_known);
    let decision = idle.last_decision.unwrap();
    assert_eq!(
        (decision.at, decision.outcome.as_str(), decision.reason.as_str()),
        (1_700_000_000_000, "idle", "idle")
    );
    assert_eq!((decision.run.checked, decision.run.elapsed_ms), (8, 120));

    let next_record: Value = serde_json::from_str(&format!(
        r#"{{"id":"vm-next","status":"running","idlePauseMinutes":30,"idlePause":{diagnostics}}}"#
    ))
    .unwrap();
    let from_app_server = next(next_record);
    assert_eq!(from_app_server.idle_pause.unwrap().last_decision.unwrap().run.elapsed_ms, 120);
    assert_eq!(from_app_server.idle_pause_minutes, Some(30));
    let policy = next(
        json!({"id": "vm-next-policy", "status": "running", "idle_policy": {"idle_seconds": 1800}}),
    );
    assert_eq!(policy.idle_pause_minutes, Some(30));
    // A malformed decision drops only the decision; a malformed object drops the diagnostics.
    let partial = classic(
        r#"{"id":"vm","idlePause":{"minutes":5,"privateAddressKnown":false,"lastDecision":{"at":"x"}}}"#,
    );
    assert!(partial.idle_pause.unwrap().last_decision.is_none());
    assert!(classic(r#"{"id":"vm","idlePause":{"minutes":5}}"#).idle_pause.is_none());
}

#[test]
fn every_backend_status_keeps_its_own_state() {
    for (wire, status) in [
        ("provisioning", Status::Provisioning),
        ("starting", Status::Starting),
        ("running", Status::Running),
        ("pausing", Status::Pausing),
        ("paused", Status::Paused),
        ("deleting", Status::Deleting),
        ("failed", Status::Failed),
        ("rebooting", Status::Unknown),
        ("destroyed", Status::Unknown),
    ] {
        assert_eq!(next(json!({"id": "vm_1", "status": wire})).status, status, "{wire}");
    }
    assert_eq!(classic(r#"{"id":"vm","status":"destroyed"}"#).status, Status::Destroyed);
    assert_eq!(classic(r#"{"id":"vm","status":"rebooting"}"#).status, Status::Unknown);
}

#[test]
fn only_the_in_between_states_are_changing() {
    for status in Status::ALL {
        let changing = matches!(status, Status::Pausing | Status::Starting | Status::Deleting);
        assert_eq!(status.is_changing(), changing, "{status:?}");
    }
    // A machine starting again is on its way up; one pausing or deleting is not.
    assert!(Status::Starting.is_live());
    assert!(!Status::Pausing.is_live() && !Status::Deleting.is_live());
    assert!(Status::Running.is_live() && Status::Provisioning.is_live());
}

#[test]
fn the_pause_reason_is_read_as_the_backend_spells_it() {
    let reason = |record: Value| next(record).pause_reason;
    assert_eq!(reason(json!({"id": "vm_1", "pause_reason": "idle"})), Some(PauseReason::Idle));
    // The cost backstop is cmux's own idle pause too: an attach resumes it.
    assert_eq!(reason(json!({"id": "vm_1", "pause_reason": "no_report"})), Some(PauseReason::Idle));
    assert_eq!(reason(json!({"id": "vm_1", "pause_reason": "provider_stopped"})), None);
    assert_eq!(reason(json!({"id": "vm_1", "pause_reason": null})), None);
    // An older app server's camel case still reads.
    assert_eq!(reason(json!({"id": "vm_1", "pauseReason": "idle"})), Some(PauseReason::Idle));
    assert_eq!(reason(json!({"id": "vm_1"})), None);
}

#[test]
fn the_records_error_is_the_last_changes_failure() {
    let failed = next(
        json!({"id": "vm_1", "error": {"code": "cloud.provider.unavailable", "message": "no capacity", "at": 1_700_000_000_000_i64}}),
    );
    let failure = failed.last_change_failure.unwrap();
    assert_eq!(failure.code, "cloud.provider.unavailable");
    assert_eq!(failure.text, "no capacity");
    assert_eq!(failure.at, Some(1_700_000_000_000.0));
    assert!(next(json!({"id": "vm_1", "error": null})).last_change_failure.is_none());
    assert!(next(json!({"id": "vm_1", "error": "odd"})).last_change_failure.is_none());
    assert!(next(json!({"id": "vm_1", "error": {"code": ""}})).last_change_failure.is_none());
    assert_eq!(
        next(json!({"id": "vm_1", "error": {"code": "x", "message": ""}}))
            .last_change_failure
            .unwrap()
            .text,
        "x"
    );
    // The classic record reads the same fields.
    let decoded = classic(r#"{"id":"vm-1","status":"pausing","error":{"code":"x","message":"y"}}"#);
    assert_eq!(decoded.status, Status::Pausing);
    assert_eq!(decoded.last_change_failure.unwrap().text, "y");
    assert!(
        classic(r#"{"id":"vm-1","error":{"code":"x","message":3}}"#).last_change_failure.is_none()
    );
}

#[test]
fn the_next_revision_is_decimal_text_only() {
    assert_eq!(
        next(json!({"id": "vm_1", "revision": "18446744073709551616"})).server_revision.as_deref(),
        Some("18446744073709551616")
    );
    assert!(next(json!({"id": "vm_1", "revision": 12})).server_revision.is_none());
}

#[test]
fn display_facts_drop_themselves_never_the_machine() {
    let machine = classic(
        r#"{"id":"vm","hourlyRateUsd":"x","runningSince":"y","updatedAt":true,"sizePick":{"vcpus":2}}"#,
    );
    assert_eq!(
        (machine.hourly_rate_usd, machine.running_since, machine.updated_at),
        (None, None, None)
    );
    assert!(machine.size_pick.is_none());
    let pick = classic(
        r#"{"id":"vm","hourlyRateUsd":0.12,"runningSince":1000,"sizePick":{"vcpus":2,"memoryGb":4,"pick":"sm","reason":"small repo"}}"#,
    );
    assert_eq!(pick.hourly_rate_usd, Some(0.12));
    assert_eq!(pick.running_since, Some(1000.0));
    assert!(pick.size_pick.is_some());
}

#[test]
fn the_shown_name_is_the_display_name_else_the_slug_else_the_id() {
    let mut machine = Machine::new("vm_8f2c1a", Status::Running);
    assert_eq!((machine.shown_name(), machine.title()), (None, "vm_8f2c1a"));
    machine.slug = Some("kind-aqua-sandpiper".into());
    assert_eq!(machine.title(), "kind-aqua-sandpiper");
    machine.display_name = Some(String::new());
    assert_eq!(machine.title(), "kind-aqua-sandpiper");
    machine.display_name = Some("Build box".into());
    assert_eq!(machine.title(), "Build box");
}

#[test]
fn fleet_names_are_agent_infrastructure() {
    for name in [
        "fs-example-1",
        "fs-other-2",
        "fs-long-exercise-name",
        "sr2-probe",
        "lane-vm-9",
        "fleet-probe",
        "FS-Example-1",
        "  sr2-x  ",
    ] {
        assert!(is_agent_infrastructure(Some(name)), "{name}");
    }
    for name in
        ["brave-teal-otter", "calm-amber-heron", "Cloud Machine 2", "my-fs-box", "fsbox", "sr2", ""]
    {
        assert!(!is_agent_infrastructure(Some(name)), "{name}");
    }
    assert!(!is_agent_infrastructure(None));
}

#[test]
fn the_shown_name_decides_agent_infrastructure() {
    let named = |display: Option<&str>, slug: Option<&str>, id: &str| {
        let mut machine = Machine::new(id, Status::Running);
        machine.display_name = display.map(Into::into);
        machine.slug = slug.map(Into::into);
        facts(&machine, None).agent_infrastructure
    };
    assert!(named(Some("fs-example-1"), None, "vm-1"));
    assert!(!named(Some("quiet-rose-finch"), Some("fs-example-2"), "vm-2"));
    assert!(named(None, Some("sr2-probe"), "vm-3"));
    assert!(!named(None, None, "fs-vm-4"), "no name: the id is not a name");
}

#[test]
fn a_machine_has_run_once_it_ran_or_is_between_runs() {
    for status in [Status::Running, Status::Pausing, Status::Paused, Status::Starting] {
        assert!(facts(&Machine::new("vm", status), None).has_run, "{status:?}");
    }
    for status in
        [Status::Provisioning, Status::Failed, Status::Unknown, Status::Destroyed, Status::Deleting]
    {
        assert!(!facts(&Machine::new("vm", status), None).has_run, "{status:?}");
    }
    let mut failed = Machine::new("vm", Status::Failed);
    failed.running_since = Some(1000.0);
    assert!(facts(&failed, None).has_run);
}

#[test]
fn gone_machines_are_not_listed_to_phones() {
    assert!(facts(&Machine::new("vm", Status::Destroyed), None).gone_for_phones);
    assert!(facts(&Machine::new("vm", Status::Deleting), None).gone_for_phones);
    let mut killing = Machine::new("vm", Status::Running);
    killing.pending_change = Some(Status::Deleting);
    assert!(facts(&killing, None).gone_for_phones);
    assert!(!facts(&Machine::new("vm", Status::Paused), None).gone_for_phones);
}

#[test]
fn the_record_round_trips_as_the_apps_json() {
    let machine = classic(
        r#"{"id":"vm-1","provider":"freestyle","status":"running","displayName":"Box","createdAt":1760000000000,"capabilities":{"exec":true},"error":{"code":"x","message":"y","at":5}}"#,
    );
    let text = serde_json::to_value(&machine).unwrap();
    assert_eq!(text["displayName"], "Box");
    // CloudMachine.swift's CodingKeys: `capabilities` and `error`, as the classic record names them.
    assert_eq!(text["capabilities"]["exec"], true);
    assert_eq!(text["capabilities"]["persistentHome"], false);
    assert_eq!(text["error"]["text"], "y");
    assert!(text.get("declaredCapabilities").is_none() && text.get("lastChangeFailure").is_none());
    assert_eq!(text["pendingMutationID"], Value::Null);
    assert_eq!(serde_json::from_value::<Machine>(text).unwrap(), machine);
}

/// A record in CloudMachine.swift's JSON shape (its CodingKeys: `capabilities`, `error`,
/// `createdByUserId` for `createdBy`) reads with every field, and writes back the same keys.
#[test]
fn a_record_in_the_swift_shape_round_trips() {
    let swift = json!({
        "id": "vm_abcdefghij0123456789", "provider": "cmux-next", "status": "pausing",
        "displayName": "Box", "slug": "kind-aqua", "kind": "dev", "image": "img", "imageVersion": "7",
        "createdAt": 1_760_000_000_000_i64, "createdByUserId": "user_1", "team": "team_1",
        "address": {"ipv4": "10.0.0.7"}, "size": {"name": "m", "cpu": 2, "memoryMb": 4096},
        "capabilities": {"exec": true, "attachTransports": ["cmux-remote"]},
        "pauseReason": "idle", "idlePauseMinutes": 30, "hourlyRateUsd": 0.25,
        "updatedAt": 1_760_000_000_500_i64, "serverRevision": "184467440737095516160",
        "runningSince": 1_760_000_000_000_i64,
        "error": {"code": "cloud.provider.unavailable", "message": "no capacity", "at": 5, "text": "no capacity"},
        "pendingChange": "pausing", "pendingMutationID": "M-1", "servesDesktop": true,
    });
    let machine: Machine = serde_json::from_value(swift).unwrap();
    assert_eq!(machine.created_by.as_deref(), Some("user_1"));
    assert!(machine.declared_capabilities.as_ref().is_some_and(|capabilities| capabilities.exec));
    assert_eq!(
        machine.last_change_failure.as_ref().map(|failure| failure.code.as_str()),
        Some("cloud.provider.unavailable")
    );
    assert_eq!(machine.server_revision.as_deref(), Some("184467440737095516160"));
    assert_eq!(machine.pending_mutation_id.as_deref(), Some("M-1"));
    let written = serde_json::to_value(&machine).unwrap();
    for key in [
        "capabilities",
        "error",
        "createdBy",
        "serverRevision",
        "pendingMutationID",
        "servesDesktop",
    ] {
        assert!(written.get(key).is_some_and(|value| !value.is_null()), "{key} was not written");
    }
    assert_eq!(serde_json::from_value::<Machine>(written).unwrap(), machine);
}
