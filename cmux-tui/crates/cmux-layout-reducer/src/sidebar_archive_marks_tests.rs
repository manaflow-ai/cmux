//! Mirrors the Swift tests of what auto-archive reads off the records (AutoArchiveCoordinatorTests'
//! theArchivedListShowsWhatIsArchivedLastUsedFirst, BulkArchiveByHandTests' pinnedAndArchivedRowsStay
//! and nothingToArchiveSendsNothing) on the rules alone.

use super::*;

fn row(section: &str, parent: Option<&str>) -> Record {
    Record { section: section.into(), parent: parent.map(Into::into), ..Record::default() }
}

fn records(list: Vec<(&str, Record)>) -> Records {
    list.into_iter().map(|(id, record)| (id.to_string(), record)).collect()
}

fn items(ids: &[&str]) -> Vec<Option<String>> {
    ids.iter().map(|id| Some(id.to_string())).collect()
}

#[test]
fn pinned_and_archived_rows_stay() {
    let mut list = records(vec![
        ("itm_a", row("sec_m_s", None)),
        ("itm_b", Record { pinned_in_group: true, ..row("sec_m_s", None) }),
        ("itm_c", Record { archived: true, ..row("sec_m_s", None) }),
        ("itm_d", row("sec_m_s", None)),
        ("itm_p", row(PINNED_SECTION, None)),
    ]);
    let all = items(&["itm_a", "itm_b", "itm_c", "itm_d", "itm_p", "itm_a"]);
    assert_eq!(archivable(&list, &all), ["itm_a", "itm_d"], "once each, pins and archives stay");
    list.insert("g".into(), Record { group: true, archived: true, ..row("sec_m_s", None) });
    list.insert("itm_e".into(), row("sec_m_s", Some("g")));
    assert_eq!(
        archivable(&list, &items(&["itm_e"])),
        Vec::<String>::new(),
        "under an archived group"
    );
}

#[test]
fn nothing_to_archive_sends_nothing() {
    let list = records(vec![("itm_a", Record { pinned_in_group: true, ..row("s", None) })]);
    let named = vec![Some("itm_a".to_string()), None, Some("unplaced".to_string())];
    assert!(archivable(&list, &named).is_empty());
}

#[test]
fn the_archived_list_shows_what_is_archived_last_used_first() {
    let list = records(vec![
        ("g", Record { group: true, archived: true, ..row("s", None) }),
        ("old", Record { archived: true, ..row("s", None) }),
        ("older", Record { archived: true, ..row("s", None) }),
        ("under", row("s", Some("g"))),
        ("live", row("s", None)),
    ]);
    let used = |item: &str, last_active, seen| Used { item: item.into(), last_active, seen };
    let candidates = vec![
        used("older", Some(10.0), None),
        used("live", Some(99.0), None),
        used("never", None, None),
        used("old", Some(5.0), Some(30.0)),
        used("under", None, None),
    ];
    let rows = archived(&list, &candidates);
    let order: Vec<usize> = rows.iter().map(|row| row.index).collect();
    assert_eq!(order, [3, 0, 4], "the later of use and sight; never used last");
    assert_eq!(rows[0].last_active, Some(30.0));
}

#[test]
fn groups_list_nearest_first_and_stop_at_a_cycle_or_the_depth() {
    let list = records(vec![
        ("w", row("s", Some("g1"))),
        ("g1", row("s", Some("g2"))),
        ("g2", row("s", Some("g1"))),
    ]);
    assert_eq!(groups_of(&list, "w"), ["g1", "g2"]);
    let mut deep: Records =
        (0..30).map(|i| (format!("g{i}"), row("s", Some(&format!("g{}", i + 1))))).collect();
    deep.insert("w".into(), row("s", Some("g0")));
    assert_eq!(groups_of(&deep, "w").len(), MAX_DEPTH);
    assert!(groups_of(&deep, "missing").is_empty());
}

#[test]
fn the_plan_marks_shown_archived_pinned_and_groups_and_reads_group_rules() {
    let list = records(vec![
        ("g", Record { group: true, auto_archive: Some(json!(24)), ..row(PINNED_SECTION, None) }),
        ("h", Record { group: true, ..row("s", None) }),
        ("n", Record { auto_archive: Some(json!("never")), ..row("s", None) }),
        ("a", Record { archived: true, ..row("s", Some("g")) }),
        ("p", row(PINNED_SECTION, None)),
    ]);
    let candidate = |item: &str, workspace: &str| Candidate {
        item: item.into(),
        workspace: workspace.into(),
        ..Candidate::default()
    };
    let shown = BTreeSet::from(["wp".to_string()]);
    let marked = marks(&list, &[candidate("a", "wa"), candidate("p", "wp")], &shown);
    assert_eq!(marked[0], Marked { archived: true, groups: vec!["g".into()], ..Marked::default() });
    assert_eq!(marked[1], Marked { shown: true, pinned: true, ..Marked::default() });
    assert_eq!(rules(&list), BTreeMap::from([("g".to_string(), json!(24))]), "groups only");
    assert!(is_pinned_group(&list, "g") && !is_pinned_group(&list, "p") && !is_pinned(&list, "a"));
}
