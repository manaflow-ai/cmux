use serde_json::json;

use super::*;

#[test]
fn an_ask_starts_at_once_when_delegated_or_granted() {
    assert_eq!(
        open(Opening { delegated: true, granted: true, scoped: true }),
        Opened::Start { always: false }
    );
    assert_eq!(
        open(Opening { delegated: false, granted: true, scoped: true }),
        Opened::Start { always: true }
    );
    assert_eq!(
        open(Opening { delegated: false, granted: false, scoped: true }),
        Opened::Show {
            card: Card {
                state: State::Ask,
                text: Text::Ask,
                answers: vec![Answer::Move, Answer::NotNow, Answer::Always]
            }
        }
    );
    // Signed out: no scope to remember Always in.
    let Opened::Show { card } = open(Opening::default()) else { panic!() };
    assert_eq!(card.answers, vec![Answer::Move, Answer::NotNow]);
}

#[test]
fn a_started_move_says_how_it_started() {
    assert_eq!(
        started(true),
        Card { state: State::Working, text: Text::MovingAlways, answers: vec![Answer::AskFirst] }
    );
    assert_eq!(started(false), Card { state: State::Working, text: Text::Moving, answers: vec![] });
}

#[test]
fn an_ended_move_closes_or_offers_retry() {
    assert_eq!(ended(false, true), None);
    assert_eq!(ended(true, true).unwrap().answers, vec![Answer::Retry, Answer::Dismiss]);
    assert_eq!(
        ended(true, false).unwrap(),
        Card { state: State::Failed, text: Text::Failure, answers: vec![Answer::Dismiss] }
    );
}

#[test]
fn an_unfinished_move_offers_retry() {
    assert_eq!(unfinished(true).text, Text::UnfinishedShow);
    assert_eq!(
        unfinished(false),
        Card {
            state: State::Failed,
            text: Text::UnfinishedMove,
            answers: vec![Answer::Retry, Answer::Dismiss]
        }
    );
    assert_eq!(refused(Text::NoMove).answers, vec![Answer::Dismiss]);
}

fn reply(answer: Answer, offered: bool, scoped: bool, same_scope: bool) -> Reply {
    super::answer(Answered { answer, offered, scoped, same_scope })
}

#[test]
fn an_answer_under_another_scope_moves_nothing() {
    let refused = Reply::Show { card: refused(Text::NoMove) };
    for answer in [Answer::Move, Answer::Retry, Answer::Always] {
        assert_eq!(reply(answer, false, true, false), refused, "{answer:?}");
    }
    // A launch offer keeps its pinned Retry; declining and Ask first always go through.
    assert_eq!(reply(Answer::Retry, true, false, false), Reply::Start { grant: false });
    assert_eq!(reply(Answer::NotNow, false, true, false), Reply::Close { remember: false });
    assert!(matches!(reply(Answer::AskFirst, false, true, false), Reply::AskFirst { .. }));
}

#[test]
fn each_answer_does_its_one_thing() {
    assert_eq!(reply(Answer::Move, false, true, true), Reply::Start { grant: false });
    assert_eq!(reply(Answer::Always, false, true, true), Reply::Start { grant: true });
    assert_eq!(reply(Answer::Always, false, false, true), Reply::Nothing);
    assert_eq!(
        reply(Answer::AskFirst, false, true, true),
        Reply::AskFirst {
            card: Card { state: State::Working, text: Text::Moving, answers: vec![] }
        }
    );
    assert_eq!(reply(Answer::Dismiss, true, false, false), Reply::Close { remember: true });
    assert_eq!(reply(Answer::Dismiss, false, true, true), Reply::Close { remember: false });
}

#[test]
fn an_agent_targets_only_its_own_chat() {
    assert!(own_target(None, None, "t", None));
    assert!(own_target(Some("tab"), Some("t"), "t", None));
    assert!(own_target(Some("tab"), Some("r"), "t", Some("r")));
    assert!(!own_target(Some("tab"), Some("u"), "t", Some("r")));
    assert!(!own_target(Some("tab"), None, "t", None));
    assert!(!own_target(Some("workspace"), Some("t"), "t", None));
}

#[test]
fn the_wire_shapes_are_camel_case() {
    let value = serde_json::to_value(open(Opening { scoped: true, ..Opening::default() })).unwrap();
    assert_eq!(
        value,
        json!({"do": "show", "card": {"state": "ask", "text": "ask", "answers": ["move", "notNow", "always"]}})
    );
    let answered: Answered =
        serde_json::from_value(json!({"answer": "askFirst", "sameScope": true})).unwrap();
    assert_eq!(answered.answer, Answer::AskFirst);
    assert!(answered.same_scope && !answered.offered);
}
