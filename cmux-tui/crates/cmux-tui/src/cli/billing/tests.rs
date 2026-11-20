use serde_json::{Value, json};

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn parsed(words: &[&str]) -> Result<Invocation, UsageError> {
    let all = args(words);
    let rest = split(&all).expect("a billing command");
    parse(rest)
}

fn checkout(plan: Plan, team: Option<&str>, open: OpenMode) -> Invocation {
    Invocation::Owned(Verb::Checkout { plan, team: team.map(str::to_owned), open })
}

#[test]
fn checkout_defaults_to_pro_and_opens_where_the_app_decides() {
    assert_eq!(
        parsed(&["billing", "checkout"]).unwrap(),
        checkout(Plan::Pro, None, OpenMode::Auto)
    );
    assert_eq!(
        parsed(&["billing", "checkout", "--plan", "max"]).unwrap(),
        checkout(Plan::Max, None, OpenMode::Auto)
    );
    assert_eq!(
        parsed(&["billing", "checkout", "--plan=pro", "--open", "default"]).unwrap(),
        checkout(Plan::Pro, None, OpenMode::Default)
    );
    assert_eq!(
        parsed(&["billing", "checkout", "--open=cmux"]).unwrap(),
        checkout(Plan::Pro, None, OpenMode::Cmux)
    );
    assert_eq!(
        parsed(&["billing", "checkout", "--no-open"]).unwrap(),
        checkout(Plan::Pro, None, OpenMode::None)
    );
    // `cmux billing` alone and `cmux billing upgrade` are the checkout too.
    assert_eq!(
        parsed(&["billing", "upgrade", "--plan", "max"]).unwrap(),
        checkout(Plan::Max, None, OpenMode::Auto)
    );
    assert!(split(&args(&["workspace", "list"])).is_none());
}

#[test]
fn plus_checks_out_as_the_go_plan_id() {
    assert_eq!(
        parsed(&["billing", "checkout", "--plan", "plus"]).unwrap(),
        checkout(Plan::Plus, None, OpenMode::Auto)
    );
    // Web billing keeps the historical `go` id for Plus; it is accepted as an alias.
    assert_eq!(
        parsed(&["billing", "checkout", "--plan", "go"]).unwrap(),
        checkout(Plan::Plus, None, OpenMode::Auto)
    );
    assert_eq!(Plan::Plus.id(), "go");
    assert_eq!(plan_name("go"), "Plus");
}

#[test]
fn team_checkout_needs_a_team() {
    assert_eq!(
        parsed(&["billing", "checkout", "--plan", "team", "--team", "t_1"]).unwrap(),
        checkout(Plan::Team, Some("t_1"), OpenMode::Auto)
    );
    assert!(parsed(&["billing", "checkout", "--plan", "team"]).is_err());
    assert!(parsed(&["billing", "checkout", "--plan", "enterprise"]).is_err());
    assert!(parsed(&["billing", "checkout", "--open", "safari"]).is_err());
    assert!(parsed(&["billing", "checkout", "pro"]).is_err());
}

#[test]
fn status_portal_and_help() {
    assert_eq!(
        parsed(&["billing", "status"]).unwrap(),
        Invocation::Owned(Verb::Status { team: None })
    );
    assert_eq!(
        parsed(&["billing", "portal", "--team", "t_2", "--no-open"]).unwrap(),
        Invocation::Owned(Verb::Portal { team: Some("t_2".into()), open: OpenMode::None })
    );
    assert_eq!(parsed(&["billing", "--help"]).unwrap(), Invocation::Help);
    assert_eq!(parsed(&["billing", "checkout", "-h"]).unwrap(), Invocation::Help);
    assert_eq!(parsed(&["billing", "help"]).unwrap(), Invocation::Help);
    assert!(parsed(&["billing", "refund"]).is_err());
}

#[test]
fn each_verb_sends_one_app_method_with_its_params() {
    let (method, params) = request(&Verb::Checkout {
        plan: Plan::Team,
        team: Some("t_9".into()),
        open: OpenMode::Default,
    });
    assert_eq!(method, "billing.checkout");
    assert_eq!(Value::Object(params), json!({"plan": "team", "teamId": "t_9", "open": "default"}));
    let (method, params) =
        request(&Verb::Checkout { plan: Plan::Pro, team: None, open: OpenMode::Auto });
    assert_eq!(method, "billing.checkout");
    assert_eq!(Value::Object(params), json!({"plan": "pro", "open": "auto"}));
    let (method, params) = request(&Verb::Status { team: None });
    assert_eq!((method, Value::Object(params)), ("billing.status", json!({})));
    let (method, params) = request(&Verb::Portal { team: None, open: OpenMode::None });
    assert_eq!((method, Value::Object(params)), ("billing.portal", json!({"open": "none"})));
}

#[test]
fn checkout_text_says_where_the_page_opened_and_never_that_anything_was_bought() {
    let english = &crate::localization::catalog_for_locale("en").billing;
    let cmux = checkout_text(
        &json!({"url": "https://checkout.stripe.com/c/pay/cs_test_1", "plan": "pro", "flow": "checkout", "mode": "test", "opened_in": "cmux", "link_session": true}),
        english,
    );
    assert!(cmux.contains("cmux browser"), "{cmux}");
    assert!(cmux.contains("Link"), "{cmux}");
    assert!(cmux.contains("test mode"), "{cmux}");
    assert!(cmux.ends_with("https://checkout.stripe.com/c/pay/cs_test_1"), "{cmux}");
    let default = checkout_text(
        &json!({"url": "https://checkout.stripe.com/c/pay/cs_test_2", "plan": "max", "flow": "checkout", "mode": "test", "opened_in": "default", "link_session": false}),
        english,
    );
    assert!(default.contains("default browser"), "{default}");
    assert!(default.contains("Max"), "{default}");
    let none = checkout_text(
        &json!({"url": "https://x.test/p", "plan": "pro", "flow": "checkout", "mode": "live", "opened_in": "none"}),
        english,
    );
    assert_eq!(none, "https://x.test/p");
    let active = checkout_text(
        &json!({"url": "https://cmux.com/welcome", "plan": "pro", "flow": "already_active", "opened_in": "none"}),
        english,
    );
    assert!(active.contains("already"), "{active}");
    for text in [cmux, default, active] {
        assert!(
            !text.to_lowercase().contains("purchased")
                && !text.to_lowercase().contains("charged you"),
            "{text}"
        );
    }
}

#[test]
fn japanese_strings_cover_every_message() {
    let english = &crate::localization::catalog_for_locale("en").billing;
    let japanese = &crate::localization::catalog_for_locale("ja").billing;
    assert_ne!(english.usage, japanese.usage);
    assert_ne!(english.opened_cmux_link, japanese.opened_cmux_link);
    assert_ne!(english.opened_default, japanese.opened_default);
    assert_ne!(english.plan_required_team, japanese.plan_required_team);
}
