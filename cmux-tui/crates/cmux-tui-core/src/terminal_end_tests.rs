use super::*;

fn receipt(outcome: Value) -> Value {
    serde_json::json!({"outcome": outcome, "exited_at": "12", "revision": "3"})
}

/// R41: clients get a typed end; a host loss is never worded as an exit.
#[test]
fn wire_json_types_process_ends_and_host_losses() {
    let exit = |outcome| TerminalExit { outcome, exited_at_ms: 1 };
    assert_eq!(
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Exit { code: 3 })).wire_json(),
        serde_json::json!({"kind": "exited", "code": 3})
    );
    assert_eq!(
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Signal {
            signal: 9,
            core_dumped: false
        }))
        .wire_json(),
        serde_json::json!({"kind": "signaled", "signal": 9, "core_dumped": false})
    );
    for (detail, reason) in [
        ("missing-host-record", "missing_record"),
        ("host-incarnation-mismatch", "incarnation_mismatch"),
        ("host-process-ended-before-adoption", "dead_before_adoption"),
        ("host-exited-during-adoption", "died_during_adoption"),
        ("terminal host ended without a durable exit sidecar", "died_without_exit_status"),
        ("session-shutdown: signal 15", "session_shutdown"),
        ("session-shutdown: exit 1", "session_shutdown"),
        (EXIT_OWNER_GONE, "owner_gone"),
        ("something new", "other"),
    ] {
        let json = TerminalEnd::host_lost(detail).wire_json();
        assert_eq!(json["kind"], "host_lost");
        assert_eq!(json["reason"], reason, "{detail}");
        assert_eq!(json["detail"], detail);
    }
    assert_eq!(TerminalEnd::launch_failed("no pty").wire_json()["kind"], "launch_failed");
}

/// A respawn that found no free PTY stores a stable code word directly
/// after the `respawn-failed` prefix, and the end names that cause in one
/// optional member, from the live end and from the stored receipt. A
/// detail with no code word at that place (each row stored before the
/// code word) gets no member: nothing matches the text of an error.
#[test]
fn wire_json_names_the_pty_cause_of_a_terminal_whose_respawn_launch_failed() {
    let no_pty = "respawn-failed: pty_capacity_exhausted: injected: PTY capacity exhausted";
    let stored = receipt(serde_json::json!({"kind":"unknown","reason":no_pty}));
    for end in [TerminalEnd::host_lost(no_pty), TerminalEnd::from_receipt(Some(&stored))] {
        let json = end.wire_json();
        assert_eq!(json["kind"], "host_lost", "{json}");
        assert_eq!(json["reason"], "restart_failed", "{json}");
        assert_eq!(json["detail"], no_pty, "{json}");
        assert_eq!(
            json["launch_failure"], "pty_capacity_exhausted",
            "the end of a respawn that found no free PTY does not name that cause: {json}"
        );
    }
    for detail in [
        // Rows stored before the code word: the same cause, or another one.
        "respawn-failed: injected: PTY capacity exhausted",
        "respawn-failed: spawn the terminal host: No such file or directory",
        // The code word names the cause only directly after the prefix.
        "respawn-failed: spawn the terminal host: pty_capacity_exhausted: x",
        "respawn-failed: pty_capacity_exhausted_more: x",
        "restart-exhausted: pty_capacity_exhausted: x",
        "pty_capacity_exhausted: x",
    ] {
        let json = TerminalEnd::host_lost(detail).wire_json();
        assert_eq!(json["kind"], "host_lost", "{detail}");
        assert!(json.get("launch_failure").is_none(), "{detail}: {json}");
    }
    // The writer of the detail gives another failed launch no code word.
    let other = anyhow::anyhow!("spawn the terminal host: No such file or directory");
    let plain = TerminalEnd::host_lost(respawn_failed_detail(&other, false)).wire_json();
    assert_eq!(plain["reason"], "restart_failed", "{plain}");
    assert!(plain.get("launch_failure").is_none(), "{plain}");
}

#[test]
fn persisted_exit_and_signal_receipts_are_process_ends() {
    for outcome in [
        serde_json::json!({"kind":"exit","code":0}),
        serde_json::json!({"kind":"signal","signal":15,"core_dumped":false}),
    ] {
        let end = TerminalEnd::from_receipt(Some(&receipt(outcome)));
        assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{end:?}");
        assert_eq!(end.exit().exited_at_ms, 12);
        assert!(end.detach_proof().is_some());
    }
}

#[test]
fn persisted_unknown_or_missing_receipts_are_host_losses() {
    let unknown = receipt(serde_json::json!({
        "kind":"unknown","reason":"host-process-ended-before-adoption",
    }));
    for end in [
        TerminalEnd::from_receipt(Some(&unknown)),
        TerminalEnd::from_receipt(None),
        TerminalEnd::from_receipt(Some(&serde_json::json!({"reason":"legacy"}))),
    ] {
        assert!(matches!(end, TerminalEnd::HostLost(_)), "{end:?}");
        assert!(end.detach_proof().is_none());
    }
}

/// cx-6so.49 L1: a replacement host that adopted a running session saw
/// it end without a status; that receipt is a process end, while any
/// other unknown reason stays a host loss.
#[test]
fn persisted_exit_unobserved_receipt_is_a_process_end() {
    let unobserved = receipt(serde_json::json!({"kind":"unknown","reason":"exit-unobserved"}));
    let end = TerminalEnd::from_receipt(Some(&unobserved));
    assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{end:?}");
    assert_eq!(end.exit().exited_at_ms, 12);
    assert!(end.detach_proof().is_some());
    assert_eq!(end.wire_json()["kind"], "exited");
    let near = receipt(serde_json::json!({"kind":"unknown","reason":"exit-unobserved: x"}));
    assert!(matches!(TerminalEnd::from_receipt(Some(&near)), TerminalEnd::HostLost(_)));
}

