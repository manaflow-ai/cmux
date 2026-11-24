use super::*;

fn app(id: &str, name: &str, categories: &[&str], date_ms: Option<i64>) -> Shelved {
    Shelved {
        id: id.into(),
        name: name.to_lowercase(),
        categories: categories.iter().map(|c| c.to_string()).collect(),
        date_ms,
    }
}

/// Featured keeps the curated order first, recent the newest version
/// first, and every category on the shelf gets its section by name.
#[test]
fn sections_come_in_their_order_with_l10n_keys() {
    let sections = all_sections(vec![
        app("acme/zeta", "Zeta", &["productivity"], Some(30)),
        app("cmux/coderouter", "CodeRouter", &["developer-tools"], Some(10)),
        app("acme/alpha", "Alpha", &["productivity", "developer-tools"], None),
        app("cmux/cloud", "Cloud", &["cloud", "developer-tools"], Some(20)),
    ]);
    let value = serde_json::to_value(&sections).unwrap();
    assert_eq!(
        value,
        json!([
            { "id": "featured", "kind": "featured", "title_key": "apps.store.section.featured",
              "apps": ["cmux/cloud", "cmux/coderouter", "acme/alpha", "acme/zeta"] },
            { "id": "recent", "kind": "recent", "title_key": "apps.store.section.recent",
              "apps": ["acme/zeta", "cmux/cloud", "cmux/coderouter"] },
            { "id": "category:cloud", "kind": "category", "category": "cloud",
              "title_key": "apps.store.category.cloud", "apps": ["cmux/cloud"] },
            { "id": "category:developer-tools", "kind": "category",
              "category": "developer-tools", "title_key": "apps.store.category.developer-tools",
              "apps": ["acme/alpha", "cmux/cloud", "cmux/coderouter"] },
            { "id": "category:productivity", "kind": "category", "category": "productivity",
              "title_key": "apps.store.category.productivity",
              "apps": ["acme/alpha", "acme/zeta"] },
        ])
    );
}

#[test]
fn a_page_names_the_cursor_of_the_next_one() {
    let section = || Section {
        id: "featured".into(),
        kind: SectionKind::Featured,
        title_key: "k".into(),
        apps: ["a", "b", "c"].map(String::from).to_vec(),
        next_cursor: None,
        category: None,
    };
    let first = page(section(), 0, 2);
    assert_eq!(
        (first.apps.clone(), first.next_cursor.as_deref()),
        (vec!["a".into(), "b".into()], Some("2"))
    );
    let last = page(section(), 2, 2);
    assert_eq!((last.apps, last.next_cursor), (vec!["c".to_string()], None));
    let past = page(section(), usize::MAX, 2);
    assert_eq!((past.apps.len(), past.next_cursor), (0, None));
}
