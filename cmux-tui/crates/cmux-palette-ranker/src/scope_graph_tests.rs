use super::*;

fn scope(id: &str, prefix: Option<&str>, keywords: &[&str], parents: Parents) -> Descriptor {
    Descriptor {
        id: id.into(),
        title: id.into(),
        symbol: "command".into(),
        placeholder: String::new(),
        prefix: prefix.map(str::to_string),
        keywords: keywords.iter().map(|k| k.to_string()).collect(),
        parents,
        empty_query_selection: 0,
        open_action: None,
        owner: "client".into(),
    }
}

fn root() -> Descriptor {
    let mut root = scope("ignored", Some(">"), &["all"], Parents::Anywhere {});
    root.title = "Commands".into();
    root.empty_query_selection = 2;
    root
}

#[test]
fn the_root_has_no_prefix_keyword_or_parent() {
    let graph = Graph::build(root(), vec![]);
    let root = graph.descriptor(ROOT).unwrap();
    assert_eq!(root.id, ROOT);
    assert_eq!(root.prefix, None);
    assert!(root.keywords.is_empty());
    assert_eq!(root.parents, Parents::Only { scopes: vec![] });
    assert_eq!(root.title, "Commands");
    assert_eq!(root.empty_query_selection, 2);
}

#[test]
fn reserved_and_duplicate_ids_are_refused() {
    let graph = Graph::build(
        root(),
        vec![
            scope("root", None, &[], Parents::Root {}),
            scope("tabs", None, &[], Parents::Root {}),
            scope("tabs", Some("%"), &[], Parents::Root {}),
        ],
    );
    assert_eq!(graph.scopes.len(), 1);
    assert_eq!(
        graph.problems,
        vec![Problem::ReservedId { id: "root".into() }, Problem::DuplicateId { id: "tabs".into() }]
    );
}

#[test]
fn prefixes_are_one_punctuation_or_symbol_scalar() {
    for valid in ["%", ">", "@", "#", "/", "€", "+", "^"] {
        assert!(is_valid_prefix(valid), "{valid}");
    }
    for invalid in ["", "a", "1", " ", "%%", "é", "e\u{301}", "\t"] {
        assert!(!is_valid_prefix(invalid), "{invalid:?}");
    }
    let graph = Graph::build(root(), vec![scope("tabs", Some("t"), &[], Parents::Root {})]);
    assert_eq!(graph.scopes[0].prefix, None);
    assert_eq!(
        graph.problems,
        vec![Problem::InvalidPrefix { id: "tabs".into(), prefix: "t".into() }]
    );
}

#[test]
fn a_later_scope_loses_a_colliding_prefix_or_keyword_only_where_parents_overlap() {
    let graph = Graph::build(
        root(),
        vec![
            scope("tabs", Some("%"), &["tabs", "t"], Parents::Root {}),
            scope("other", Some("%"), &["tabs", "o", "o", ""], Parents::Anywhere {}),
            scope("nested", Some("%"), &["t"], Parents::Only { scopes: vec!["tabs".into()] }),
        ],
    );
    assert_eq!(graph.scopes[1].prefix, None);
    assert_eq!(graph.scopes[1].keywords, vec!["o"]);
    assert_eq!(graph.scopes[2].prefix.as_deref(), Some("%"));
    assert_eq!(graph.scopes[2].keywords, vec!["t"]);
    assert_eq!(
        graph.problems,
        vec![
            Problem::PrefixCollision {
                id: "other".into(),
                with: "tabs".into(),
                prefix: "%".into()
            },
            Problem::KeywordCollision {
                id: "other".into(),
                with: "tabs".into(),
                keyword: "tabs".into()
            },
        ]
    );
}

