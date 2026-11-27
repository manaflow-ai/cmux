//! Parity with `HomeNewMessageDraftTests` and `ContactAddressTests`: addresses, tokens, suggestions.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("compose.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn contacts() -> Value {
    json!([
        {"id": "ada", "name": "Ada Lovelace", "source": "team"},
        {"id": "alan", "name": "Alan Turing", "source": "connection"},
        {"id": "grace", "name": "Grace Hopper", "source": "team"},
        {"id": "chief-1", "name": "Chief", "source": "agent"},
    ])
}

fn address(text: &str) -> Value {
    op("address.parse", json!({"text": text}))
}

fn ids(list: &Value) -> Vec<String> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|r| r["contact"]["id"].as_str().or(r["id"].as_str()).unwrap_or("").to_owned())
        .collect()
}

#[test]
fn emails_normalize_and_bad_ones_are_refused() {
    assert_eq!(
        address(" Austin@Manaflow.ai "),
        json!({"kind": "email", "value": "austin@manaflow.ai"})
    );
    for bad in ["a@b", "@x.com", "a@.com", "a@x..com", "a b@x.com", "a@x.c0m", ".a@x.com"] {
        assert_eq!(address(bad), Value::Null, "{bad}");
    }
}

#[test]
fn phones_take_the_calling_code() {
    assert_eq!(address("(415) 555-0134")["value"], "+14155550134");
    assert_eq!(address("1 415 555 0134")["value"], "+14155550134");
    assert_eq!(address("+44 20 7946 0958")["value"], "+442079460958");
    assert_eq!(address("0044 20 7946 0958")["value"], "+442079460958");
    for bad in ["555-0134", "+1 415 555", "415-555-0134x9", "4+15", "hello"] {
        assert_eq!(address(bad), Value::Null, "{bad}");
    }
}

#[test]
fn suggestions_rank_word_starts_first() {
    let s = |q: &str| {
        ids(&op("draft.suggestions", json!({"draft": {"query": q}, "contacts": contacts()})))
    };
    assert_eq!(s("a"), ["ada", "alan", "grace"]);
    assert_eq!(s("tur"), ["alan"]);
    assert_eq!(s("chi"), ["chief-1"]);
    assert!(s("").is_empty());
}

#[test]
fn suggestions_leave_out_chosen() {
    let draft = op(
        "draft.add",
        json!({"recipient": {"kind": "contact", "contact": contacts()[0]}}),
    )["draft"]
        .clone();
    let drafted = json!({"tokens": draft["tokens"], "query": "a"});
    assert_eq!(
        ids(&op("draft.suggestions", json!({"draft": drafted, "contacts": contacts()}))),
        ["alan", "grace"]
    );
}

#[test]
fn commit_makes_a_token_or_an_invalid_one() {
    let done = op("draft.commit", json!({"draft": {"query": "ada,"}, "contacts": contacts()}));
    assert_eq!(done["changed"], true);
    assert_eq!(done["draft"]["tokens"][0]["text"], "Ada Lovelace");
    assert_eq!(done["draft"]["query"], "");
    let nobody = op("draft.commit", json!({"draft": {"query": "zed"}, "contacts": contacts()}));
    assert_eq!(nobody["draft"]["tokens"][0], json!({"text": "zed"}));
    let state = op("draft.state", json!({"draft": nobody["draft"]}));
    assert_eq!(state["hasInvalidTokens"], true);
    assert_eq!(state["sendBlocker"], json!({"kind": "unknownRecipient", "text": "zed"}));
    let empty = op("draft.commit", json!({"draft": {"query": " , "}, "contacts": contacts()}));
    assert_eq!(empty["changed"], false);
}

#[test]
fn commit_twice_adds_once() {
    let once = op(
        "draft.commit",
        json!({"draft": {"query": "Ada Lovelace"}, "contacts": contacts()}),
    )["draft"]
        .clone();
    let again = json!({"tokens": once["tokens"], "query": "ada"});
    let twice = op("draft.commit", json!({"draft": again, "contacts": contacts()}));
    assert_eq!(twice["draft"]["tokens"].as_array().unwrap().len(), 1);
}

#[test]
fn resolve_prefers_address_then_name_then_unique_prefix() {
    let r = |t: &str| op("draft.resolve", json!({"text": t, "contacts": contacts()}));
    assert_eq!(r("a@x.com")["kind"], "address");
    assert_eq!(r("grace hopper")["contact"]["id"], "grace");
    assert_eq!(r("Gra")["contact"]["id"], "grace");
    assert_eq!(r("A"), Value::Null);
}

#[test]
fn delete_backward_drops_last_token_only_when_nothing_typed() {
    let draft = json!({"tokens": [{"text": "a"}, {"text": "b"}], "query": ""});
    let out = op("draft.deleteBackward", json!({"draft": draft}));
    assert_eq!(out["draft"]["tokens"], json!([{"text": "a"}]));
    let typed =
        op("draft.deleteBackward", json!({"draft": {"tokens": [{"text": "a"}], "query": "x"}}));
    assert_eq!(typed["changed"], false);
}

#[test]
fn state_of_empty_draft_needs_a_recipient() {
    let state = op("draft.state", json!({}));
    assert_eq!(state["isEmpty"], true);
    assert_eq!(state["sendBlocker"], json!({"kind": "needsRecipient"}));
}

#[test]
fn idle_suggestions_are_chiefs_then_team() {
    let out = op("draft.idleSuggestions", json!({"contacts": contacts()}));
    assert_eq!(ids(&out), ["chief-1", "ada", "grace"]);
}

#[test]
fn existing_conversation_matches_exact_people() {
    let draft =
        op("draft.commit", json!({"draft": {"query": "ada"}, "contacts": contacts()}))["draft"]
            .clone();
    let rows = json!([
        {"id": "g", "kind": "group", "participants": [{"id": "me"}, {"id": "ada"}, {"id": "alan"}]},
        {"id": "d", "kind": "direct", "participants": [{"id": "me"}, {"id": "ada"}]},
    ]);
    assert_eq!(
        op("draft.existingConversation", json!({"draft": draft, "rows": rows, "me": "me"})),
        "d"
    );
}
