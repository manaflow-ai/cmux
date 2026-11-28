use super::*;

fn ask(preview: &str) -> Value {
    json!({
        "toolCall": {
            "toolCallId": "toolu_1",
            "rawInput": {"questions": [{
                "question": "Which card?", "header": "Card",
                "options": [
                    {"label": "Glass", "description": "Frosted", "preview": preview},
                    {"label": "Plain", "description": "Flat"},
                ],
            }]},
            "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": true}},
        },
        "options": [{"optionId": "allow_once", "name": "Answer", "kind": "allow_once"}],
    })
}

fn preview_of(request: &Value) -> &Value {
    &question(request).unwrap()["items"][0]["options"][0]["preview"]
}

#[test]
fn previews_are_monospace_unless_the_launch_says_html() {
    let mut plain = ask("┌──┐\n│ab│\n└──┘");
    normalize(&mut plain, PreviewFormat::Monospace);
    assert_eq!(preview_of(&plain), &json!({"text": "┌──┐\n│ab│\n└──┘", "format": "monospace"}));

    let fragment = r#"<div style="padding:8px">Glass</div>"#;
    let mut html = ask(fragment);
    normalize(&mut html, PreviewFormat::Html);
    assert_eq!(preview_of(&html), &json!({"text": fragment, "format": "html"}));
    // An option without a preview stays without one.
    assert!(question(&html).unwrap()["items"][0]["options"][1].get("preview").is_none());
}

#[test]
fn only_a_claude_launch_with_the_literal_html_writes_html() {
    let env = |value: &str| {
        std::collections::BTreeMap::from([(PREVIEW_FORMAT_ENV.to_owned(), value.to_owned())])
    };
    assert_eq!(PreviewFormat::of(true, &env("html")), PreviewFormat::Html);
    assert_eq!(PreviewFormat::of(true, &env(" html ")), PreviewFormat::Html);
    assert_eq!(PreviewFormat::of(true, &env("markdown")), PreviewFormat::Monospace);
    assert_eq!(PreviewFormat::of(true, &env("${FORMAT}")), PreviewFormat::Monospace);
    assert_eq!(PreviewFormat::of(true, &Default::default()), PreviewFormat::Monospace);
    // Another harness reading the variable is not Claude Code's preview format.
    assert_eq!(PreviewFormat::of(false, &env("html")), PreviewFormat::Monospace);
}

#[test]
fn a_question_normalized_earlier_keeps_its_format() {
    let mut request = ask("<b>x</b>");
    normalize(&mut request, PreviewFormat::Html);
    normalize(&mut request, PreviewFormat::Monospace);
    assert_eq!(preview_of(&request)["format"], "html");
}

/// An item that takes no answer of the person's own (an MCP form's choice)
/// takes only its labels, each once.
#[test]
fn an_item_without_other_answers_takes_only_its_labels() {
    let request = json!({"toolCall": {"_meta": {"acpmux": {"question": {"harness": "claude", "items": [
        {"id": "q0", "prompt": "Region", "multiSelect": false, "allowsOther": false,
         "options": [{"id": "EU", "label": "EU"}, {"id": "US", "label": "US"}]},
        {"id": "q1", "prompt": "Tags", "multiSelect": true, "allowsOther": false,
         "options": [{"id": "a", "label": "a"}, {"id": "b", "label": "b"}]},
        {"id": "q2", "prompt": "Note", "multiSelect": false, "allowsOther": true, "options": []},
    ]}}}}});
    let check = |region: &str, tags: &str| {
        check_answers(&request, &json!({"Region": region, "Tags": tags, "Note": "free text"}))
    };
    assert!(check("EU", "a, b").is_ok());
    assert!(check("Mars", "a").is_err());
    assert!(check("EU", "a, c").is_err());
    assert!(check("EU", "a, a").is_err());
    assert!(check("EU, US", "a").is_err());
}

/// Pi's `ctx.ui.select` as pi-acp 0.0.35 raises it.
fn pi_select() -> Value {
    json!({
        "toolCall": {
            "toolCallId": "pi-ui-7", "title": "Deploy target", "kind": "other", "status": "pending",
            "rawInput": {"method": "select", "title": "Deploy target",
                "message": "Where should this build go?", "options": ["staging", "prod"]},
        },
        "options": [
            {"optionId": "choice-0", "name": "staging", "kind": "allow_once"},
            {"optionId": "choice-1", "name": "prod", "kind": "allow_once"},
        ],
    })
}

fn pi_confirm() -> Value {
    json!({
        "toolCall": {"toolCallId": "pi-ui-8", "title": "Delete branch?", "kind": "other",
            "rawInput": {"method": "confirm", "title": "Delete branch?"}},
        "options": [
            {"optionId": "yes", "name": "Yes", "kind": "allow_once"},
            {"optionId": "no", "name": "No", "kind": "reject_once"},
        ],
    })
}

#[test]
fn a_pi_select_is_a_persons_question_answered_by_its_option() {
    let mut request = pi_select();
    assert!(!needs_person(&request), "without the copy, approve-all would pick choice-0");
    normalize_pi(&mut request, Some("pi"));
    assert_eq!(
        question(&request).unwrap(),
        &json!({"harness": "acp", "agent": "pi", "items": [{
            "id": "q0", "header": "Deploy target", "prompt": "Where should this build go?",
            "options": [{"id": "choice-0", "label": "staging"}, {"id": "choice-1", "label": "prod"}],
            "multiSelect": false, "allowsOther": false,
        }]})
    );
    assert!(needs_person(&request));
    assert!(!ancestor_answerable(&request, true), "the person's, not a session above");
    assert!(check_reply(&request, Some("choice-1"), None).is_ok());
    assert!(check_reply(&request, None, None).is_ok(), "a cancel");
}

#[test]
fn a_pi_confirm_prompts_with_its_title() {
    let mut request = pi_confirm();
    normalize_pi(&mut request, Some("pi"));
    let item = &question(&request).unwrap()["items"][0];
    assert_eq!(item["prompt"], "Delete branch?");
    assert!(item.get("header").is_none());
    assert_eq!(
        item["options"],
        json!([{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}])
    );
    assert!(check_reply(&request, Some("yes"), None).is_ok());
    assert!(check_reply(&request, Some("no"), None).is_ok());
}

#[test]
fn only_a_pi_session_dialog_becomes_a_question() {
    for family in [None, Some("claude"), Some("codex")] {
        let mut request = pi_select();
        normalize_pi(&mut request, family);
        assert!(question(&request).is_none(), "{family:?}");
    }
    let mut tool = pi_select();
    tool["toolCall"]["toolCallId"] = json!("call_1");
    normalize_pi(&mut tool, Some("pi"));
    assert!(question(&tool).is_none(), "a Pi tool call stays a permission");
    let mut other = pi_select();
    other["toolCall"]["rawInput"]["method"] = json!("input");
    normalize_pi(&mut other, Some("pi"));
    assert!(question(&other).is_none());
}

#[test]
fn an_option_only_allow_still_refuses_a_claude_question() {
    let mut request = ask("x");
    normalize(&mut request, PreviewFormat::Monospace);
    assert!(check_reply(&request, Some("allow_once"), None).is_err());
}
