//! The JSON operations the app sends over the app FFI: each one round-trips.

mod updater_core_wire {
    use cmux_updater_core::wire::{WireError, respond};
    use serde_json::{Value, json};

    fn call(operation: &str, request: &Value) -> Value {
        let bytes =
            respond(operation.as_bytes(), &serde_json::to_vec(request).unwrap()).unwrap().unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[test]
    fn an_unknown_operation_is_not_this_crates_and_bad_json_is_invalid() {
        assert!(respond(b"resolve", b"{}").is_none());
        assert_eq!(respond(b"updater_version_compare", b"nope"), Some(Err(WireError)));
        assert_eq!(respond(b"updater_version_compare", br#"{"lhs":"1"}"#), Some(Err(WireError)));
    }

    #[test]
    fn version_compare_and_build_order() {
        assert_eq!(
            call("updater_version_compare", &json!({"lhs": "1.0b1", "rhs": "1.0"})),
            json!({"order": -1})
        );
        assert_eq!(
            call("updater_version_compare", &json!({"lhs": "1.0", "rhs": "1.0.0"})),
            json!({"order": 0})
        );
        assert_eq!(
            call("updater_builds_newest_first", &json!({"builds": ["2", "10", "1"]})),
            json!({"order": [1, 0, 2]})
        );
    }

    #[test]
    fn appcast_parse_filters_by_channel_and_reports_errors_as_values() {
        let xml = "<rss><channel><item><sparkle:version>2</sparkle:version><sparkle:channel>cmux-next-dev</sparkle:channel></item><item><sparkle:version>1</sparkle:version><enclosure url=\"https://x/1.zip\"/></item></channel></rss>";
        let answer =
            call("updater_appcast_parse", &json!({"xml": xml, "allowedChannels": ["cmux-next"]}));
        assert_eq!(
            answer,
            json!({"items": [{
                "version": "1", "displayVersion": "1", "title": null, "minimumSystemVersion": null,
                "maximumSystemVersion": null, "releaseNotesUrl": null, "downloadUrl": "https://x/1.zip",
                "itemDescription": null, "date": null, "sparkleChannel": null, "listsDeltas": false
            }]})
        );
        assert_eq!(
            call("updater_appcast_parse", &json!({"xml": xml}))
                .get("items")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(2)
        );
        assert_eq!(
            call("updater_appcast_parse", &json!({"xml": "<rss/>"})),
            json!({"error": "appcast has no <channel>"})
        );
    }

    #[test]
    fn appcast_select_names_items_by_index() {
        let items = json!([
            {"version": "300", "displayVersion": "300", "minimumSystemVersion": {"major": 26, "minor": 0, "patch": 0}},
            {"version": "200", "displayVersion": "200"}
        ]);
        let request = |build: &str, major: i64| json!({"items": items, "currentBuild": build, "system": {"major": major, "minor": 0, "patch": 0}});
        assert_eq!(
            call("updater_appcast_select", &request("100", 26)),
            json!({"kind": "update_available", "item": 0})
        );
        assert_eq!(
            call("updater_appcast_select", &request("200", 15)),
            json!({"kind": "requires_newer_macos", "item": 0, "required": {"major": 26, "minor": 0, "patch": 0}})
        );
        assert_eq!(
            call("updater_appcast_select", &request("300", 26)),
            json!({"kind": "up_to_date", "latest": 0})
        );
    }

    #[test]
    fn ring_return_rollback_and_install_check() {
        assert_eq!(
            call(
                "updater_ring_return",
                &json!({"installedBuild": "500", "offered": ["300"], "kept": ["450", "300"]})
            ),
            json!({"way": "goBack", "kept": 1})
        );
        assert_eq!(
            call("updater_ring_return", &json!({"installedBuild": "300", "offered": ["300"]})),
            json!({"way": "none"})
        );
        assert_eq!(
            call(
                "updater_rollback_decide",
                &json!({"kept": [{"build": "1", "storeSchemas": {"layout": 1}, "teamId": "T"}], "stored": {"layout": 2}, "teamId": "T"})
            ),
            json!({"refusal": {"kind": "storeTooNew", "kept": 0, "store": "layout", "stored": 2, "readable": 1}})
        );
        assert_eq!(
            call(
                "updater_rollback_decide",
                &json!({"kept": [{"build": "1", "storeSchemas": {}, "teamId": "T"}], "stored": {}, "teamId": "T"})
            ),
            json!({"target": 0})
        );
        assert_eq!(
            call("updater_rollback_decide", &json!({"kept": []})),
            json!({"refusal": {"kind": "storesUnknown"}})
        );
        assert_eq!(
            call(
                "updater_install_check",
                &json!({"fromBuild": "1", "targetBuild": "2", "recordedAt": 0.0, "runningBuild": "1", "now": 10.0})
            ),
            json!({"outcome": "failed"})
        );
        assert_eq!(
            call(
                "updater_install_check",
                &json!({"fromBuild": "1", "targetBuild": "1", "recordedAt": 0.0, "runningBuild": "1", "now": 10.0})
            ),
            json!({"outcome": null})
        );
    }

    #[test]
    fn pulled_decode_takes_the_raw_body() {
        let bytes = respond(b"updater_pulled_decode", br#"[{"build":"5","reason":"r"},7]"#)
            .unwrap()
            .unwrap();
        let answer: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            answer,
            json!({"builds": [{"build": "5", "reason": "r", "pulledAt": null, "serve": null}]})
        );
    }

    #[test]
    fn channel_tracks_carry_links_and_dates() {
        let answer = call(
            "updater_channel_tracks",
            &json!({
                "index": [{"build": "300", "shortVersion": "s300", "date": "2026-10-21", "head": "cccccccc"},
                          {"build": "200", "shortVersion": "s200", "date": "2026-10-20", "head": "bbbbbbbb"}],
                "verdicts": {"200": "pass"},
                "installedBuild": "200",
                "followed": "nightly",
                "limit": 10
            }),
        );
        let nightly = answer.pointer("/tracks/1").unwrap();
        assert_eq!(nightly.get("ring"), Some(&json!("nightly")));
        assert_eq!(nightly.get("isFollowed"), Some(&json!(true)));
        assert_eq!(
            nightly.pointer("/builds/0/compareUrl"),
            Some(&json!("https://github.com/manaflow-ai/cmux/compare/bbbbbbbb...cccccccc"))
        );
        assert_eq!(nightly.pointer("/builds/1/health"), Some(&json!("promoted")));
        assert_eq!(answer.pointer("/tracks/0/builds"), Some(&json!([])));
    }

    #[test]
    fn build_info_and_rules() {
        assert_eq!(
            call(
                "updater_build_info",
                &json!({"bundleIdentifier": "com.cmuxterm.app", "minimumSystemVersion": "26.0", "publicKey": "$(K)"})
            ),
            json!({"bundleIdentifier": "com.cmuxterm.app", "shortVersion": "0", "build": "0",
                   "minimumSystemVersion": {"major": 26, "minor": 0, "patch": 0}, "infoFeedUrl": null, "hasPublicKey": false})
        );
        assert_eq!(
            call(
                "updater_build_rules",
                &json!({"bundleIdentifier": "com.cmuxterm.app.debug.next", "infoFeedUrl": "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml", "hasPublicKey": true, "feedChannel": "nightlyNext"})
            ),
            json!({"isTipBuild": true, "developmentBundle": true, "track": "nightly-next", "allowsTestFeed": true,
                   "downloadsAutomaticallyByDefault": false, "disabledReason": null, "offersChannelSwitch": true})
        );
        assert_eq!(
            call("updater_build_rules", &json!({"bundleIdentifier": "com.cmuxterm.app", "hasPublicKey": false, "feedChannel": "stable", "managedPolicyDisablesUpdates": true}))
                .get("disabledReason"),
            Some(&json!("missing_public_key"))
        );
    }
}
