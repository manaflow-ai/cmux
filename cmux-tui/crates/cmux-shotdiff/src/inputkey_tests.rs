use super::*;
use serde_json::json;

fn fam(paths: &[&str]) -> Family {
    Family::from_value("f", &json!({"paths": paths})).unwrap()
}

#[test]
fn globs() {
    let f = fam(&["app/**", "!**/*.md", "Cargo.toml", "pkg/*/Sources/**", "!pkg/**/Tests/**"]);
    assert!(f.wants("app/a.swift"));
    assert!(f.wants("app/deep/b.swift"));
    assert!(!f.wants("app"));
    assert!(!f.wants("app/README.md"));
    assert!(!f.wants("README.md"));
    assert!(f.wants("Cargo.toml"));
    assert!(!f.wants("x/Cargo.toml"));
    assert!(f.wants("pkg/Kit/Sources/a.swift"));
    assert!(!f.wants("pkg/Kit/Sources/Tests/a.swift"));
    assert!(!f.wants("pkg/Kit/Other/a.swift"));
    assert!(glob_name(b"a?c*", b"abcdef"));
    assert!(!glob_name(b"a?c", b"ac"));
}

#[test]
fn rejects_bad_families() {
    assert!(Family::from_value("f", &json!({"paths": ["!x"]})).is_err());
    assert!(Family::from_value("f", &json!({"paths": []})).is_err());
    assert!(Family::from_value("F", &json!({"paths": ["x"]})).is_err());
    assert!(Family::from_value("f", &json!({"paths": ["x"], "extra": 1})).is_err());
    assert!(Family::from_value("f", &json!({"paths": ["/x"]})).is_err());
}

#[test]
fn variants() {
    let f =
        Family::from_value("f", &json!({"paths": ["x"], "variants": ["iphone", "ipad"]})).unwrap();
    assert_eq!(f.variant(Some("ipad")).unwrap(), "ipad");
    assert!(f.variant(Some("duo")).is_err());
    assert!(f.variant(None).is_err());
    assert_eq!(fam(&["x"]).variant(None).unwrap(), "default");
}

#[test]
fn key_moves_only_with_inputs() {
    let f = fam(&["app/**", "!**/*.md"]);
    let rows = |blob: &'static str, doc: &'static str| {
        vec![
            ("100644", blob, "app/a.swift"),
            ("100644", doc, "app/README.md"),
            ("100644", "z", "other.rs"),
        ]
    };
    let a = f.key_over("default", rows("b1", "d1")).unwrap();
    assert_eq!(a.files, 1);
    assert_eq!(
        a,
        f.key_over("default", rows("b1", "d2")).unwrap(),
        "an excluded file moved the key"
    );
    assert_ne!(a.key, f.key_over("default", rows("b2", "d1")).unwrap().key);
    assert_ne!(a.key, f.key_over("other", rows("b1", "d1")).unwrap().key, "variant is in the key");
    let g = fam(&["app/**"]);
    assert_ne!(
        a.key,
        g.key_over("default", rows("b1", "d1")).unwrap().key,
        "the family entry is in the key"
    );
    assert!(f.key_over("default", vec![("100644", "z", "other.rs")]).is_err());
}

#[test]
fn canonical_is_format_independent() {
    let a: Value = serde_json::from_str(r#"{"b": [1, {"y": 2, "x": "é"}], "a": true}"#).unwrap();
    let b: Value = serde_json::from_str(r#"{"a":true,"b":[1,{"x":"é","y":2}]}"#).unwrap();
    assert_eq!(canonical_json(&a), canonical_json(&b));
    assert_eq!(canonical_json(&a), r#"{"a":true,"b":[1,{"x":"é","y":2}]}"#);
}

#[test]
fn store_path() {
    let k =
        InputKey { family: "ios-gate".into(), variant: "ipad".into(), key: "ab".into(), files: 1 };
    assert_eq!(key_store_path("s3://b/goldens/", &k), "s3://b/goldens/ios-gate/ipad/ab");
}
