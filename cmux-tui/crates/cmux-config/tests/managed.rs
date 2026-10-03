//! Managed preferences and team policy (ported from Swift
//! `ManagedPreferencesTests`): precedence, policy keys, readers.

use std::collections::BTreeMap;

use cmux_config::diagnostics::DiagnosticKind;
use cmux_config::managed::{
    JsonFileManagedReader, ManagedPreferences, ManagedReader, ManagedSource,
    PlistFileManagedReader, TeamPolicyLayer, enrollment_token_hash,
};
use cmux_config::{EffectiveSettings, Schema, jsonc};
use serde_json::{Value, json};

const SPEED: &str = "ui.animationSpeed";

fn file(text: &str) -> Value {
    jsonc::parse(text).unwrap()
}

fn map(entries: &[(&str, Value)]) -> BTreeMap<String, Value> {
    entries.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

fn merge(file: &Value, managed: &ManagedPreferences, team: &TeamPolicyLayer) -> EffectiveSettings {
    EffectiveSettings::merge(file, managed, team, Schema::embedded())
}

#[test]
fn precedence_highest_present_layer_decides() {
    type Row = (
        Option<&'static str>,
        Option<&'static str>,
        Option<&'static str>,
        Option<&'static str>,
        Option<&'static str>,
        Option<&'static str>,
        Option<&'static str>,
    );
    // (file, recommended, team default, team enforced, forced, expected, managed by)
    let rows: [Row; 7] = [
        (None, None, None, None, None, None, None),
        (None, None, Some("normal"), None, None, Some("normal"), None),
        (None, Some("off"), Some("normal"), None, None, Some("off"), None),
        (Some("fast"), Some("off"), Some("normal"), None, None, Some("fast"), None),
        (
            Some("fast"),
            Some("off"),
            Some("normal"),
            Some("normal"),
            None,
            Some("normal"),
            Some("team"),
        ),
        (
            Some("fast"),
            Some("off"),
            Some("normal"),
            Some("normal"),
            Some("off"),
            Some("off"),
            Some("device"),
        ),
        (None, None, None, None, Some("normal"), Some("normal"), Some("device")),
    ];
    for (mine, recommended, team_default, team_enforced, forced, expected, managed_by) in rows {
        let root = mine.map_or_else(
            || file("{}"),
            |v| file(&format!("{{\"ui\": {{\"animationSpeed\": \"{v}\"}}}}")),
        );
        let mut managed = ManagedPreferences::default();
        if let Some(v) = recommended {
            managed.recommended.insert(SPEED.into(), json!(v));
        }
        if let Some(v) = forced {
            managed.forced.insert(SPEED.into(), json!(v));
        }
        let mut team = TeamPolicyLayer { team_name: "Acme".into(), ..Default::default() };
        if let Some(v) = team_default {
            team.defaults.insert(SPEED.into(), json!(v));
        }
        if let Some(v) = team_enforced {
            team.enforced.insert(SPEED.into(), json!(v));
        }
        let result = merge(&root, &managed, &team);
        assert_eq!(result.root.pointer("/ui/animationSpeed").and_then(Value::as_str), expected);
        assert_eq!(result.file_root, root);
        match managed_by {
            Some("device") => {
                assert_eq!(result.managed_keys.get(SPEED), Some(&ManagedSource::Device));
            }
            Some("team") => assert_eq!(
                result.managed_keys.get(SPEED),
                Some(&ManagedSource::Team("Acme".into()))
            ),
            _ => assert!(result.managed_keys.is_empty()),
        }
        let overridden = mine.is_some() && managed_by.is_some() && mine != expected;
        let reported = result
            .diagnostics
            .iter()
            .any(|d| d.kind == DiagnosticKind::ManagedOverride && d.path == SPEED);
        assert_eq!(reported, overridden, "{mine:?} {forced:?}");
    }
}

#[test]
fn policy_keys_stay_out_of_the_settings_document() {
    let managed = ManagedPreferences {
        forced: map(&[("EnrollmentToken", json!("tok")), ("DisabledFeatures", json!(["mcp"]))]),
        recommended: map(&[("UpdateChannel", json!("nightly"))]),
    };
    let result = merge(&file("{\"a\": 1}"), &managed, &TeamPolicyLayer::default());
    assert_eq!(result.root, json!({"a": 1}));
    assert_eq!(
        result.policy.raw,
        map(&[("EnrollmentToken", json!("tok")), ("DisabledFeatures", json!(["mcp"]))])
    );
    assert_eq!(result.policy.enrollment_token.as_deref(), Some("tok"));
    assert!(result.policy.disables("mcp"));
    // Non-forced UpdateChannel is ignored: any local user can write it.
    assert_eq!(result.policy.update_channel, None);
    assert!(result.managed_keys.is_empty());
    assert_eq!(result.policy.to_json(true)["EnrollmentToken"], json!("<set>"));
}

#[test]
fn every_policy_key_is_typed() {
    let managed = ManagedPreferences {
        forced: map(&[
            ("EnrollmentToken", json!("  tok \n")),
            ("ManagedTeam", json!("team_1")),
            ("RestrictToManagedTeam", json!(true)),
            ("DisabledFeatures", json!(["cloud", "futureThing"])),
            ("UpdateChannel", json!("beta")),
            ("MinimumVersion", json!("1.2.0")),
            ("AllowedSignInMethods", json!(["sso"])),
            ("DisableAutoUpdate", json!("yes")),
        ]),
        recommended: BTreeMap::new(),
    };
    let result = merge(&file("{}"), &managed, &TeamPolicyLayer::default());
    let policy = &result.policy;
    assert_eq!(policy.enrollment_token.as_deref(), Some("tok"));
    assert_eq!(policy.managed_team.as_deref(), Some("team_1"));
    assert_eq!(policy.restrict_to_managed_team, Some(true));
    assert_eq!(
        policy.disabled_features,
        Some(vec!["cloud".to_string(), "futureThing".to_string()])
    );
    assert_eq!(policy.update_channel, None, "beta is not a channel");
    assert_eq!(policy.minimum_version.as_deref(), Some("1.2.0"));
    assert_eq!(policy.allowed_sign_in_methods, Some(vec!["sso".to_string()]));
    assert_eq!(policy.disable_auto_update, None, "a string is not a boolean");
    let invalid: Vec<&str> = result
        .diagnostics
        .iter()
        .filter(|d| d.kind == DiagnosticKind::InvalidValue)
        .map(|d| d.path.as_str())
        .collect();
    assert_eq!(invalid, ["UpdateChannel", "DisableAutoUpdate"]);
}

#[test]
fn forced_key_replaces_a_non_object_on_its_path() {
    let managed =
        ManagedPreferences { forced: map(&[(SPEED, json!("off"))]), ..Default::default() };
    let result = merge(&file("{\"ui\": 3}"), &managed, &TeamPolicyLayer::default());
    assert_eq!(result.root.pointer("/ui/animationSpeed"), Some(&json!("off")));
}

#[test]
fn an_mdm_value_that_overrides_the_team_policy_is_reported() {
    let managed =
        ManagedPreferences { forced: map(&[(SPEED, json!("off"))]), ..Default::default() };
    let team = TeamPolicyLayer {
        team_name: "Acme".into(),
        enforced: map(&[(SPEED, json!("normal"))]),
        ..Default::default()
    };
    let result = merge(&file("{}"), &managed, &team);
    assert_eq!(result.root.pointer("/ui/animationSpeed"), Some(&json!("off")));
    assert!(
        result
            .diagnostics
            .iter()
            .any(|d| d.kind == DiagnosticKind::ManagedConflict && d.path == SPEED)
    );
}

#[test]
fn the_team_layer_sets_only_catalog_settings() {
    let team = TeamPolicyLayer {
        team_name: "Acme".into(),
        enforced: map(&[
            ("appearance", json!({"borders": "none"})),
            ("shortcuts.bindings.tab.close", json!("cmd+w")),
            ("actions.evil", json!({"command": "rm"})),
            (SPEED, json!("normal")),
        ]),
        ..Default::default()
    };
    let result = merge(
        &file("{\"appearance\": {\"density\": \"comfortable\"}}"),
        &ManagedPreferences::default(),
        &team,
    );
    assert_eq!(result.root.pointer("/appearance/density"), Some(&json!("comfortable")));
    assert!(result.root.get("shortcuts").is_none());
    assert!(result.root.get("actions").is_none());
    assert_eq!(
        result.managed_keys,
        [(SPEED.to_string(), ManagedSource::Team("Acme".into()))].into_iter().collect()
    );
}

#[test]
fn device_policy_becomes_a_team_layer_only_when_managed() {
    let schema = Schema::embedded();
    let managed = json!({
        "managed": true, "team": "team_00000000000000000001", "team_name": "Acme", "version": 3,
        "defaults": {"layout.stripScrollbar": "always"},
        "enforced": {SPEED: "off", "telemetry.level": "crash_only", "NotASetting": true},
    });
    let layer = TeamPolicyLayer::from_device_policy(&managed, schema).unwrap();
    assert_eq!(
        layer,
        TeamPolicyLayer {
            team_name: "Acme".into(),
            defaults: map(&[("layout.stripScrollbar", json!("always"))]),
            enforced: map(&[(SPEED, json!("off"))]),
            team_id: "team_00000000000000000001".into(),
            version: 3,
        }
    );
    let unmanaged = json!({"managed": false, "enforced": {"telemetry.level": "off"}});
    assert_eq!(TeamPolicyLayer::from_device_policy(&unmanaged, schema), None);
}

/// Shared vector with backend/apps/api/test/team-enrollment.test.ts.
#[test]
fn enrollment_token_hash_matches_the_backend_vector() {
    assert_eq!(
        enrollment_token_hash("cmxe_shared_vector_v1"),
        "gBhFw31wF2LFrvU2l8Xgno2GFgrlOQQkj_hhy9_5fvw"
    );
    let forced = ManagedPreferences {
        forced: map(&[("EnrollmentToken", json!("  tok \n"))]),
        ..Default::default()
    };
    assert_eq!(forced.enrollment_token().as_deref(), Some("tok"));
    let local = ManagedPreferences {
        recommended: map(&[("EnrollmentToken", json!("planted"))]),
        ..Default::default()
    };
    assert_eq!(local.enrollment_token(), None);
    assert!(merge(&file("{}"), &local, &TeamPolicyLayer::default()).policy.raw.is_empty());
}

#[test]
fn plist_reader_splits_forced_and_recommended_and_keeps_types() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("managed.plist");
    let mut recommended = plist::Dictionary::new();
    recommended.insert("layout.stripScrollbar".into(), plist::Value::String("auto".into()));
    let mut root = plist::Dictionary::new();
    root.insert(SPEED.into(), plist::Value::String("off".into()));
    root.insert("layout.panePadding".into(), plist::Value::Integer(8.into()));
    root.insert("layout.ratio".into(), plist::Value::Real(0.5));
    root.insert("RestrictToManagedTeam".into(), plist::Value::Boolean(true));
    root.insert("Recommended".into(), plist::Value::Dictionary(recommended));
    plist::Value::Dictionary(root).to_file_xml(&path).unwrap();
    let read = PlistFileManagedReader { path }.read();
    assert_eq!(
        read.forced,
        map(&[
            (SPEED, json!("off")),
            ("layout.panePadding", json!(8)),
            ("layout.ratio", json!(0.5)),
            ("RestrictToManagedTeam", json!(true))
        ])
    );
    assert_eq!(read.recommended, map(&[("layout.stripScrollbar", json!("auto"))]));
    assert!(PlistFileManagedReader { path: dir.path().join("missing") }.read().is_empty());
}

