//! Mirrors the app's SidebarLayoutReducerTests and SectionFlowTests reducer
//! cases, the shared fixture, L5 round trips, and a seeded property test for
//! invariants L1-L4 and the revision rule.

use super::*;
use serde_json::json;

fn op(value: Value) -> Op {
    serde_json::from_value(value).expect("op")
}

fn find<'a>(document: &'a Document, id: &str) -> &'a Section {
    document.sections.iter().find(|s| s.id == id).expect("section")
}

/// The cases shared with the app's reducer
/// (Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json).
#[test]
fn shared_cases_match_the_app() {
    let file: Value = serde_json::from_str(include_str!(
        "../../../../../Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json"
    ))
    .unwrap();
    let cases = file["cases"].as_array().unwrap();
    assert!(cases.len() >= 20);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let result = reduce(&defaults(), &op(case["op"].clone()));
        match (case["expect"].as_str().unwrap(), result) {
            ("accept", Ok(doc)) => {
                assert_eq!(doc.revision, case["revision"].as_u64().unwrap(), "{name}");
                if let Some(id) = case["section"].as_str() {
                    let section = find(&doc, id);
                    if let Some(items) = case["items"].as_array() {
                        let actual: Vec<_> = section.items.iter().map(|i| json!(i.id)).collect();
                        assert_eq!(&actual, items, "{name}");
                    }
                    if let Some(arrangement) = case.get("arrangement") {
                        assert_eq!(
                            &serde_json::to_value(&section.arrangement).unwrap(),
                            arrangement,
                            "{name}"
                        );
                    }
                }
            }
            ("reject", Err(reject)) => {
                assert_eq!(reject.as_str(), case["reason"].as_str().unwrap(), "{name}");
            }
            (expect, other) => panic!("{name}: expected {expect}, got {other:?}"),
        }
    }
}
