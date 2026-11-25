//! The updater's ops (`updater_*`) through the C ABI: what the app's CmuxNextUpdater sends and
//! reads back, so its feed reading, version order and offer are cmux-updater-core's.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(operation: &std::ffi::CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn version_compare_is_sparkles_order() {
    let (code, body) = call(
        c"updater_version_compare",
        &json!({"pairs": [["1203", "1204"], ["1.0", "1.0.0"], ["1.0", "1.0b1"]]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"orders": [-1, 0, 1]}));
}

#[test]
fn appcast_parse_reads_items_and_errors() {
    let feed = r#"<rss xmlns:sparkle="x"><channel><item>
        <sparkle:version>1204</sparkle:version>
        <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
        <enclosure url="https://files.cmux.com/a.dmg" length="10" sparkle:edSignature="c2ln"/>
    </item></channel></rss>"#;
    let (code, body) = call(c"updater_appcast_parse", &json!({"xml": feed}));
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"items": [{
            "version": "1204",
            "minimumSystemVersion": {"major": 26, "minor": 0, "patch": 0},
            "downloadUrl": "https://files.cmux.com/a.dmg",
            "listsDeltas": false,
            "signature": {"edSignature": "c2ln", "length": 10},
        }]})
    );
    let (code, body) = call(c"updater_appcast_parse", &json!({"xml": "<rss/>"}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"error": "appcast has no <channel>"}));
}

#[test]
fn appcast_select_names_the_offer() {
    let (code, body) = call(
        c"updater_appcast_select",
        &json!({
            "items": [{"version": "1205", "minimumSystemVersion": {"major": 27, "minor": 0, "patch": 0}},
                      {"version": "1204"}],
            "currentBuild": "1204",
            "system": {"major": 26, "minor": 0, "patch": 0},
        }),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"kind": "requires_newer_macos", "item": 0, "required": {"major": 27, "minor": 0, "patch": 0}})
    );
}

#[test]
fn system_version_parses_each_text() {
    let (code, body) = call(c"updater_system_version", &json!({"texts": ["15.6.1", "nope"]}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"versions": [{"major": 15, "minor": 6, "patch": 1}, null]}));
}

#[test]
fn a_malformed_request_is_invalid() {
    let (code, _) = call(c"updater_appcast_select", &json!({"items": 3}));
    assert_eq!(code, ERR_INVALID);
}

#[test]
fn rollback_and_ring_return_answer() {
    let (code, body) = call(
        c"updater_rollback",
        &json!({"kept": [{"build": "1205", "storeSchemas": {"tabs": 3}, "teamId": "T"}],
                "running": "1210", "stored": {"tabs": 3}, "teamId": "T"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"target": 0}));
    let (code, body) = call(
        c"updater_ring_return",
        &json!({"installedBuild": "1210", "offered": ["1200"], "kept": ["1209"]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"kind": "waits"}));
    let (code, body) = call(c"updater_numeric_compare", &json!({"pairs": [["999", "1204"]]}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"orders": [-1]}));
}

#[test]
fn feed_resolve_picks_the_architecture_feed() {
    let (code, body) = call(
        c"updater_feed_resolve",
        &json!({"infoFeedURL": "https://x/nightly/appcast.xml", "architecture": "x86_64"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["url"], "https://x/nightly/appcast-x86_64.xml");
    assert_eq!(body["channel"], "nightly");
    assert_eq!(body["allowedSparkleChannels"], json!([]));
}

#[test]
fn install_attempt_confirms_the_fresh_update() {
    let (code, body) = call(
        c"updater_install_attempt",
        &json!({"attempt": "awaitingResult", "event": "phase", "phase": "updateAvailable"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["action"], "confirmInstall");
    assert_eq!(body["disarm"], false);
    let (code, _) = call(c"updater_install_attempt", &json!({"event": "request"}));
    assert_eq!(code, ERR_INVALID);
}

#[test]
fn relaunch_permits_holds_for_a_running_command() {
    let (code, body) = call(
        c"updater_relaunch_permits",
        &json!({"blockers": {"runningCommandCount": 1}, "automatic": false,
                "waits": {"waited": 9999, "daemonUnavailableFor": 0, "agentTimeout": 1,
                          "daemonUnavailableTimeout": 1, "automaticWaitCap": 1}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"permits": false, "empty": false}));
}
