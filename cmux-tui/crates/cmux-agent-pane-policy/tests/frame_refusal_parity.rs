//! Refusal diagnostics and ticket facts must preserve the transport contract.
use cmux_agent_pane_policy::answers::{answers_rule_violation, breaks_answers_rule};
use cmux_agent_pane_policy::ffi::checked_json;
use cmux_agent_pane_policy::gesture::PermissionOptions;
use cmux_agent_pane_policy::params::{
    breaks_params_rule, params_rule_violation, take_gesture_ticket,
};
use cmux_agent_pane_policy::{
    Checked, FrameState, Gesture, PaneSessions, Refusal, check_frame, policy,
};
use serde_json::{Map, Value, json};

fn frame(method: &str, params: Value) -> Map<String, Value> {
    json!({"jsonrpc":"2.0", "id":7, "method":method, "params":params}).as_object().unwrap().clone()
}

fn options() -> PermissionOptions {
    let options = PermissionOptions::new();
    options.observe(
        json!({
            "method":"_acpmux/permission_pending",
            "params":{"permissionId":"p1", "request":{
                "options":[{"optionId":"yes", "kind":"allow_once"}],
                "toolCall":{"_meta":{"acpmux":{"question":{"items":[{"id":"q1"}]}}}}
            }}
        })
        .as_object()
        .unwrap(),
        None,
    );
    options
}

fn answer(params: Value) -> Option<String> {
    let object = frame(&policy().question_answers.method, params);
    let options = options();
    let cause = answers_rule_violation(&object, &options);
    assert_eq!(breaks_answers_rule(&object, &options), cause.is_some());
    cause
}

fn check(method: &str, params: Value) -> Checked {
    let sessions = PaneSessions::new();
    sessions.add("own");
    let options = options();
    check_frame(
        &Value::Object(frame(method, params)).to_string(),
        &FrameState {
            is_first: false,
            local_app_token: None,
            mode_fields: None,
            remote_wire: false,
            gesture: Gesture::Click,
            scope: &sessions,
            options: &options,
        },
    )
}

#[test]
fn answers_require_a_known_pending_question_without_echoing_values() {
    for (params, expected) in [
        (json!({"answers":{"q1":"secret-answer"}}), "answers without a permissionId"),
        (
            json!({"permissionId":"secret-permission", "answers":{"q1":"secret-answer"}}),
            "answers for no pending question",
        ),
        (
            json!({"permissionId":"p1", "answers":{"secret-question":"secret-answer"}}),
            "answers item not one of the question's",
        ),
    ] {
        assert_eq!(answer(params).as_deref(), Some(expected));
    }
}

#[test]
fn answer_shapes_and_utf8_bounds_have_specific_value_free_causes() {
    let rule = &policy().question_answers;
    for answers in [Value::Null, json!([]), json!({})] {
        assert_eq!(
            answer(json!({"permissionId":"p1", "answers":answers})),
            Some(format!("answers not an object of 1 to {} items", rule.maximum_items)),
        );
    }
    let long_key = "é".repeat(rule.maximum_value_bytes / 2 + 1);
    assert_eq!(
        answer(json!({"permissionId":"p1", "answers":{long_key:"secret-answer"}})),
        Some(format!("answers item key over {} bytes", rule.maximum_value_bytes)),
    );
    for value in [
        json!("é".repeat(rule.maximum_value_bytes / 2 + 1)),
        json!(vec!["secret-answer"; rule.maximum_list_strings + 1]),
        json!({"answers":["secret-answer"], "extra":"secret-extra"}),
        json!(true),
        json!(["secret-answer", 7]),
    ] {
        assert_eq!(
            answer(json!({"permissionId":"p1", "answers":{"q1":value}})).as_deref(),
            Some("answers item value not a bounded string, list or {answers}"),
        );
    }
}

#[test]
fn annotations_take_precedence_and_do_not_expose_note_contents() {
    for (params, expected) in [
        (json!({"annotations":{"q1":{"notes":"secret-note"}}}), "annotations without answers"),
        (json!({"answers":{}, "annotations":{}}), "annotations without a permissionId"),
        (
            json!({"permissionId":"secret-permission", "answers":{}, "annotations":{}}),
            "annotations for no pending question",
        ),
        (
            json!({"permissionId":"p1", "answers":{}, "annotations":{"q1":{"secret-field":"secret-note"}}}),
            "annotations item field other than preview or notes",
        ),
    ] {
        assert_eq!(answer(params).as_deref(), Some(expected));
    }
    let rule = &policy().question_answers;
    for (annotation, expected) in [
        (json!({}), "annotations item not a non-empty object".to_owned()),
        (json!("secret-note"), "annotations item not a non-empty object".to_owned()),
        (
            json!({"notes":"é".repeat(rule.maximum_annotation_bytes / 2 + 1)}),
            format!(
                "annotations item notes not a string of at most {} bytes",
                rule.maximum_annotation_bytes
            ),
        ),
    ] {
        assert_eq!(
            answer(
                json!({"permissionId":"p1", "answers":{"q1":"ok"}, "annotations":{"q1":annotation}})
            ),
            Some(expected),
        );
    }
}

#[test]
fn bounded_answer_variants_and_annotations_remain_accepted() {
    let rule = &policy().question_answers;
    for value in [
        json!("a".repeat(rule.maximum_value_bytes)),
        json!(vec!["ok"; rule.maximum_list_strings]),
        json!({"answers":["ok"]}),
    ] {
        assert_eq!(
            answer(json!({"permissionId":"p1", "answers":{"q1":value},
                "annotations":{"q1":{"preview":"p", "notes":"a".repeat(rule.maximum_annotation_bytes)}}})),
            None,
        );
    }
}

