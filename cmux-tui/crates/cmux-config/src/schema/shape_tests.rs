use serde_json::{Value, json};

use super::{check, matches};

fn lines() -> Value {
    json!({
        "type": "array",
        "maxItems": 3,
        "items": {
            "type": "array",
            "minItems": 1,
            "maxItems": 10,
            "uniqueItems": true,
            "items": { "enum": ["icon", "name", "branch", "directory"] },
        },
    })
}

fn by_name() -> Value {
    json!({
        "type": "object",
        "maxProperties": 2,
        "propertyNames": { "type": "string", "minLength": 1, "maxLength": 8 },
        "additionalProperties": lines(),
    })
}

#[test]
fn a_shape_with_a_keyword_the_validator_skips_is_refused() {
    assert!(check(&lines()).is_ok());
    assert!(check(&by_name()).is_ok());
    // A skipped keyword would accept what an editor refuses.
    for bad in [
        json!({ "type": "string", "pattern": "^a" }),
        json!({ "$ref": "#/$defs/line" }),
        json!({ "type": "array", "items": { "anyOf": [{ "type": "string" }] } }),
        json!({ "type": "object", "properties": { "a": { "format": "uri" } } }),
        json!({ "type": "strings" }),
        json!({ "maxItems": -1 }),
        json!("array"),
    ] {
        assert!(check(&bad).is_err(), "{bad}");
    }
    // Annotations carry no rule.
    assert!(check(&json!({ "type": "array", "title": "Lines", "description": "x" })).is_ok());
}

#[test]
fn nested_lists_are_checked_member_by_member_with_a_path() {
    let shape = lines();
    assert!(matches(&shape, &json!([])).is_ok());
    assert!(matches(&shape, &json!([["icon", "name"], ["branch"]])).is_ok());
    assert_eq!(matches(&shape, &json!("name")), Err("expected an array".to_owned()));
    assert_eq!(
        matches(&shape, &json!([["name"], "branch"])),
        Err("[1]: expected an array".to_owned())
    );
    assert_eq!(
        matches(&shape, &json!([["name", "nope"]])),
        Err("[0][1]: not one of the allowed values".to_owned())
    );
    assert_eq!(matches(&shape, &json!([["name", "name"]])), Err("[0][1]: repeated".to_owned()));
    assert_eq!(matches(&shape, &json!([[]])), Err("[0]: too few items".to_owned()));
    assert_eq!(
        matches(&shape, &json!([["name"], ["icon"], ["branch"], ["directory"]])),
        Err("more than 3 items".to_owned())
    );
}

#[test]
fn maps_check_their_names_and_members() {
    let shape = by_name();
    assert!(matches(&shape, &json!({})).is_ok());
    assert!(matches(&shape, &json!({ "claude": [["name"]] })).is_ok());
    assert_eq!(matches(&shape, &json!([])), Err("expected an object".to_owned()));
    assert_eq!(
        matches(&shape, &json!({ "claude": [["nope"]] })),
        Err(".claude[0][0]: not one of the allowed values".to_owned())
    );
    assert_eq!(matches(&shape, &json!({ "": [] })), Err(".: not an allowed name".to_owned()));
    assert_eq!(
        matches(&shape, &json!({ "a": [], "b": [], "c": [] })),
        Err("more than 2 members".to_owned())
    );
}

#[test]
fn properties_required_and_closed_objects() {
    let shape = json!({
        "type": "object",
        "required": ["id"],
        "properties": { "id": { "type": "string" }, "size": { "type": "integer" } },
        "additionalProperties": false,
    });
    assert!(check(&shape).is_ok());
    assert!(matches(&shape, &json!({ "id": "a", "size": 2.0 })).is_ok());
    assert_eq!(matches(&shape, &json!({ "size": 2 })), Err("id is required".to_owned()));
    assert_eq!(
        matches(&shape, &json!({ "id": "a", "size": 2.5 })),
        Err(".size: expected an integer".to_owned())
    );
    assert_eq!(matches(&shape, &json!({ "id": "a", "x": 1 })), Err(".x: not allowed".to_owned()));
}

/// The owner and an editor's full draft 2020-12 validator agree on every
/// shape the validator takes: the editor schema is the owner's check.
#[test]
fn agrees_with_a_full_json_schema_validator() {
    let values = [
        json!(null),
        json!("name"),
        json!(1),
        json!([]),
        json!({}),
        json!([[]]),
        json!([["name"]]),
        json!([["icon", "name"], ["branch", "directory"]]),
        json!([["name", "name"]]),
        json!([["name"], ["icon"], ["branch"], ["directory"]]),
        json!([["name", 1]]),
        json!([["name", "x"]]),
        json!([["icon", "name", "branch", "directory", "icon"]]),
        json!({ "claude": [["name"]] }),
        json!({ "claude": [["nope"]] }),
        json!({ "": [] }),
        json!({ "toolongname": [] }),
        json!({ "a": [], "b": [], "c": [] }),
        json!({ "a": "name" }),
        json!({ "id": "a", "size": 2.0 }),
        json!({ "id": "a", "size": 2.5 }),
        json!({ "id": "a", "x": 1 }),
        json!({ "size": 1 }),
    ];
    let shapes = [
        lines(),
        by_name(),
        json!({
            "type": "object",
            "required": ["id"],
            "properties": { "id": { "type": "string" }, "size": { "type": "integer" } },
            "additionalProperties": false,
        }),
        json!({ "type": ["string", "null"], "minLength": 2 }),
        json!({ "const": [["name"]] }),
    ];
    for shape in &shapes {
        assert!(check(shape).is_ok(), "{shape}");
        let full = jsonschema::validator_for(shape).expect("compiles");
        for value in &values {
            assert_eq!(
                matches(shape, value).is_ok(),
                full.is_valid(value),
                "shape {shape} value {value}: {:?}",
                matches(shape, value)
            );
        }
    }
}
