use super::*;

#[test]
fn a_listing_row_and_an_address_read_as_cross_session_targets() {
    assert_eq!(target("beta"), ("beta", false));
    assert_eq!(target("beta [3fa9c1]"), ("beta", true));
    assert_eq!(target("  beta [3fa9c1] "), ("beta", true));
    assert_eq!(target("uds:/tmp/cc-socks/1.sock"), ("uds:/tmp/cc-socks/1.sock", true));
    assert_eq!(target("bridge:abc"), ("bridge:abc", true));
    // Not a ref: brackets around words a name may hold.
    assert_eq!(target("notes [draft]"), ("notes [draft]", false));
}

#[test]
fn the_refusal_names_the_acpmux_command_quoted() {
    let text = refusal_text("beta", true);
    assert!(text.contains("\"$ACPMUX_BIN\" send beta --wait"), "{text}");
    assert!(text.contains("Nothing was sent"), "{text}");
    let text = refusal_text("it's", false);
    assert!(text.contains("send 'it'\\''s' --wait"), "{text}");
}
