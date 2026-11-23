use serde_json::json;

use super::*;
use crate::Schema;

/// The table's own rules: a rename lands on a real row, never on another
/// retired key (no chains, no cycles), an old key is never a live row, and a
/// window reads.
#[test]
fn the_table_renames_to_live_rows_with_no_chains() {
    let schema = Schema::embedded();
    let entries = retired_entries();
    for entry in entries {
        assert!(schema.row(&entry.key).is_none(), "{} is retired and a live row", entry.key);
        if let Some(to) = &entry.replaced_by {
            assert!(schema.row(to).is_some(), "{} is replaced by {to}, which is no row", entry.key);
            assert!(
                entries.iter().all(|other| other.key != *to),
                "{} -> {to}, which is retired too: a chain",
                entry.key
            );
        }
        for mark in [&entry.since, &entry.until].into_iter().flatten() {
            assert!(date(mark).is_some() || version(mark).is_some(), "{}: {mark}", entry.key);
        }
        if let (Some(since), Some(until)) = (&entry.since, &entry.until) {
            assert!(until > since, "{}: until {until} is not after since {since}", entry.key);
        }
    }
}

#[test]
fn a_plain_rename_moves_the_value_dotted_or_nested() {
    let old = "agentPane.display.inspector.placement";
    let new = "agentPane.display.sessionInfo.placement";
    for (written, at) in [
        (json!({ old: "overlay" }), json!({ new: "overlay" })),
        (
            json!({ "agentPane": { "display": { "inspector": { "placement": "overlay" } } } }),
            json!({ "agentPane": { "display": { "sessionInfo": { "placement": "overlay" } } } }),
        ),
        (
            json!({ "agentPane.display": { "inspector.placement": "overlay", "width": 760 } }),
            json!({
                "agentPane.display": { "width": 760 },
                "agentPane": { "display": { "sessionInfo": { "placement": "overlay" } } }
            }),
        ),
    ] {
        let (migrated, notices) = migrate(&written);
        assert_eq!(migrated, at, "{written}");
        assert_eq!(notices.len(), 1);
        let notice = &notices[0];
        assert_eq!((notice.from.as_str(), notice.to.as_deref()), (old, Some(new)));
        assert_eq!(notice.kind, NoticeKind::Renamed);
        assert_eq!(notice.until.as_deref(), Some("2027-01-01"));
        assert_eq!(notice.message(), format!("{old} is now {new} (until 2027-01-01)"));
    }
}

#[test]
fn a_mapped_value_moves_mapped_and_an_unmapped_one_is_dropped() {
    let (migrated, notices) = migrate(&json!({ "remote.ultraMode": true }));
    assert_eq!(migrated, json!({ "remote.ultra": "always" }));
    assert_eq!(notices[0].kind, NoticeKind::Renamed);

    let (migrated, notices) = migrate(&json!({ "remote": { "ultraMode": false, "x": 1 } }));
    assert_eq!(migrated, json!({ "remote": { "x": 1 } }), "false has no equivalent");
    assert_eq!(notices[0].kind, NoticeKind::Removed);
    assert_eq!(notices[0].to.as_deref(), Some("remote.ultra"));
    assert!(notices[0].message().contains("keeps its default"), "{}", notices[0].message());
}

#[test]
fn a_removed_key_is_dropped_with_its_reason() {
    let (migrated, notices) =
        migrate(&json!({ "tabs": { "terminalFirst": true }, "sidebar.side": "right" }));
    assert_eq!(migrated, json!({ "sidebar.side": "right" }), "the emptied tabs object goes too");
    assert_eq!(notices.len(), 1);
    assert_eq!(notices[0].kind, NoticeKind::Removed);
    assert_eq!(notices[0].to, None);
    assert!(notices[0].message().starts_with("tabs.terminalFirst was removed: "));
}

#[test]
fn the_new_name_wins_over_the_old_one() {
    let written =
        json!({ "sidebar.showCounts": false, "sidebar": { "workspaceRow": { "tabCount": true } } });
    let (migrated, notices) = migrate(&written);
    assert_eq!(migrated, json!({ "sidebar": { "workspaceRow": { "tabCount": true } } }));
    assert_eq!(notices[0].kind, NoticeKind::Renamed);
    assert!(notices[0].reason.contains("is set too"), "{}", notices[0].reason);
}

