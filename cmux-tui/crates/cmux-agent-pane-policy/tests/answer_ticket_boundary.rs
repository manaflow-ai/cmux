//! Contract tests for the optional Rust boundary, not proof of native host provenance.
use cmux_agent_pane_policy::check::{
    AnswerTicketOrigin, AnswerTicketRequest, AnswerTicketVerifier, GesturePick,
    check_frame_with_answer_tickets,
};
use cmux_agent_pane_policy::gesture::PermissionOptions;
use cmux_agent_pane_policy::{Checked, FrameState, Gesture, PaneSessions, Refusal, check_frame};
use serde_json::{Value, json};

struct HostTicket {
    pick: GesturePick,
    session: String,
    origin: AnswerTicketOrigin,
    valid: bool,
    available: bool,
    attempts: usize,
}
impl AnswerTicketVerifier for HostTicket {
    fn redeem(&mut self, request: AnswerTicketRequest<'_>) -> Option<AnswerTicketOrigin> {
        self.attempts += 1;
        let available = std::mem::replace(&mut self.available, false);
        (available
            && self.valid
            && request.ticket == "native-ticket"
            && request.pick == &self.pick
            && request.session_id == Some(self.session.as_str()))
        .then_some(self.origin)
    }
}
fn answer() -> Value {
    json!({"jsonrpc":"2.0", "id":7, "method":"_acpmux/permission_respond", "params":{
        "sessionId":"own", "permissionId":"p1", "optionId":"yes", "answers":{"choice":"A"},
        "_meta":{"cmuxGesture":"native-ticket"}
    }})
}
fn ticket(frame: &Value, origin: AnswerTicketOrigin) -> HostTicket {
    HostTicket {
        pick: GesturePick::new(frame["method"].as_str(), frame["params"].as_object().unwrap()),
        session: "own".into(),
        origin,
        valid: true,
        available: true,
        attempts: 0,
    }
}
fn with_state(f: impl FnOnce(&FrameState<'_>)) {
    let scope = PaneSessions::new();
    scope.add("own");
    let options = PermissionOptions::new();
    options.observe(json!({"method":"_acpmux/permission_pending", "params":{
        "permissionId":"p1", "request":{
            "options":[{"optionId":"yes", "kind":"allow_once"}, {"optionId":"no", "kind":"reject_once"}],
            "toolCall":{"_meta":{"acpmux":{"question":{"items":[{"id":"choice", "prompt":"Choose"}]}}}}
        }
    }}).as_object().unwrap(), None);
    f(&FrameState {
        is_first: false,
        local_app_token: None,
        mode_fields: None,
        remote_wire: false,
        gesture: Gesture::Key,
        scope: &scope,
        options: &options,
    });
}
fn gesture_refused(checked: Checked) {
    let Checked::Refuse { refused, spend } = checked else { panic!("unverified answer passed") };
    assert_eq!(refused.refusal, Refusal::GestureRequired);
    assert_eq!(spend.as_deref(), Some("native-ticket"));
}

#[test]
fn raw_key_and_ticket_stay_closed_but_verified_click_and_return_are_single_use() {
    with_state(|state| {
        let frame = answer();
        gesture_refused(check_frame(&frame.to_string(), state));
        for origin in [AnswerTicketOrigin::Click, AnswerTicketOrigin::QuestionReturn] {
            let mut host = ticket(&frame, origin);
            let Checked::Frame { frame: checked, facts } =
                check_frame_with_answer_tickets(&frame.to_string(), state, &mut host)
            else {
                panic!("verified native answer refused")
            };
            assert_eq!(facts.redeemed_answer, Some(origin));
            assert!(facts.needs_click && facts.needs_gesture && !facts.free());
            assert_eq!(facts.ticket.as_deref(), Some("native-ticket"));
            assert!(checked["params"].get("_meta").is_none());
            gesture_refused(check_frame_with_answer_tickets(&frame.to_string(), state, &mut host));
            assert_eq!(host.attempts, 2);
        }
    });
}

#[test]
fn failed_host_validation_and_changed_answer_or_session_never_supply_input() {
    with_state(|state| {
        for mismatch in ["approval_or_freshness", "answer", "session", "unknown_ticket"] {
            let frame = answer();
            let mut host = ticket(&frame, AnswerTicketOrigin::QuestionReturn);
            match mismatch {
                "approval_or_freshness" => host.valid = false,
                "answer" => host
                    .pick
                    .params
                    .as_mut()
                    .unwrap()
                    .insert("answers".into(), json!("other-digest"))
                    .map(|_| ())
                    .unwrap(),
                "session" => host.session = "other".into(),
                _ => host.available = false,
            }
            gesture_refused(check_frame_with_answer_tickets(&frame.to_string(), state, &mut host));
            assert!(!host.available);
            assert_eq!(host.attempts, 1);
        }
    });
}

#[test]
fn return_is_not_generic_approval_and_denies_do_not_consume_a_ticket() {
    with_state(|state| {
        for option in ["yes", "unknown", "no"] {
            let mut frame = answer();
            frame["params"].as_object_mut().unwrap().remove("answers");
            frame["params"]["optionId"] = json!(option);
            let mut host = ticket(&frame, AnswerTicketOrigin::QuestionReturn);
            let checked = check_frame_with_answer_tickets(&frame.to_string(), state, &mut host);
            if option == "no" {
                let Checked::Frame { facts, .. } = checked else { panic!("deny refused") };
                assert!(!facts.needs_gesture);
                assert_eq!(facts.redeemed_answer, None);
                assert_eq!(host.attempts, 0);
            } else {
                gesture_refused(checked);
            }
        }
    });
}

#[test]
fn structural_refusal_precedes_verifier_and_preserves_spending() {
    with_state(|state| {
        let mut frame = answer();
        let mut host = ticket(&frame, AnswerTicketOrigin::Click);
        frame["params"]["answers"] = json!({"not-the-question":"private answer"});
        let Checked::Refuse { refused, spend } =
            check_frame_with_answer_tickets(&frame.to_string(), state, &mut host)
        else {
            panic!("invalid answer passed")
        };
        assert_eq!(refused.refusal, Refusal::IntentInvalid);
        assert!(refused.cause.is_some());
        assert_eq!(spend.as_deref(), Some("native-ticket"));
        assert_eq!(host.attempts, 0);
    });
}
