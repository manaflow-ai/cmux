//! `question` parts and the `question.answer` op (question.rs).

use serde_json::json;

use super::*;

const ALICE: &str = "user_local";
const MUX: &str = "agent_mux";
const PHONE: &str = "remote_inst1";
const NOW: &str = "2026-10-07T12:00:00.000Z";

fn participant(id: &str, kind: ParticipantKind, name: &str, person: Option<&str>) -> Participant {
    Participant {
        id: id.to_string(),
        kind,
        display_name: name.to_string(),
        agent_class: (kind == ParticipantKind::Agent).then_some(AgentClass::Mux),
        acp_session: None,
        person: person.map(str::to_string),
    }
}

fn head() -> ConversationHead {
    create(&CreateRequest {
        id: "conv_Q",
        actor: ALICE,
        title: "mux",
        participants: &[
            participant(ALICE, ParticipantKind::Human, "Lawrence", None),
            participant(MUX, ParticipantKind::Agent, "Chief", None),
            participant(PHONE, ParticipantKind::Human, "Lawrence's iPhone", Some(ALICE)),
        ],
        now: NOW,
    })
    .unwrap()
}

fn question(multi: bool) -> Question {
    serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1", "agent": "Chief",
        "items": [{"id": "q0", "header": "Auth", "prompt": "Which auth method?", "multi_select": multi,
                   "options": [{"id": "oauth", "label": "OAuth", "detail": "Delegated"},
                               {"id": "keys", "label": "API keys", "preview": {"text": "KEY=..."}}]}]
    }))
    .unwrap()
}

fn run(
    head: &ConversationHead,
    actor: &str,
    op: &Op,
    target: Option<&Message>,
) -> Result<Commit, Reject> {
    apply(
        head,
        &OpRequest {
            actor,
            idempotency_key: "k1",
            op,
            now: NOW,
            new_message_id: "msg_1",
            target,
            reply_target: None,
            last_message: target,
        },
    )
}

/// The Chief posts a question; returns the head and the stored message.
fn posted(multi: bool) -> (ConversationHead, Message) {
    let op = Op::MessageSend {
        client_msg_id: "k1".into(),
        parts: vec![Part::Question(question(multi))],
        reply_to: None,
    };
    let commit = run(&head(), MUX, &op, None).unwrap();
    (commit.head, commit.message.unwrap())
}

fn answer_op(selections: serde_json::Value) -> Op {
    serde_json::from_value(
        json!({"kind": "question.answer", "message_id": "msg_1", "part_index": 0,
                                  "answer": {"selections": selections}}),
    )
    .unwrap()
}

fn state(message: &Message) -> &QuestionState {
    match &message.parts[0] {
        Part::Question(question) => &question.state,
        other => panic!("not a question: {other:?}"),
    }
}

#[test]
fn wire_shape_is_a_tagged_part_with_snake_case_fields() {
    let part = Part::Question(question(false));
    let value = serde_json::to_value(&part).unwrap();
    assert_eq!(value["type"], "question");
    assert_eq!(value["state"], json!({"kind": "pending"}));
    assert_eq!(value["items"][0]["allows_other"], true);
    assert_eq!(
        value["items"][0]["options"][1]["preview"],
        json!({"text": "KEY=...", "format": "monospace"})
    );
    assert_eq!(serde_json::from_value::<Part>(value).unwrap(), part);
}

#[test]
fn only_an_agent_posts_a_question() {
    let op = Op::MessageSend {
        client_msg_id: "k1".into(),
        parts: vec![Part::Question(question(false))],
        reply_to: None,
    };
    assert_eq!(run(&head(), ALICE, &op, None).unwrap_err(), Reject::InvalidParts);
    assert!(run(&head(), MUX, &op, None).is_ok());
}

#[test]
fn a_posted_question_must_be_pending_and_well_formed() {
    let mut answered = question(false);
    answered.state = QuestionState::Cancelled;
    let mut duplicate = question(false);
    duplicate.items[0].options[1].id = "oauth".into();
    let mut empty = question(false);
    empty.items.clear();
    let mut no_choice = question(false);
    no_choice.items[0].options.clear();
    no_choice.items[0].allows_other = false;
    for bad in [answered, duplicate, empty, no_choice] {
        let op = Op::MessageSend {
            client_msg_id: "k1".into(),
            parts: vec![Part::Question(bad)],
            reply_to: None,
        };
        assert_eq!(run(&head(), MUX, &op, None).unwrap_err(), Reject::InvalidParts);
    }
}

#[test]
fn a_person_answers_once_and_the_owner_stamps_the_respondent() {
    let (head, message) = posted(false);
    let commit =
        run(&head, ALICE, &answer_op(json!({"q0": {"option_ids": ["keys"]}})), Some(&message))
            .unwrap();
    let answered = commit.message.unwrap();
    let QuestionState::Answered { answer } = state(&answered) else { panic!("not answered") };
    assert_eq!(answer.selections["q0"].option_ids, ["keys"]);
    assert_eq!(answer.answered_at.as_deref(), Some(NOW));
    let respondent = answer.respondent.as_ref().unwrap();
    assert_eq!((respondent.participant.as_str(), respondent.remote), (ALICE, false));
    assert!(matches!(commit.change, Change::MessageUpdated { .. }));
    // A second answer is refused.
    let again = run(
        &commit.head,
        ALICE,
        &answer_op(json!({"q0": {"option_ids": ["oauth"]}})),
        Some(&answered),
    );
    assert_eq!(again.unwrap_err(), Reject::QuestionClosed);
}

