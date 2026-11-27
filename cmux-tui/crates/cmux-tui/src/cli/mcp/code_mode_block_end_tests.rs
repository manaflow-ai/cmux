use super::*;

/// Braces inside strings, template literals and comments are skipped; a block that never
/// closes, or a string, escape or comment cut off at the end, is `None`, not a panic.
#[test]
fn block_end_skips_quoted_and_commented_braces_and_stops_at_the_end() {
    let script = "{ \"}\" '}' `}` /* } */ // }\n }";
    assert_eq!(block_end(script, 0), Some(script.len() - 1));
    for cut in ["{ \"open", "{ 'a\\", "{ /* never closed", "{ // to the end", "{ {", "{ /"] {
        assert_eq!(block_end(cut, 0), None, "{cut:?}");
    }
}

/// Only the descriptor's own reads change: a cmux tool keeps its required list,
/// read-only and destructive hints in the compact form.
#[test]
fn compact_keeps_required_and_hints() {
    let tool = json!({
        "name": "pane_close",
        "description": "Close a pane (cmux.protocol/2 `pane.close`).",
        "inputSchema": {"type": "object", "properties": {"pane": {"type": "string"}}, "required": ["pane"]},
        "annotations": {"readOnlyHint": false, "destructiveHint": true},
    });
    let out = compact(&tool);
    assert_eq!(out["inputSchema"]["required"], json!(["pane"]));
    assert_eq!(out.get("destructive"), Some(&json!(true)));
    assert_eq!(out.get("readOnly"), None);
}
