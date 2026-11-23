use super::super::mirror::Tier;
use super::*;
use cmux_layout_reducer::sidebar_doc::reduce;

fn package() -> Package {
    Package {
        id: "local/customize".into(),
        version: "1.0.0".into(),
        tier: Tier::Unverified,
        source: Source::Local,
        dir: Default::default(),
        manifest: json!({"implements": {"cmux.section/1": {
            "export": "render", "title": "Recent PRs",
            "options": {"defaultRegion": "bottom", "maxRows": 8}
        }}}),
        fragment: None,
    }
}

fn connection() -> Connection {
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        .unwrap();
    connection
}

fn apply(doc: &mut Doc, ops: &[Op]) {
    reduce::apply_in_place(doc, ops, &mut || "unused".into()).unwrap();
}

#[test]
fn customize_bottom_is_placed_once_and_removal_survives_reload_and_restart() {
    let mut connection = connection();
    let sections = sections(&package());
    let id = sections[0].id.clone();
    let mut doc = Doc::from_parts(0, vec![], vec![]);
    let tx = connection.transaction().unwrap();
    let ops = placement_ops(&tx, &doc, &sections, true).unwrap();
    apply(&mut doc, &ops);
    tx.commit().unwrap();
    assert_eq!(doc.section(&id).unwrap().region, Region::Bottom);
    assert_eq!(doc.section(&id).unwrap().max_rows, Some(8));
    apply(&mut doc, &[Op::SectionRemove { id: id.clone() }]);
    // Re-read the durable receipt in a new transaction. No process-local
    // placement set can bring the person's removed section back.
    for _ in 0..2 {
        let tx = connection.transaction().unwrap();
        assert!(placement_ops(&tx, &doc, &sections, true).unwrap().is_empty());
        tx.commit().unwrap();
    }
    assert!(doc.section(&id).is_none());
    let tx = connection.transaction().unwrap();
    let restore = placement_ops(&tx, &doc, &sections, false).unwrap();
    apply(&mut doc, &restore);
    tx.commit().unwrap();
    assert!(doc.section(&id).is_some(), "explicit placement restores it");
}

#[test]
fn automatic_placement_preserves_a_move_and_adopts_an_existing_contribution() {
    let mut connection = connection();
    let sections = sections(&package());
    let mut existing = sections[0].clone();
    existing.id = "sec_persons_section".into();
    existing.region = Region::Top;
    existing.order = "a0".into();
    let doc = Doc::from_parts(0, vec![existing.clone()], vec![]);
    let tx = connection.transaction().unwrap();
    assert!(placement_ops(&tx, &doc, &sections, true).unwrap().is_empty());
    tx.commit().unwrap();
    let tx = connection.transaction().unwrap();
    assert!(placement_ops(&tx, &doc, &sections, true).unwrap().is_empty());
    assert_eq!(doc.section(&existing.id).unwrap().region, Region::Top);
    assert!(matches!(placement_ops(&tx, &doc, &sections, false).unwrap().as_slice(),
        [Op::SectionMove { id, .. }] if id == &existing.id));
}

#[test]
fn a_failed_document_transaction_does_not_record_placement() {
    let mut connection = connection();
    let sections = sections(&package());
    let doc = Doc::from_parts(0, vec![], vec![]);
    {
        let tx = connection.transaction().unwrap();
        assert_eq!(placement_ops(&tx, &doc, &sections, true).unwrap().len(), 1);
        // Dropping a rejected document transaction rolls back the receipt too.
    }
    let tx = connection.transaction().unwrap();
    assert_eq!(placement_ops(&tx, &doc, &sections, true).unwrap().len(), 1);
}

#[test]
fn v1_contribution_ids_and_v2_interface_ids_match_the_scene_provider() {
    let mut app = package();
    app.manifest = json!({"contributes": {"sidebarSections": [
        {"id":"prs", "title":{"en":"PRs"}, "defaultRegion":"bottom", "render":"render"},
        {"id":"other", "title":"Other", "render":"render"}
    ]}});
    let sections = sections(&app);
    assert!(
        matches!(&sections[0].kind, SectionKind::App { contribution } if contribution == "local/customize#prs")
    );
    assert_eq!(sections[0].region, Region::Bottom);
    assert_eq!(sections[1].region, Region::Middle);
}

/// A repeated contribution id gives one section, the first entry's
/// (base red: each entry gave a section with the same hashed id, and a
/// placement of both added one id twice).
#[test]
fn a_repeated_section_id_gives_one_section() {
    let mut app = package();
    app.manifest = json!({"contributes": {"sidebarSections": (0..200)
        .map(|i| json!({"id": format!("s{}", i % 7), "title": "T", "defaultRegion": if i < 7 { "bottom" } else { "top" }, "render": "render"}))
        .collect::<Vec<_>>()}});
    let sections = sections(&app);
    assert_eq!(sections.len(), 7);
    let ids: std::collections::HashSet<&str> = sections.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids.len(), 7);
    assert!(sections.iter().all(|s| s.region == Region::Bottom), "the first entry wins");
}