#[test]
fn a_paired_device_answers_as_its_person_and_names_the_device() {
    let (head, message) = posted(false);
    let commit =
        run(&head, PHONE, &answer_op(json!({"q0": {"other": "  mTLS "}})), Some(&message)).unwrap();
    let QuestionState::Answered { answer } = state(commit.message.as_ref().unwrap()) else {
        panic!()
    };
    let respondent = answer.respondent.as_ref().unwrap();
    assert_eq!(respondent.participant, ALICE);
    assert_eq!(respondent.device.as_deref(), Some("Lawrence's iPhone"));
    assert!(respondent.remote);
    assert_eq!(answer.selections["q0"].other.as_deref(), Some("mTLS"));
}

#[test]
fn an_agent_never_answers() {
    let (head, message) = posted(false);
    let result =
        run(&head, MUX, &answer_op(json!({"q0": {"option_ids": ["keys"]}})), Some(&message));
    assert_eq!(result.unwrap_err(), Reject::HumanOnly);
}

#[test]
fn invalid_answers_are_refused() {
    let (head, message) = posted(false);
    for selections in [
        json!({}),
        json!({"q0": {}}),
        json!({"q0": {"option_ids": ["nope"]}}),
        json!({"q0": {"option_ids": ["keys", "oauth"]}}),
        json!({"q0": {"option_ids": ["keys"], "other": "x"}}),
        json!({"q0": {"option_ids": ["keys", "keys"]}}),
        json!({"q0": {"option_ids": ["keys"]}, "q9": {"option_ids": ["keys"]}}),
    ] {
        let result = run(&head, ALICE, &answer_op(selections.clone()), Some(&message));
        assert_eq!(result.unwrap_err(), Reject::InvalidAnswer, "{selections}");
    }
}

#[test]
fn multi_select_keeps_the_items_option_order() {
    let (head, message) = posted(true);
    let op = answer_op(json!({"q0": {"option_ids": ["keys", "oauth"], "other": "SSO"}}));
    let commit = run(&head, ALICE, &op, Some(&message)).unwrap();
    let QuestionState::Answered { answer } = state(commit.message.as_ref().unwrap()) else {
        panic!()
    };
    assert_eq!(answer.selections["q0"].option_ids, ["oauth", "keys"]);
    assert_eq!(answer.selections["q0"].other.as_deref(), Some("SSO"));
}

#[test]
fn the_author_may_only_cancel_a_pending_question_by_edit() {
    let (head, message) = posted(false);
    let mut cancelled = question(false);
    cancelled.state = QuestionState::Cancelled;
    let cancel =
        Op::MessageEdit { message_id: "msg_1".into(), parts: vec![Part::Question(cancelled)] };
    let commit = run(&head, MUX, &cancel, Some(&message)).unwrap();
    assert_eq!(state(commit.message.as_ref().unwrap()), &QuestionState::Cancelled);

    let mut reworded = question(false);
    reworded.items[0].prompt = "Something else?".into();
    let reword =
        Op::MessageEdit { message_id: "msg_1".into(), parts: vec![Part::Question(reworded)] };
    assert_eq!(run(&head, MUX, &reword, Some(&message)).unwrap_err(), Reject::InvalidParts);

    let answered: Question = serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1", "agent": "Chief",
        "items": question(false).items,
        "state": {"kind": "answered", "answer": {"selections": {"q0": {"option_ids": ["keys"]}}}}
    }))
    .unwrap();
    let forge =
        Op::MessageEdit { message_id: "msg_1".into(), parts: vec![Part::Question(answered)] };
    assert_eq!(run(&head, MUX, &forge, Some(&message)).unwrap_err(), Reject::InvalidParts);

    let drop = Op::MessageEdit {
        message_id: "msg_1".into(),
        parts: vec![Part::Text { text: "gone".into(), runs: None }],
    };
    assert_eq!(run(&head, MUX, &drop, Some(&message)).unwrap_err(), Reject::InvalidParts);
}

#[test]
fn answering_a_non_question_part_is_refused() {
    let send = Op::MessageSend {
        client_msg_id: "k1".into(),
        parts: vec![Part::Text { text: "hi".into(), runs: None }],
        reply_to: None,
    };
    let commit = run(&head(), MUX, &send, None).unwrap();
    let message = commit.message.unwrap();
    let result = run(
        &commit.head,
        ALICE,
        &answer_op(json!({"q0": {"option_ids": ["keys"]}})),
        Some(&message),
    );
    assert_eq!(result.unwrap_err(), Reject::InvalidPartIndex);
}

#[test]
fn search_matches_the_first_prompt() {
    let (_, message) = posted(false);
    assert_eq!(message_text(&message), "Which auth method?");
}

#[test]
fn every_reject_code_is_listed() {
    for code in ["human_only", "question_closed", "invalid_answer"] {
        assert!(Reject::ALL.iter().any(|reject| reject.code() == code), "{code}");
    }
}