#[test]
fn json_reader_reads_the_linux_layout() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("managed.json");
    std::fs::write(&path, r#"{"ui.animationSpeed": "off", "UpdateChannel": "stable", "Recommended": {"layout.panePadding": 8.0}}"#).unwrap();
    let reader = JsonFileManagedReader { path: path.clone() };
    let read = reader.read();
    assert_eq!(read.forced, map(&[(SPEED, json!("off")), ("UpdateChannel", json!("stable"))]));
    assert_eq!(read.recommended, map(&[("layout.panePadding", json!(8))]));
    assert_eq!(reader.watch_paths(), vec![path]);
    std::fs::write(dir.path().join("broken.json"), "{ nope").unwrap();
    assert!(JsonFileManagedReader { path: dir.path().join("broken.json") }.read().is_empty());
}

/// The CFPreferences reader runs against the real managed domain without
/// failing; on an unmanaged host it reads nothing forced.
#[cfg(target_os = "macos")]
#[test]
fn the_cf_reader_reads_the_managed_domain() {
    let reader = cmux_config::managed::CfManagedReader::new(Schema::embedded());
    assert!(reader.keys.iter().any(|key| key == "EnrollmentToken"));
    assert!(reader.keys.iter().any(|key| key == SPEED));
    let read = reader.read();
    assert!(read.forced.keys().chain(read.recommended.keys()).all(|key| reader.keys.contains(key)));
    assert!(
        reader.watch_paths().iter().all(|path| path.starts_with("/Library/Managed Preferences"))
    );
}
