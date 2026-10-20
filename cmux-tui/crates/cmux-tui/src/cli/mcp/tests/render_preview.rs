use super::*;

#[test]
fn render_preview_scopes_requests_and_rejects_unbounded_input() {
    let args = json!({"html":"<p>Hello</p>","width":390});
    let args = args.as_object().unwrap();
    assert_eq!(
        render_preview_tool::params(args, Some("own-session")).unwrap(),
        json!({"agent_session":"own-session","html":"<p>Hello</p>","width":390})
    );
    assert!(render_preview_tool::params(args, None).is_err());
    for bad in [
        json!({"html":" "}),
        json!({"html":"x","agent_session":"other"}),
        json!({"html":"x","width":319}),
        json!({"html":"x","width":1441}),
        json!({"html":"x","width":390.5}),
        json!({"html":"x","width":null}),
        json!({"html":"x".repeat((1 << 20) + 1)}),
    ] {
        assert!(render_preview_tool::params(bad.as_object().unwrap(), Some("own")).is_err());
    }
}

#[test]
fn render_preview_routes_to_app_without_focus_or_mutation() {
    let backend = Fake::default();
    let _ = render_preview_tool::call(
        &backend,
        json!({"html":"<p>Hello</p>"}).as_object().unwrap(),
        Some("own"),
    );
    let sent = backend.sent.borrow();
    let request = sent.last().unwrap();
    assert_eq!(request["method"], "agent.render_preview");
    assert_eq!(request["params"]["agent_session"], "own");
    assert_eq!(request["params"]["html"], "<p>Hello</p>");
    assert!(request["params"].get("focus").is_none());
}

#[test]
fn render_preview_returns_image_without_text_truncation_or_duplicate_base64() {
    let png = format!("iVBORw0KGgo{}", "A".repeat(300_000));
    let result = render_preview_tool::result(json!({"png":png,"contentHeight":230,"warnings":[]}));
    assert_eq!(result["isError"], false);
    assert_eq!(result["content"][0]["data"], png);
    assert_eq!(result["content"][0]["mimeType"], "image/png");
    assert_eq!(result["structuredContent"]["contentHeight"], 230);
    assert!(result["structuredContent"].get("png").is_none());
    assert_eq!(render_preview_tool::result(json!({"error":"disabled"}))["isError"], true);
}

#[test]
fn render_preview_truncates_diagnostics_without_dropping_the_image() {
    let png = "iVBORw0KGgoAAA";
    let result = render_preview_tool::result(json!({"png":png,
        "warnings":vec!["x".repeat(10000);100],
        "consoleMessages":vec![json!({"level":"warn","message":"\u{0001}".repeat(10000)});100],
        "unexpected":"x".repeat(100000)}));
    assert_eq!(result["isError"], false);
    assert_eq!(result["content"][0]["data"], png);
    assert_eq!(result["structuredContent"]["warnings"].as_array().unwrap().len(), 20);
    assert!(result["structuredContent"]["consoleMessages"].as_array().unwrap().len() <= 50);
    assert!(result["content"][1]["text"].as_str().unwrap().len() < 64 << 10);
    assert_eq!(
        render_preview_tool::result(json!({"png":format!("iVBORw0KGgo{}", "A".repeat(4_194_304))}))
            ["isError"],
        true
    );
}