#[test]
fn a_host_loss_never_yields_a_detach_proof() {
    let real = TerminalExit::now(TerminalExitOutcome::Exit { code: 1 });
    assert!(TerminalEnd::ProcessEnded(real).detach_proof().is_some());
    // An older host's Exit frame without a status is still a real end.
    assert!(TerminalEnd::ProcessEnded(TerminalExit::unknown("omitted")).detach_proof().is_some());
    assert!(TerminalEnd::host_lost("lost").detach_proof().is_none());
    // The owner abandoning its own launch detaches like a close.
    assert!(TerminalEnd::launch_failed("spawn").detach_proof().is_some());
}

/// Every key of `value` is a field of the schema object `name`, every required field is there,
/// a null only where the schema allows it, and an enum or object field holds what its schema
/// type declares: `end` on a tab is typed as `TerminalTabEnd` in `sdk-schema.json`, which the
/// generated Swift mirror reads.
fn schema_problems(
    types: &serde_json::Map<String, Value>,
    name: &str,
    value: &Value,
) -> Vec<String> {
    let ty = &types[name];
    let fields = ty["fields"].as_object().unwrap();
    let mut problems = Vec::new();
    let object = value.as_object().unwrap();
    for (key, item) in object {
        let Some(field) = fields.get(key) else {
            problems.push(format!("{name}.{key}: not in the schema"));
            continue;
        };
        if item.is_null() {
            if field["nullable"] != true {
                problems.push(format!("{name}.{key}: null but not nullable"));
            }
            continue;
        }
        let field_type = &field["type"];
        match field_type["kind"].as_str().unwrap() {
            "ref" => {
                let target = field_type["name"].as_str().unwrap();
                match types[target]["kind"].as_str().unwrap() {
                    "enum" if !types[target]["values"].as_array().unwrap().contains(item) => {
                        problems.push(format!("{name}.{key}: {item} is not a {target}"));
                    }
                    "object" => problems.extend(schema_problems(types, target, item)),
                    _ => {}
                }
            }
            "scalar" => {
                let ok = match field_type["name"].as_str().unwrap() {
                    "string" => item.is_string(),
                    "boolean" => item.is_boolean(),
                    _ => item.is_i64(),
                };
                if !ok {
                    problems.push(format!("{name}.{key}: {item} is not a {}", field_type["name"]));
                }
            }
            kind => problems.push(format!("{name}.{key}: schema kind {kind} is not checked here")),
        }
    }
    for (key, field) in fields {
        if field["presence"] == "required" && !object.contains_key(key) {
            problems.push(format!("{name}.{key}: required but missing"));
        }
    }
    problems
}

#[test]
fn every_end_and_its_cause_is_what_the_sdk_schema_declares() {
    let schema: Value =
        serde_json::from_str(include_str!("../../../spec/sdk-schema.json")).unwrap();
    let types = schema["types"].as_object().unwrap();
    let exit = |outcome| TerminalExit { outcome, exited_at_ms: 1 };
    let no_pty = anyhow::anyhow!("no free pty");
    let mut ends = vec![
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Exit { code: -1 })),
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Signal {
            signal: 9,
            core_dumped: true,
        })),
        TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Unknown { reason: "gone".into() })),
        TerminalEnd::launch_failed("no pty"),
        TerminalEnd::host_lost(respawn_failed_detail(&no_pty, true)),
        TerminalEnd::host_lost(respawn_failed_detail(&no_pty, false)),
        TerminalEnd::host_lost(format!("{RESPAWN_EXHAUSTED_DETAIL}: 3 in 60s")),
    ];
    for detail in [
        "missing-host-record",
        "host-incarnation-mismatch",
        "host-process-ended-before-adoption",
        "host-exited-during-adoption",
        "terminal host ended without a durable exit sidecar",
        "terminal exit receipt is missing",
        "unadoptable-host-ended",
        EXIT_OWNER_GONE,
        "session-shutdown: signal 15",
        "something new",
    ] {
        ends.push(TerminalEnd::host_lost(detail));
    }
    let signal = serde_json::json!({"signal": 15, "sender_pid": 84954, "sender": {"name": "bash"}});
    let unknown_sender = serde_json::json!({"signal": 1, "sender_pid": null});
    let crash = serde_json::json!({"message": "boom"});
    let causes = [
        crate::terminal_loss_cause::cause_summary(std::slice::from_ref(&signal), None),
        crate::terminal_loss_cause::cause_summary(&[unknown_sender], Some(&crash)),
        crate::terminal_loss_cause::cause_summary(&[], Some(&crash)),
    ];
    let mut problems = Vec::new();
    for end in &ends {
        for cause in &causes {
            let mut json = end.wire_json();
            if json["kind"] == "host_lost" {
                json.as_object_mut().unwrap().insert("cause".into(), cause.clone().unwrap());
            }
            problems.extend(
                schema_problems(types, "TerminalTabEnd", &json)
                    .into_iter()
                    .map(|p| format!("{json}: {p}")),
            );
        }
    }
    assert!(
        problems.is_empty(),
        "a tab's end is not what cmux-tui/spec/sdk-schema.json declares (`TerminalTabEnd`); change \
         the schema with the serializer (the Swift mirror is generated from it):\n{}",
        problems.join("\n")
    );
}
