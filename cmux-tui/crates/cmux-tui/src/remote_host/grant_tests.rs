#[test]
fn rfc3339_formats_known_instants() {
    assert_eq!(super::rfc3339(0), "1970-01-01T00:00:00Z");
    assert_eq!(super::rfc3339(1_792_488_779), "2026-10-20T09:32:59Z");
    assert_eq!(super::rfc3339(951_782_400), "2000-02-29T00:00:00Z");
}