#[test]
fn parents_overlap_like_swift() {
    let only = |s: &[&str]| Parents::Only { scopes: s.iter().map(|x| x.to_string()).collect() };
    assert!(Parents::Anywhere {}.overlaps(&only(&[])));
    assert!(Parents::Root {}.overlaps(&Parents::Root {}));
    assert!(Parents::Root {}.overlaps(&only(&["root"])));
    assert!(!Parents::Root {}.overlaps(&only(&["tabs"])));
    assert!(only(&["a", "b"]).overlaps(&only(&["b"])));
    assert!(!only(&["a"]).overlaps(&only(&["b"])));
}

#[test]
fn lookups_follow_registration_order_and_parents() {
    let graph = Graph::build(
        root(),
        vec![
            scope("tabs", Some("%"), &["tabs"], Parents::Root {}),
            scope(
                "actions",
                Some(">"),
                &["actions"],
                Parents::Only { scopes: vec!["tabs".into()] },
            ),
        ],
    );
    assert_eq!(graph.child_by_prefix(ROOT, "%").map(|d| d.id.as_str()), Some("tabs"));
    assert!(graph.child_by_prefix(ROOT, ">").is_none());
    assert_eq!(graph.child_by_prefix("tabs", ">").map(|d| d.id.as_str()), Some("actions"));
    assert_eq!(graph.child_by_keyword(ROOT, "  TaBs\t").map(|d| d.id.as_str()), Some("tabs"));
    assert!(graph.child_by_keyword(ROOT, "   ").is_none());
    assert!(graph.contains(ROOT) && graph.contains("actions") && !graph.contains("nope"));
}

#[test]
fn the_json_is_swifts_synthesized_codable() {
    let json = r#"{"id":"tabs","title":"Tabs","symbol":"square","placeholder":"Search","prefix":"%",
        "keywords":["tabs"],"parents":{"only":{"_0":["root"]}},"emptyQuerySelection":1,"owner":"client"}"#;
    let descriptor: Descriptor = serde_json::from_str(json).unwrap();
    assert_eq!(descriptor.parents, Parents::Only { scopes: vec!["root".into()] });
    assert_eq!(descriptor.open_action, None);
    let root: Parents = serde_json::from_str(r#"{"root":{}}"#).unwrap();
    assert_eq!(root, Parents::Root {});
    let problem =
        serde_json::to_value(Problem::InvalidPrefix { id: "a".into(), prefix: "b".into() })
            .unwrap();
    assert_eq!(problem, serde_json::json!({"invalidPrefix": {"_0": "a", "_1": "b"}}));
    let problem = serde_json::to_value(Problem::ReservedId { id: "root".into() }).unwrap();
    assert_eq!(problem, serde_json::json!({"reservedID": {"_0": "root"}}));
}

#[test]
fn first_grapheme_splits_like_swift_first_and_drop_first() {
    assert_eq!(split_first_grapheme("%abc"), Some(("%", "abc")));
    assert_eq!(split_first_grapheme("e\u{301}x"), Some(("e\u{301}", "x")));
    assert_eq!(split_first_grapheme(""), None);
}

#[test]
fn a_user_prefix_wins_and_an_invalid_one_is_ignored() {
    let scopes = vec![
        scope("tabs", Some("@"), &[], Parents::Root {}),
        scope("workspaces", Some("#"), &[], Parents::Root {}),
        scope("actions", Some(">"), &[], Parents::Root {}),
        scope("settings", Some(","), &[], Parents::Root {}),
    ];
    let assigned = HashMap::from([
        ("workspaces".to_string(), Some("@".to_string())),
        ("actions".to_string(), Some("a".to_string())),
        ("settings".to_string(), None),
    ]);
    let applied = apply_assigned(&assigned, scopes);
    let prefixes: Vec<_> = applied.iter().map(|s| s.prefix.as_deref()).collect();
    assert_eq!(prefixes, [None, Some("@"), Some(">"), None]);
    let unchanged = apply_assigned(&HashMap::new(), applied.clone());
    assert_eq!(unchanged, applied);
}