#[test]
fn nothing_retired_comes_back_as_it_was() {
    for written in
        [json!({ "sidebar": { "side": "right" }, "actions": {} }), json!([1]), json!(null)]
    {
        assert_eq!(migrate(&written), (written.clone(), Vec::new()));
    }
    let dotted: BTreeMap<String, Value> =
        [("sidebar.showWorkspaceDirectory".to_owned(), json!(false))].into_iter().collect();
    let (migrated, notices) = migrate_dotted(&dotted);
    assert_eq!(migrated.get("sidebar.workspaceRow.directory"), Some(&json!(false)));
    assert_eq!(notices.len(), 1);
}

#[test]
fn the_window_ends_after_its_date_or_at_its_version() {
    let notice = |until: &str| Notice {
        from: "a.b".into(),
        to: Some("a.c".into()),
        kind: NoticeKind::Renamed,
        reason: String::new(),
        since: None,
        until: Some(until.into()),
        old_value: None,
        new_value: None,
    };
    assert!(!notice("2027-01-01").window_ended("2027-01-01", "1.0.0"));
    assert!(notice("2027-01-01").window_ended("2027-01-02", "1.0.0"));
    assert!(!notice("0.90.0").window_ended("2027-01-02", "0.89.9"));
    assert!(notice("0.90.0").window_ended("2027-01-02", "0.90.0"));
    assert!(!notice("0.90.0").window_ended("2027-01-02", "0.0.0"), "an unstamped build");
    assert!(!Notice { until: None, ..notice("x") }.window_ended("2099-01-01", "9.0.0"));
}

/// A row's `aliases` (schemas/settings/source, compiled in by
/// `schema::aliases`): each names a live row, maps to a value the row
/// accepts, and an old value is one the row no longer takes.
#[test]
fn every_choice_alias_maps_to_a_value_its_row_accepts() {
    let schema = Schema::embedded();
    assert!(!choice_aliases().is_empty(), "updates.notify has card -> badge");
    for (key, aliases) in choice_aliases() {
        let row = schema.row(key).unwrap_or_else(|| panic!("{key} has aliases and is no row"));
        for (old, new) in aliases {
            let domains = Default::default();
            assert!(crate::schema::accepts(row, &json!(new), &domains).is_ok(), "{key}: {new}");
            assert!(crate::schema::accepts(row, &json!(old), &domains).is_err(), "{key}: {old}");
        }
    }
}

#[test]
fn a_renamed_choice_value_is_rewritten_dotted_or_nested() {
    for (written, at) in [
        (json!({ "updates.notify": "card" }), json!({ "updates.notify": "badge" })),
        (json!({ "updates": { "notify": "card" } }), json!({ "updates": { "notify": "badge" } })),
    ] {
        let (migrated, notices) = migrate(&written);
        assert_eq!(migrated, at);
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].kind, NoticeKind::RenamedValue);
        assert_eq!(notices[0].old_value, Some(json!("card")));
        assert_eq!(notices[0].new_value, Some(json!("badge")));
        assert_eq!(notices[0].message(), "updates.notify: \"card\" is now \"badge\"");
    }
    let current = json!({ "updates.notify": "silent" });
    assert_eq!(migrate(&current), (current.clone(), Vec::new()));
}

/// The daemon reads an old choice value as its replacement, with no diagnostic.
#[test]
fn the_daemon_reads_an_old_choice_value_as_its_replacement() {
    let row = Schema::embedded().row("updates.notify").expect("the row");
    let root = json!({ "updates": { "notify": "card" } });
    let read = crate::schema::effective_value(row, &root, &Default::default());
    assert_eq!(read, Some(json!("badge")));
}

/// Every section source's aliases are compiled in: a section that gains one
/// adds its file to `schema::aliases::SOURCES`.
#[test]
fn every_source_alias_is_compiled_in() {
    let dir =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/settings/source");
    let mut texts = Vec::new();
    for entry in std::fs::read_dir(&dir).expect("schemas/settings/source") {
        let path = entry.expect("an entry").path();
        if path.extension().is_some_and(|ext| ext == "json") {
            texts.push(std::fs::read_to_string(&path).expect("readable"));
        }
    }
    let on_disk = crate::schema::aliases::aliases_in(texts.iter().map(String::as_str));
    assert!(!on_disk.is_empty(), "updates.notify has card -> badge");
    assert_eq!(&on_disk, choice_aliases(), "add the section source to schema::aliases::SOURCES");
}