#[test]
fn param_diagnostics_choose_sorted_keys_and_bound_names_without_values() {
    let object = frame("session/prompt", json!({"z":"secret-z", "a":"secret-a"}));
    assert_eq!(params_rule_violation(&object, None).as_deref(), Some("unknown param \"a\""));
    assert!(breaks_params_rule(&object, None));
    let key = "é".repeat(80);
    let object = frame("session/prompt", json!({key:"secret-value"}));
    assert_eq!(
        params_rule_violation(&object, None),
        Some(format!("unknown param \"{}\"", "é".repeat(64)))
    );
    let object = frame("session/prompt", json!({"_meta":{"z":"secret-z", "a":"secret-a"}}));
    assert_eq!(params_rule_violation(&object, None).as_deref(), Some("unknown _meta key \"a\""));
}

#[test]
fn malformed_metadata_survives_stripping_and_is_refused_with_a_cause() {
    for (meta, cause) in [
        (json!("secret-meta"), "_meta is not an object"),
        (json!({"acpmux":"secret-meta"}), "_meta.acpmux is not an object"),
        (json!({"traceparent":"secret-trace"}), "_meta.traceparent is not a W3C traceparent"),
    ] {
        let checked =
            check("session/prompt", json!({"sessionId":"own", "prompt":[], "_meta":meta}));
        let Checked::Refuse { ref refused, ref spend } = checked else {
            panic!("malformed metadata escaped")
        };
        assert_eq!(refused.refusal, Refusal::IntentInvalid);
        assert_eq!(refused.cause.as_deref(), Some(cause));
        assert_eq!(spend, &None);
        let wire = checked_json(checked);
        assert_eq!(wire["cause"], cause);
        assert_eq!(wire["id"], "7");
        assert_eq!(wire["method"], "session/prompt");
        assert!(!wire.to_string().contains("secret-"));
    }
}

#[test]
fn refusal_serialization_preserves_ticket_spending_for_params_and_answers() {
    let ticket_key = &policy().gesture_ticket_key;
    for (meta, answers, cause) in [
        (
            json!({ticket_key:"ticket-1", "extra":"secret-meta"}),
            json!({"q1":"ok"}),
            "_meta holds more than the gesture ticket",
        ),
        (
            json!({ticket_key:"ticket-1"}),
            json!({"q1":true}),
            "answers item value not a bounded string, list or {answers}",
        ),
    ] {
        let checked = check(
            "_acpmux/permission_respond",
            json!({
                "sessionId":"own", "permissionId":"p1", "optionId":"yes", "answers":answers, "_meta":meta
            }),
        );
        let Checked::Refuse { ref refused, ref spend } = checked else {
            panic!("invalid ticketed answer escaped")
        };
        assert_eq!(refused.refusal, Refusal::IntentInvalid);
        assert_eq!(refused.cause.as_deref(), Some(cause));
        assert_eq!(spend.as_deref(), Some("ticket-1"));
        let wire = checked_json(checked);
        assert_eq!(wire["refuse"], Refusal::IntentInvalid.code());
        assert_eq!(wire["cause"], cause);
        assert_eq!(wire["spend"], "ticket-1");
        assert_eq!(wire["method"], "_acpmux/permission_respond");
        assert_eq!(wire["id"], "7");
        assert!(!wire.to_string().contains("secret-meta"));
    }
}

#[test]
fn ticket_meta_facts_sort_names_and_exclude_only_prompt_acpmux() {
    let ticket_key = &policy().gesture_ticket_key;
    for (method, expected) in [
        ("session/prompt", vec!["a", "z"]),
        ("_acpmux/permission_respond", vec!["a", "acpmux", "z"]),
    ] {
        let object = frame(
            method,
            json!({"_meta":{
                ticket_key:"ticket-1", "z":"secret-z", "acpmux":{"promptId":"secret-prompt"}, "a":"secret-a"
            }}),
        );
        let taken = take_gesture_ticket(&object);
        assert_eq!(taken.ticket.as_deref(), Some("ticket-1"));
        assert!(taken.other_meta);
        assert_eq!(taken.other_meta_keys, expected);
        let mut expected_object = object;
        expected_object.get_mut("params").unwrap()["_meta"]
            .as_object_mut()
            .unwrap()
            .remove(ticket_key);
        assert_eq!(taken.object, expected_object);
    }
    let object = frame("session/prompt", json!({"_meta":{"z":"secret-z"}}));
    let taken = take_gesture_ticket(&object);
    assert_eq!(taken.object, object);
    assert_eq!(taken.ticket, None);
    assert!(!taken.other_meta);
    assert!(taken.other_meta_keys.is_empty());
}

#[test]
fn checked_facts_expose_meta_names_and_keep_ticket_off_the_wire() {
    let ticket_key = &policy().gesture_ticket_key;
    let checked = check(
        "session/prompt",
        json!({"sessionId":"own", "prompt":[], "_meta":{
            ticket_key:"ticket-1", "acpmux":{"promptId":"p"},
            "traceparent":"00-11111111111111111111111111111111-2222222222222222-01"
        }}),
    );
    let Checked::Frame { ref frame, ref facts } = checked else {
        panic!("valid ticketed prompt refused")
    };
    assert_eq!(facts.other_meta_keys, ["traceparent"]);
    assert!(facts.other_meta);
    assert_eq!(facts.ticket.as_deref(), Some("ticket-1"));
    assert!(frame["params"]["_meta"].get(ticket_key).is_none());
    assert_eq!(checked_json(checked)["facts"]["other_meta_keys"], json!(["traceparent"]));
}
