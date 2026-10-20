//! Remote groups (plans/cmux-next/remote-groups-DESIGN.md slice 4): a machine
//! section marked `host_group` is a remote group, drawn with its header (host
//! name and status) even when the sidebar is one list. Only a machine section
//! can be one.

use super::reduce::{apply_in_place, check};
use super::*;

fn doc() -> Doc {
    let mut custom = Section::new("sec_custom", SectionKind::Custom, Region::Middle);
    custom.order = "c".into();
    let mut mini = Section::machine("mini");
    mini.order = "a".into();
    Doc::from_parts(1, vec![mini, custom], vec![])
}

fn update(id: &str, host_group: bool) -> Op {
    Op::SectionUpdate {
        id: id.into(),
        patch: SectionPatch { host_group: Some(host_group), ..SectionPatch::default() },
    }
}

fn apply(doc: &mut Doc, ops: &[Op]) -> Result<(), Refusal> {
    apply_in_place(doc, ops, &mut || "itm_x".to_string()).map(|_| ())
}

#[test]
fn a_machine_section_becomes_a_remote_group_and_back() {
    let mut doc = doc();
    let id = machine_section_id("mini");
    assert!(!doc.section(&id).unwrap().host_group, "not a remote group by default");
    apply(&mut doc, &[update(&id, true)]).unwrap();
    assert!(doc.section(&id).unwrap().host_group);
    check(&doc).unwrap();
    apply(&mut doc, &[update(&id, false)]).unwrap();
    assert!(!doc.section(&id).unwrap().host_group);
}

#[test]
fn only_a_machine_section_is_a_remote_group() {
    let mut doc = doc();
    assert_eq!(apply(&mut doc, &[update("sec_custom", true)]), Err(Refusal::InvalidValue));
}

#[test]
fn host_group_is_on_the_wire_only_when_set() {
    let mut section = Section::machine("mini");
    let plain = serde_json::to_value(&section).unwrap();
    assert!(plain.get("host_group").is_none());
    section.host_group = true;
    let wire = serde_json::to_value(&section).unwrap();
    assert_eq!(wire["host_group"], serde_json::Value::Bool(true));
    let back: Section = serde_json::from_value(wire).unwrap();
    assert!(back.host_group);
}
