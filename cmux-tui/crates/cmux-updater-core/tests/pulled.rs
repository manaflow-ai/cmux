//! Ported from the Swift `PulledBuildWatchTests.decodeSkipsBadEntries`.

mod updater_core_pulled {
    use cmux_updater_core::pulled::{PulledBuild, decode};

    #[test]
    fn decode_skips_bad_entries() {
        let body = br#"[{"build":"5","reason":"r"},{"reason":"no build"},7]"#;
        assert_eq!(
            decode(body),
            vec![PulledBuild {
                build: "5".to_owned(),
                reason: "r".to_owned(),
                pulled_at: None,
                serve: None
            }]
        );
        assert!(decode(b"nope").is_empty());
        assert!(decode(br#"{"build":"5"}"#).is_empty(), "the list is an array");
    }

    #[test]
    fn decode_reads_every_field_and_tolerates_wrong_types() {
        let body = br#"[{"build":"4091813159501","reason":"crashes","pulledAt":"2026-10-20T21:00:00Z","serve":"100"},
                        {"build":"6","reason":3,"serve":null},{"build":7}]"#;
        assert_eq!(
            decode(body),
            vec![
                PulledBuild {
                    build: "4091813159501".to_owned(),
                    reason: "crashes".to_owned(),
                    pulled_at: Some("2026-10-20T21:00:00Z".to_owned()),
                    serve: Some("100".to_owned()),
                },
                PulledBuild {
                    build: "6".to_owned(),
                    reason: String::new(),
                    pulled_at: None,
                    serve: None
                },
            ]
        );
    }
}
