//! `chief_home` home resolution: `schemas/chief-home/vectors.json` (the Swift `ChiefHomeVectorTests` and the
//! CLI's `cli/chief/home.rs` follow the same file) plus the per-build cases of `ChiefHome.resolve`.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_home.{name}"), &request)
        .unwrap_or_else(|err| panic!("chief_home.{name}: {err}"))
}

#[test]
fn every_vector_resolves_as_the_cli_resolves_it() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../schemas/chief-home/vectors.json");
    let vectors: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("vectors.json")).expect("json");
    let cases = vectors["cases"].as_array().expect("cases");
    assert!(cases.len() >= 12);
    for case in cases {
        let name = case["name"].as_str().unwrap_or_default();
        let home = op(
            "resolve",
            json!({
                "tag": case["tag"],
                "environment": case["environment"],
                "userHome": case["user_home"],
                "bundleID": case["environment"]["CMUX_BUNDLE_ID"],
                "isDebugBuild": false,
            }),
        );
        assert_eq!(home["root"], case["root"], "{name}");
        assert_eq!(home["session"], case["session"], "{name}");
        if let Some(isolated) = case["isolated"].as_bool() {
            assert_eq!(home["isolated"], isolated, "{name}");
        }
    }
}

fn resolve(env: Value, bundle: Option<&str>, tag: Option<&str>, debug: bool) -> Value {
    op(
        "resolve",
        json!({"tag": tag, "environment": env, "userHome": "/Users/me", "bundleID": bundle, "isDebugBuild": debug}),
    )
}

#[test]
fn nightly_keeps_the_shared_home_and_imports_old_chiefs() {
    let home = resolve(json!({}), Some("com.cmuxterm.app.nightly"), None, false);
    assert_eq!(home["root"], "/Users/me/.cmux/chief/default");
    assert_eq!(home["buildID"], "com.cmuxterm.app.nightly");
    assert_eq!(home["importsOldChiefs"], true);
    assert_eq!(home["usesAppAcpmux"], true);
    assert_eq!(home["acpmuxHome"], "/Users/me/.cmux/chief/default/acpmux");
    assert_eq!(home["daemonStateDirectory"], "/Users/me/.cmux/chief/default/tui");
    assert_eq!(home["shutdownMarker"], "/Users/me/.cmux/chief/default/state/shutdown");
    assert_eq!(home["settleStatusFile"], "/Users/me/.cmux/chief/default/state/settle.json");
    let own = resolve(
        json!({"CMUX_CHIEF_OWN_ACPMUX": "1"}),
        Some("com.cmuxterm.app.nightly"),
        None,
        false,
    );
    assert_eq!(own["usesAppAcpmux"], false);
}

#[test]
fn every_other_build_has_its_own_home() {
    let next = resolve(json!({}), Some("com.cmuxterm.app.nightly.cmux-next"), None, false);
    assert_eq!(next["root"], "/Users/me/.cmux/chief/com.cmuxterm.app.nightly.cmux-next");
    assert_eq!(next["importsOldChiefs"], false);
    assert_eq!(next["usesAppAcpmux"], false);
    let account =
        resolve(json!({"CMUX_NEXT_CHIEF_ACCOUNT": "work"}), Some("com.cmuxterm.app"), None, false);
    assert_eq!(account["root"], "/Users/me/.cmux/chief/com.cmuxterm.app.work");
    // Two copies of the plain DEV bundle with their own tags keep apart (the build key).
    let a = resolve(json!({}), Some("com.cmuxterm.app.debug"), Some("a"), false);
    let b = resolve(json!({}), Some("com.cmuxterm.app.debug"), Some("b"), false);
    assert_eq!(a["root"], "/Users/me/.cmux/chief/com.cmuxterm.app.debug--a");
    assert_eq!(b["root"], "/Users/me/.cmux/chief/com.cmuxterm.app.debug--b");
    let tagged = resolve(json!({}), Some("com.cmuxterm.app.debug.my-tag"), Some("my-tag"), false);
    assert_eq!(tagged["root"], "/Users/me/.cmux/chief/com.cmuxterm.app.debug.my-tag");
}

#[test]
fn the_build_id_override_counts_only_in_a_debug_compile() {
    let env = json!({"CMUX_NEXT_CHIEF_BUILD_ID": "com.cmuxterm.app.nightly"});
    let debug = resolve(env.clone(), Some("com.cmuxterm.app.debug.x"), None, true);
    assert_eq!(debug["root"], "/Users/me/.cmux/chief/default");
    assert_eq!(debug["buildID"], "com.cmuxterm.app.nightly");
    let release = resolve(env, Some("com.cmuxterm.app.debug.x"), None, false);
    assert_eq!(release["root"], "/Users/me/.cmux/chief/com.cmuxterm.app.debug.x");
}

