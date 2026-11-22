//! The "Computer use can act as me" grant (src/act_as_me.rs): off by
//! default, no agent path turns it on, one turn-off revokes it, and posted
//! input grants only Send, Retry and Approve while it is on.

use cmux_agent_pane_policy::act_as_me::{
    ActAsMe, Driver, GrantSource, Holder, Verdict, covers, decide, let_through_record,
};
use cmux_agent_pane_policy::policy;

/// Every source an agent on the Mac could use.
const AGENT_PATHS: [GrantSource; 7] = [
    GrantSource::PostedInput,
    GrantSource::Rpc,
    GrantSource::Cli,
    GrantSource::Mcp,
    GrantSource::Page,
    GrantSource::Defaults,
    GrantSource::ConfigFile,
];

#[test]
fn it_is_off_by_default() {
    let state = ActAsMe::default();
    assert!(!state.is_on());
    assert_eq!(state.holder(), None);
    assert_eq!(decide(state, "session/prompt", false), Verdict::Refused);
}

#[test]
fn no_agent_path_turns_it_on() {
    for source in AGENT_PATHS {
        let mut state = ActAsMe::default();
        let refused = state.turn_on(source).expect_err(source.name());
        assert_eq!(refused.source, source);
        assert!(refused.message().contains(source.name()));
        assert!(!source.may_grant(), "{}", source.name());
        assert_eq!(state, ActAsMe::default(), "{} changed the state", source.name());
        assert_eq!(decide(state, "session/prompt", false), Verdict::Refused);
    }
}

#[test]
fn an_agent_path_cannot_turn_a_revoked_grant_back_on() {
    let mut state = ActAsMe::default();
    state.turn_on(GrantSource::PersonClick).unwrap();
    state.turn_off();
    for source in AGENT_PATHS {
        assert!(state.turn_on(source).is_err());
        assert!(!state.is_on(), "{} turned it back on", source.name());
    }
}

#[test]
fn the_persons_click_and_a_managed_profile_turn_it_on() {
    let mut state = ActAsMe::default();
    assert_eq!(state.turn_on(GrantSource::PersonClick), Ok(Holder::Person));
    assert_eq!(state.holder(), Some(Holder::Person));
    let mut managed = ActAsMe::default();
    assert_eq!(managed.turn_on(GrantSource::ManagedProfile), Ok(Holder::Managed));
    assert_eq!(managed.holder(), Some(Holder::Managed));
}

#[test]
fn one_turn_off_revokes_it() {
    let mut state = ActAsMe::default();
    state.turn_on(GrantSource::PersonClick).unwrap();
    state.turn_off();
    assert!(!state.is_on());
    assert_eq!(decide(state, "session/prompt", false), Verdict::Refused);
}

#[test]
fn turning_off_holds_a_managed_grant_off_until_the_persons_click() {
    let mut state = ActAsMe::default();
    state.turn_on(GrantSource::ManagedProfile).unwrap();
    state.turn_off();
    assert!(!state.is_on());
    // The profile read again (a settings reload) does not undo the person's turn-off.
    state.turn_on(GrantSource::ManagedProfile).unwrap();
    assert!(!state.is_on());
    state.turn_on(GrantSource::PersonClick).unwrap();
    assert_eq!(state.holder(), Some(Holder::Person));
    state.turn_off();
    state.managed_removed();
    assert!(!state.is_on());
}

#[test]
fn it_covers_send_retry_and_approve_only() {
    assert!(covers("session/prompt"));
    assert!(covers("_acpmux/queue_approve"));
    assert_eq!(policy().act_as_me_covers.len(), 2);
    let mut state = ActAsMe::default();
    state.turn_on(GrantSource::PersonClick).unwrap();
    assert_eq!(decide(state, "session/prompt", false), Verdict::ActsAsPerson(Holder::Person));
    assert_eq!(
        decide(state, "_acpmux/queue_approve", false),
        Verdict::ActsAsPerson(Holder::Person)
    );
    // Every other method that needs a gesture stays the person's alone.
    for method in policy().gesture_rules.keys() {
        if method == "session/prompt" || method == "_acpmux/queue_approve" {
            continue;
        }
        assert!(!covers(method), "{method}");
        assert_eq!(decide(state, method, false), Verdict::Refused, "{method}");
    }
    for method in ["_acpmux/permission_respond", "acp.trust.set", "session/set_mode", "session/new"]
    {
        assert_eq!(decide(state, method, false), Verdict::Refused, "{method}");
    }
}

#[test]
fn the_persons_own_input_is_judged_as_always() {
    assert_eq!(decide(ActAsMe::default(), "acp.trust.set", true), Verdict::Person);
    assert_eq!(decide(ActAsMe::default(), "session/prompt", true), Verdict::Person);
}

#[test]
fn a_let_through_records_the_driver() {
    let driver = Driver {
        pid: Some(4242),
        path: Some("/Applications/cmux.app/Contents/Helpers/cua-driver".into()),
        bundle_id: Some("com.manaflow.cua".into()),
        cua_session: None,
    };
    let record = let_through_record("session/prompt", Holder::Managed, &driver);
    assert_eq!(record["event"], "act_as_me.let_through");
    assert_eq!(record["method"], "session/prompt");
    assert_eq!(record["holder"], "managed");
    assert_eq!(record["driver"]["pid"], 4242);
    assert_eq!(record["driver"]["bundleId"], "com.manaflow.cua");
    assert!(record["driver"].get("cuaSession").is_some_and(serde_json::Value::is_null));
}
