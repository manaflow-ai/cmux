use super::*;
use crate::schema::Schema;

fn checked_in(name: &str) -> &'static str {
    match name {
        "com.manaflow.cmux.plist" => {
            include_str!("../../../../../docs/mdm/com.manaflow.cmux.plist")
        }
        "com.manaflow.cmux.json" => include_str!("../../../../../docs/mdm/com.manaflow.cmux.json"),
        "cmux-example.mobileconfig" => {
            include_str!("../../../../../docs/mdm/cmux-example.mobileconfig")
        }
        "com.manaflow.cmux.intune.plist" => {
            include_str!("../../../../../docs/mdm/com.manaflow.cmux.intune.plist")
        }
        _ => include_str!("../../../../../docs/mdm/managed-preferences.md"),
    }
}

/// Swift `checkedInSchemaMatchesTheCatalog`: a new or changed setting fails
/// here until the files are regenerated.
#[test]
fn checked_in_schema_matches_the_catalog() {
    for (name, text) in files(Schema::embedded()) {
        let want = checked_in(name);
        if text != want {
            let line = text.lines().zip(want.lines()).position(|(a, b)| a != b);
            let at = line.unwrap_or_else(|| text.lines().count().min(want.lines().count()));
            panic!(
                "docs/mdm/{name} is stale at line {}: got {:?}, want {:?}",
                at + 1,
                text.lines().nth(at),
                want.lines().nth(at)
            );
        }
    }
}

/// Swift `everyCatalogKeyIsInTheSchemaWithItsType`.
#[test]
fn every_catalog_key_is_in_the_schema_with_its_type() {
    let schema = Schema::embedded();
    let entries = entries(schema);
    let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
    let mut unique = names.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), names.len());
    for key in POLICY_KEYS.iter() {
        assert!(names.contains(&key.name));
    }
    let toggles = schema.rows.iter().filter(|r| matches!(r.kind, crate::schema::Kind::Toggle));
    for row in toggles {
        if let Some(entry) = entries.iter().find(|e| e.name == row.key) {
            assert_eq!(entry.ty, "boolean", "{}", row.key);
        }
    }
}

/// Swift `exampleProfileIsAValidConfigurationProfile`.
#[test]
fn example_profile_is_a_valid_configuration_profile() {
    let schema = Schema::embedded();
    let entries = entries(schema);
    let profile = example_mobileconfig(&entries);
    assert!(profile.contains("<string>Configuration</string>"));
    assert!(profile.contains("<key>PayloadType</key>\n\t\t\t<string>com.manaflow.cmux</string>"));
    // Every non-payload key is a published key.
    let published = crate::managed::published_keys(schema);
    for key in example_keys(&entries).keys() {
        assert!(published.contains(key), "{key}");
    }
}

/// Swift `intuneFileHasNoPlistWrapper`.
#[test]
fn intune_file_has_no_plist_wrapper() {
    let text = intune_preference_file(&entries(Schema::embedded()));
    assert!(!text.contains("<plist"));
    assert!(!text.contains("<dict>\n<key>"));
    assert!(text.contains("<key>DisabledFeatures</key>"));
}

#[test]
fn reals_print_as_core_foundation_does() {
    assert_eq!(real_text(0.0), "0.0");
    assert_eq!(real_text(1.0), "1");
    assert_eq!(real_text(0.1), "0.10000000000000001");
    assert_eq!(real_text(1.5), "1.5");
    assert_eq!(real_text(1e20), "1e+20");
    assert_eq!(real_text(0.00001), "1.0000000000000001e-05");
}

#[test]
fn numbers_print_as_the_swift_writers_do() {
    assert_eq!(swift_double(0.00001), "1e-05");
    assert_eq!(swift_double(2.5), "2.5");
    assert_eq!(format_number(3.0), "3");
    assert_eq!(
        compact_text(&serde_json::json!({"b": [1, 2.5, "x"], "a": null})),
        r#"{"a":null,"b":[1,2.5,"x"]}"#
    );
}

#[test]
fn deterministic_json_orders_keys_without_case() {
    let value = serde_json::json!({"b": 1, "A": [], "a": {}});
    assert_eq!(
        deterministic_json(&value, true, 0),
        "{\n  \"A\" : [\n\n  ],\n  \"a\" : {\n\n  },\n  \"b\" : 1\n}"
    );
}
