use super::*;

#[test]
fn patterns_match_whole_names_with_star_as_any_run() {
    assert!(tool_matches("mcp__github__get_pull_request", "mcp__github__get_pull_request"));
    assert!(!tool_matches("mcp__github__get_pull_request", "mcp__github__get_pull_requests"));
    assert!(tool_matches("mcp__github__*", "mcp__github__get_pull_request"));
    assert!(tool_matches("mcp__github__*pull_request*", "mcp__github__get_pull_request"));
    assert!(tool_matches("mcp__github__*pull_request*", "mcp__github__pull_request_read"));
    assert!(tool_matches("*__get_pull_request", "mcp__github__get_pull_request"));
    assert!(!tool_matches("mcp__github__*pull_request*", "mcp__linear__get_issue"));
    assert!(!tool_matches("a*a", "a"), "the prefix and suffix may not overlap");
    assert!(tool_matches("a*a", "aa"));
    assert_eq!(specificity("mcp__github__*"), 13);
    assert_eq!(specificity("**"), 0);
}

#[test]
fn a_long_output_is_cut_at_a_character_boundary() {
    let output = "é".repeat(MAX_FIELD_BYTES);
    let tool = ToolCall {
        name: "t".into(),
        title: None,
        status: None,
        input: Some(json!({ "blob": "x".repeat(MAX_FIELD_BYTES) })),
        output: Some(output),
    };
    let context = tool_context(tool);
    let cut = context["output"].as_str().unwrap();
    assert!(cut.len() <= MAX_FIELD_BYTES && cut.len() >= MAX_FIELD_BYTES - 1);
    assert!(context.get("input").is_none(), "an input past 16 KiB is dropped");
}
