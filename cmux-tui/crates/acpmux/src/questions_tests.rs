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
