use super::*;

/// A Computer Use result's outline blocks go back in their place for a
/// script; an unmarked second text block (another tool's) is left as content.
#[test]
fn computer_use_outlines_return_to_their_place() {
    let mut out = acpmux::computer_use::ToolOutput::ok(json!({
        "route": "ax_press",
        "state": {"unchanged": false, "tree": "~ [3] button \"Save\" (was: disabled)"},
    }));
    out.png_base64 = Some("AAAA".into());
    let mut images = Vec::new();
    let value = from_content(&out.to_mcp()["content"], &mut images, false);
    assert_eq!(value["state"]["tree"], "~ [3] button \"Save\" (was: disabled)");
    assert_eq!(value["route"], "ax_press");
    assert_eq!(images.len(), 1);
    let other = json!([{"type": "text", "text": "{\"a\": 1}"}, {"type": "text", "text": "notes"}]);
    let value = from_content(&other, &mut images, false);
    assert!(value.get("tree").is_none() && value["content"].is_array(), "{value}");
}
