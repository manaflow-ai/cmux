//! Remote groups (plans/cmux-next/remote-groups-DESIGN.md slice 4): a machine
//! section marked `host_group` is a remote group, drawn with its header (host
//! name and status) even when the sidebar is one list. Only a machine section
//! can be one.

use super::reduce::{apply_in_place, check, repair};
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

fn update_with_opt_out(id: &str, host_group: bool, host_group_opt_out: bool) -> Op {
    Op::SectionUpdate {
        id: id.into(),
        patch: SectionPatch {
            host_group: Some(host_group),
            host_group_opt_out: Some(host_group_opt_out),
            ..SectionPatch::default()
        },
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
    assert!(!doc.section(&id).unwrap().host_group_opt_out);
    check(&doc).unwrap();
    apply(&mut doc, &[update(&id, false)]).unwrap();
    assert!(!doc.section(&id).unwrap().host_group);
    assert!(doc.section(&id).unwrap().host_group_opt_out);
}

#[test]
fn only_a_machine_section_is_a_remote_group() {
    let mut doc = doc();
    assert_eq!(apply(&mut doc, &[update("sec_custom", true)]), Err(Refusal::InvalidValue));
}

#[test]
fn false_host_group_patch_is_harmless_on_a_custom_section() {
    let mut doc = doc();
    let before = doc.section("sec_custom").unwrap().clone();
    apply(&mut doc, &[update("sec_custom", false)]).unwrap();
    assert_eq!(doc.section("sec_custom").unwrap(), &before);
    assert_eq!(apply(&mut doc, &[update("sec_custom", true)]), Err(Refusal::InvalidValue));
    assert_eq!(doc.section("sec_custom").unwrap(), &before);
    check(&doc).unwrap();
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

#[test]
fn host_group_opt_out_survives_false_host_group() {
    let mut doc = doc();
    let id = machine_section_id("mini");
    apply(&mut doc, &[update_with_opt_out(&id, false, true)]).unwrap();
    let section = doc.section(&id).unwrap();
    assert!(!section.host_group);
    assert!(section.host_group_opt_out);

    let wire = serde_json::to_value(section).unwrap();
    assert_eq!(wire["host_group_opt_out"], serde_json::Value::Bool(true));
    let back: Section = serde_json::from_value(wire).unwrap();
    assert!(!back.host_group);
    assert!(back.host_group_opt_out);

    // New Remote Group explicitly clears a prior Remove choice.
    apply(&mut doc, &[update_with_opt_out(&id, true, false)]).unwrap();
    let section = doc.section(&id).unwrap();
    assert!(section.host_group);
    assert!(!section.host_group_opt_out);
}

#[test]
fn host_group_opt_out_is_machine_only() {
    let mut doc = doc();
    assert_eq!(
        apply(
            &mut doc,
            &[Op::SectionUpdate {
                id: "sec_custom".into(),
                patch: SectionPatch { host_group_opt_out: Some(true), ..SectionPatch::default() },
            }],
        ),
        Err(Refusal::InvalidValue)
    );

    let mut custom = Section::new("sec_added", SectionKind::Custom, Region::Middle);
    custom.host_group_opt_out = true;
    assert_eq!(
        apply(&mut doc, &[Op::SectionAdd { section: custom, place: SectionPlace::default() }],),
        Err(Refusal::InvalidValue)
    );
}

#[test]
fn host_group_and_opt_out_cannot_both_be_set() {
    let mut doc = doc();
    let id = machine_section_id("mini");
    assert_eq!(
        apply(&mut doc, &[update_with_opt_out(&id, true, true)]),
        Err(Refusal::InvalidValue)
    );
}

#[test]
fn repair_normalizes_invalid_host_group_flags() {
    let (mut sections, items) = doc().to_parts();
    let mini = machine_section_id("mini");
    let mini_section = sections.iter_mut().find(|section| section.id == mini).unwrap();
    mini_section.host_group = true;
    mini_section.host_group_opt_out = true;
    sections.iter_mut().find(|section| section.id == "sec_custom").unwrap().host_group_opt_out =
        true;
    let mut doc = Doc::from_parts(1, sections, items);
    assert!(repair(&mut doc));
    assert!(!doc.section(&mini).unwrap().host_group);
    assert!(doc.section(&mini).unwrap().host_group_opt_out);
    assert!(!doc.section("sec_custom").unwrap().host_group);
    assert!(!doc.section("sec_custom").unwrap().host_group_opt_out);
    check(&doc).unwrap();
}
