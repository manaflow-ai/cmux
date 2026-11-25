use super::*;
use serde_json::json;

#[test]
fn an_emoji_a_symbol_and_a_mark_parse_to_the_spec_clients_draw() {
    let id = "01a18a35-b1e8-7951-ba2f-703bf916b9a6";
    let mango = SessionIcon::parse("🥭", id, "Mango").unwrap();
    assert_eq!(
        serde_json::to_value(&mango).unwrap(),
        json!({"kind": "emoji", "text": "🥭", "source": "session"})
    );
    let symbol = SessionIcon::parse("sf:leaf.fill", id, "Mango").unwrap();
    let wire = serde_json::to_value(&symbol).unwrap();
    assert_eq!(wire["kind"], "symbol");
    assert_eq!(wire["name"], "leaf.fill");
    assert_eq!(wire["text"], "M");
    assert_eq!(SessionIcon::parse("leaf.fill", id, "Mango").unwrap(), symbol);
    assert_eq!(
        serde_json::to_value(SessionIcon::parse("claude", id, "Mango").unwrap()).unwrap()["kind"],
        "brand"
    );
}

#[test]
fn a_stored_icon_reads_back_as_it_was_written() {
    let icon = SessionIcon::parse("🥭", "id", "Mango").unwrap();
    let text = serde_json::to_string(&icon).unwrap();
    assert_eq!(serde_json::from_str::<SessionIcon>(&text).unwrap(), icon);
}

#[test]
fn images_arrive_as_bytes_and_are_checked() {
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>"#;
    let icon = SessionIcon::image("image/svg+xml", svg).unwrap();
    assert!(!icon.fits_a_row());
    let url = format!(
        "data:image/svg+xml;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(svg)
    );
    assert_eq!(SessionIcon::parse(&url, "id", "x").unwrap(), icon);
    assert!(SessionIcon::image("image/svg+xml", b"<svg><script>x</script></svg>").is_err());
    assert!(SessionIcon::image("image/png", b"not a png").is_err());
    assert!(SessionIcon::image("image/png", &vec![0; MAX_IMAGE_BYTES + 1]).is_err());
    assert!(SessionIcon::image("image/x-icon", &[0, 0, 1, 0, 1]).is_ok());
    assert!(SessionIcon::image("text/html", b"<html>").is_err());
}

#[test]
fn a_path_is_refused_by_the_daemon_and_typed_by_the_cli() {
    assert!(SessionIcon::parse("./mango.svg", "id", "x").is_err());
    assert_eq!(SessionIcon::mime_of("https://example.com/favicon.ico?v=2"), Some("image/x-icon"));
    assert_eq!(SessionIcon::mime_of("mark.SVG"), Some("image/svg+xml"));
    assert_eq!(SessionIcon::sniff(b"\x89PNG\r\n\x1a\n...."), Some("image/png"));
    assert_eq!(SessionIcon::sniff(b"<?xml?><svg/>"), Some("image/svg+xml"));
    assert!(clears("none") && clears(" ") && !clears("🥭"));
}

#[test]
fn junk_is_refused_with_the_forms_an_icon_takes() {
    let why = SessionIcon::parse("Hello World", "id", "x").unwrap_err();
    assert!(why.contains("emoji"), "{why}");
}
