use super::is_cua;

#[test]
fn recognizes_cmux_computer_use_and_not_the_retired_helper() {
    assert!(is_cua("cmux-computer-use", None, &[]));
    assert!(is_cua("cu", Some("/opt/cmux/bin/cmux"), &["computer-use", "mcp"]));
    assert!(is_cua("cu", Some("acpmux"), &["computer-use-mcp"]));
    assert!(!is_cua("cu", Some("cmux"), &["mcp", "serve"]));
    // The retired cmux-cua helper no longer serves Computer Use.
    assert!(!is_cua("cmux-cua", Some("cmux-cua"), &["mcp"]));
}