#[test]
fn isolated_launches_and_overrides() {
    for env in [
        json!({"CMUX_NEXT_CHIEF_ISOLATED": "1"}),
        json!({"CMUX_NEXT_NO_ACTIVATE": "1"}),
        json!({"CMUX_NEXT_SHOWCASE": "1"}),
        json!({"CMUX_NEXT_TEST_WINDOW_FRAME": "0,0,800,600"}),
        json!({"CMUX_NEXT_TEST_WINDOW_SCREEN": "1"}),
    ] {
        let home = resolve(env.clone(), Some("com.cmuxterm.app.nightly"), Some("My Tag"), false);
        assert_eq!(home["root"], "/Users/me/.cmux/chief/isolated/My-Tag", "{env}");
        assert_eq!(home["isolated"], true);
        assert_eq!(home["importsOldChiefs"], false);
    }
    let untagged = resolve(json!({"CMUX_NEXT_SHOWCASE": "1"}), None, None, false);
    assert_eq!(untagged["root"], "/Users/me/.cmux/chief/isolated/untagged");
    let empty = resolve(json!({"CMUX_NEXT_TEST_WINDOW_FRAME": ""}), None, None, false);
    assert_eq!(empty["isolated"], false, "an empty variable is unset");
    // A root override ignores the isolation markers.
    let rooted = resolve(
        json!({"CMUX_NEXT_CHIEF_ROOT": "/tmp/x/../roots/./c", "CMUX_NEXT_CHIEF_ISOLATED": "1"}),
        Some("com.cmuxterm.app.nightly"),
        None,
        false,
    );
    assert_eq!(rooted["root"], "/tmp/roots/c/default");
    let explicit = resolve(
        json!({"CMUX_NEXT_MUX_HOME": "/tmp/a/../home/"}),
        Some("com.cmuxterm.app"),
        None,
        false,
    );
    assert_eq!(explicit["root"], "/tmp/home");
    assert_eq!(explicit["buildID"], Value::Null);
}

#[test]
fn small_rules() {
    assert_eq!(
        op("has_own_home", json!({"bundleID": "com.cmuxterm.app.nightly"}))["ownHome"],
        false
    );
    assert_eq!(op("has_own_home", json!({"bundleID": "  "}))["ownHome"], false);
    assert_eq!(op("has_own_home", json!({}))["ownHome"], false);
    assert_eq!(op("has_own_home", json!({"bundleID": "com.cmuxterm.app"}))["ownHome"], true);
    assert_eq!(op("component", json!({"raw": "..a b!c.."}))["component"], "a-b-c");
    assert_eq!(op("component", json!({"raw": "-.-"}))["component"], Value::Null);
    assert_eq!(
        op("session_name", json!({"path": "/Users/cmux/.cmux/chief/default"}))["session"],
        "cmux-chief-b902d10e"
    );
    let host =
        op("tab_host", json!({"path": "/Users/cmux/.cmux/chief/default"}))["tabHost"].clone();
    assert_eq!(host, "chief:b902d10e");
    assert_eq!(op("chief_root", json!({"userHome": "/Users/me"}))["root"], "/Users/me/.cmux/chief");
    let app = op("uses_app_acpmux", json!({"buildID": "com.cmuxterm.app.nightly"}));
    assert_eq!(app, json!({"ownAcpmux": false, "usesAppAcpmux": true}));
    let isolated =
        op("uses_app_acpmux", json!({"isolated": true, "buildID": "com.cmuxterm.app.nightly"}));
    assert_eq!(isolated["usesAppAcpmux"], false);
    let own = op(
        "uses_app_acpmux",
        json!({"buildID": "com.cmuxterm.app.nightly", "environment": {"CMUX_CHIEF_OWN_ACPMUX": "1"}}),
    );
    assert_eq!(own["usesAppAcpmux"], false);
}

#[test]
fn named_chiefs_have_their_own_brain_home() {
    let brain =
        op("brain_home", json!({"muxHome": "/h", "chief": "agent_01JNEWCHIEF0000ABCDEFGH"}));
    assert_eq!(brain["brainHome"], "/h/c/abcdefgh");
    assert_eq!(op("brain_home", json!({"muxHome": "/h"}))["brainHome"], "/h");
    let one = json!({"participants": [{"id": "user_me"}, {"id": "agent_x", "isChief": true}]});
    assert_eq!(op("named_chief", one)["chief"], "agent_x");
    let mux = json!({"participants": [{"id": "agent_mux", "isChief": true}]});
    assert_eq!(op("named_chief", mux)["chief"], Value::Null);
    let two = json!({"participants": [{"id": "a", "isChief": true}, {"id": "b", "isChief": true}]});
    assert_eq!(op("named_chief", two)["chief"], Value::Null);
}
