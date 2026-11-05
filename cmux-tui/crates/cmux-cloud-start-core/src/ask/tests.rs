//! Who may answer an agent's Cloud ask.

use super::*;

#[test]
fn only_a_plain_cli_request_with_no_agent_session_is_the_person() {
    assert_eq!(caller(Some("cli"), None), Caller::Person);
    assert_eq!(caller(Some("cli"), Some("")), Caller::Person);
    assert_eq!(caller(Some("cli"), Some("  ")), Caller::Person);
    assert_eq!(caller(Some("cli"), Some("sess-1")), Caller::Agent);
    assert_eq!(caller(Some("mcp"), None), Caller::Agent);
    for origin in [None, Some("script"), Some("remote"), Some("user"), Some("CLI"), Some("")] {
        assert_eq!(caller(origin, None), Caller::Agent, "{origin:?}");
    }
}

#[test]
fn an_agent_is_refused_start_without_the_persons_delegation() {
    assert_eq!(answer(Caller::Agent, false, Choice::Start), Verdict::PersonRequired);
    let agent = caller(Some("cli"), Some("sess-1"));
    assert_eq!(answer(agent, false, Choice::Start), Verdict::PersonRequired);
    assert_eq!(answer(caller(Some("mcp"), None), false, Choice::Start), Verdict::PersonRequired);
}

#[test]
fn the_person_may_start_from_their_own_terminal() {
    assert_eq!(answer(caller(Some("cli"), None), false, Choice::Start), Verdict::Allowed);
    assert_eq!(answer(Caller::Person, true, Choice::Start), Verdict::Allowed);
}

#[test]
fn a_delegated_agent_may_start() {
    assert_eq!(answer(Caller::Agent, true, Choice::Start), Verdict::Allowed);
}

#[test]
fn anyone_may_say_not_now() {
    for caller in [Caller::Person, Caller::Agent] {
        for delegated in [false, true] {
            assert_eq!(answer(caller, delegated, Choice::NotNow), Verdict::Allowed);
        }
    }
}

#[test]
fn an_agents_start_asks_first_unless_delegated() {
    assert!(agent_asks_first(false));
    assert!(!agent_asks_first(true));
}

#[test]
fn choices_read_ids_labels_and_permission_words() {
    for word in ["start", "Start", " START ", "allow", "yes"] {
        assert_eq!(choice(word), Some(Choice::Start), "{word}");
    }
    for word in ["notNow", "Not now", "not-now", "not_now", "deny", "decline", "no"] {
        assert_eq!(choice(word), Some(Choice::NotNow), "{word}");
    }
    for word in ["", "always", "starting", "maybe"] {
        assert_eq!(choice(word), None, "{word}");
    }
}
