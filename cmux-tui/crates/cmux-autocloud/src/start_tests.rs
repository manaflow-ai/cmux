use super::*;

#[test]
fn on_by_default_when_signed_in_unless_killed() {
    assert!(on_by_default(None, true));
    assert!(on_by_default(Some("1"), true));
    assert!(!on_by_default(None, false));
    for off in ["0", "off", "FALSE", " no "] {
        assert!(!on_by_default(Some(off), true), "{off}");
    }
}

#[test]
fn api_words_name_the_backends() {
    assert_eq!(api_base("prod"), cmux_cloud_environment::PRODUCTION_API);
    assert_eq!(api_base(""), cmux_cloud_environment::PRODUCTION_API);
    assert_eq!(api_base("staging"), cmux_cloud_environment::STAGING_API);
    assert_eq!(api_base("https://example.test/"), "https://example.test");
}

#[test]
fn the_create_is_the_chat_start_size_and_says_who_started_it() {
    let p = serde_json::to_value(create_params("autocloud")).unwrap();
    assert_eq!(p["name"], "autocloud");
    assert_eq!(p["size"]["cpu"], 4);
    assert_eq!(p["size"]["memory_mb"], 16_384);
    assert_eq!(p["size"]["disk_mb"], 65_536);
    assert_eq!(p["origin"]["label"], "cmux autocloud");
    assert!(p.get("ttl_seconds").is_none());
}
