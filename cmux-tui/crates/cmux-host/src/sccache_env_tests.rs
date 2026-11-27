use serde_json::json;

use super::*;

/// The section the cloud service writes (cmux-platform `sccacheGuestEnv`), values shortened.
fn platform_section() -> Value {
    json!({"env": {
        "RUSTC_WRAPPER": "sccache",
        "SCCACHE_BUCKET": "cmux-sccache",
        "SCCACHE_ENDPOINT": "https://platform.example/v1/cloud/sccache",
        "SCCACHE_REGION": "auto",
        "SCCACHE_S3_NO_CREDENTIALS": "true",
        "SCCACHE_S3_USE_SSL": "true",
        "SCCACHE_BASEDIRS": "/home/cmux",
        "SCCACHE_SKIP_CACHE_CHECK": "true",
        "SCCACHE_IGNORE_SERVER_IO_ERROR": "1",
        "SCCACHE_CACHE_READ_TIMEOUT_SECS": "5",
        "SCCACHE_ALLOW_INCREMENTAL": "1",
    }})
}

#[test]
fn the_platform_section_is_accepted_in_name_order() {
    let vars = parse_section(&platform_section()).unwrap();
    assert_eq!(vars.len(), 11);
    assert_eq!(vars[0], ("RUSTC_WRAPPER".to_owned(), "sccache".to_owned()));
    assert!(vars.windows(2).all(|w| w[0].0 < w[1].0));
    assert_eq!(parse_file(&file_text(&vars)).unwrap(), vars, "the kept file reads back");
}

#[test]
fn only_rustc_wrapper_and_sccache_names_are_allowed() {
    for ok in ["RUSTC_WRAPPER", "SCCACHE_BUCKET", "SCCACHE_S3_USE_SSL", "SCCACHE_X1"] {
        assert!(allowed_name(ok), "{ok}");
    }
    for no in ["PATH", "LD_PRELOAD", "SCCACHE_", "sccache_bucket", "SCCACHE_a", "RUSTC", "HOME"] {
        assert!(!allowed_name(no), "{no}");
    }
}

#[test]
fn a_section_with_any_other_name_is_refused_whole_and_names_only_the_key() {
    let mut section = platform_section();
    section["env"]["LD_PRELOAD"] = json!("/tmp/secret-value.so");
    let why = parse_section(&section).unwrap_err();
    assert!(why.contains("LD_PRELOAD"), "{why}");
    assert!(!why.contains("secret-value"), "a refusal never shows a value: {why}");
}

#[test]
fn malformed_sections_are_refused_without_showing_values() {
    let cases = [
        json!("sccache"),
        json!({}),
        json!({"env": []}),
        json!({"env": {}}),
        json!({"env": {"RUSTC_WRAPPER": "sccache"}, "other": 1}),
        json!({"env": {"RUSTC_WRAPPER": 1}}),
        json!({"env": {"RUSTC_WRAPPER": ""}}),
        json!({"env": {"SCCACHE_ENDPOINT": "https://a\nSECRET=token-value"}}),
        json!({"env": {"SCCACHE_ENDPOINT": "x".repeat(5000)}}),
    ];
    for case in cases {
        let why = parse_section(&case).unwrap_err();
        assert!(!why.contains("token-value"), "{why}");
    }
    let many: Map<String, Value> = (0..33).map(|i| (format!("SCCACHE_V{i}"), json!("1"))).collect();
    assert!(parse_section(&json!({"env": many})).is_err());
    assert!(parse_file("not json").is_err());
}

#[test]
fn names_lists_names_never_values() {
    let vars = vec![
        ("RUSTC_WRAPPER".to_owned(), "sccache".to_owned()),
        ("SCCACHE_X".to_owned(), "v".to_owned()),
    ];
    assert_eq!(names(&vars), "RUSTC_WRAPPER,SCCACHE_X");
}
