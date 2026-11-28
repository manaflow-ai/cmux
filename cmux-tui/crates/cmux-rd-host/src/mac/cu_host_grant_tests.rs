use super::parse_screen_recording;

#[test]
fn reads_the_permissions_snapshot() {
    assert_eq!(
        parse_screen_recording(b"{\"screen_recording\":true,\"accessibility\":false}\n"),
        Some(true)
    );
    assert_eq!(
        parse_screen_recording(b"{\"screen_recording\":false,\"accessibility\":true}\n"),
        Some(false)
    );
}

#[test]
fn anything_else_is_no_answer() {
    assert_eq!(parse_screen_recording(b""), None);
    assert_eq!(parse_screen_recording(b"not json\n"), None);
    assert_eq!(parse_screen_recording(b"{\"accessibility\":true}\n"), None);
}
