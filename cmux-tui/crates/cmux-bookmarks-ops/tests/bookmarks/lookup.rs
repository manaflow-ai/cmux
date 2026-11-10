//! What the app reads instead of a copy of the tree: places, the star and
//! bar status, folder choices, CLI names, an import's undo draft and an
//! older build's file.

use cmux_bookmarks_core::{Bookmark, BookmarkOp, Tree};
use cmux_bookmarks_ops::lookup::{
    self, FolderChoice, Unresolved, bar_filled, find, find_exact, folder, folders, matches, path,
    placed, source_draft, typed_url,
};

const NOW: u64 = 1_700_000_000_000;

fn id(n: u32) -> String {
    format!("bm_{n:032x}")
}

fn node(n: u32, parent: &str, kind: &str, title: &str, url: Option<&str>) -> Bookmark {
    Bookmark {
        id: id(n),
        browser_profile_id: "default".into(),
        parent: parent.into(),
        kind: kind.into(),
        index: n as usize,
        title: title.into(),
        url: url.map(str::to_string),
        favicon_key: None,
        source_key: None,
        created_ms: NOW,
        last_used_ms: None,
        icon: None,
    }
}

/// bar: Work/{Rust docs, Deep/{Deeper}}, Example; other: GitHub.
fn tree() -> Tree {
    Tree::from_listing(
        "default",
        [
            node(1, "bar", "folder", "Work", None),
            node(2, &id(1), "url", "Rust docs", Some("https://doc.rust-lang.org/")),
            node(3, &id(1), "folder", "Deep", None),
            node(4, &id(3), "url", "Deeper", Some("https://deep.example/")),
            node(5, "bar", "url", "Example", Some("https://Example.com")),
            node(6, "other", "url", "GitHub", Some("https://github.com/")),
        ],
    )
}

#[test]
fn a_path_names_the_root_then_each_folder() {
    let tree = tree();
    assert_eq!(path(&tree, &id(4)), ["bar", "Work", "Deep"]);
    assert_eq!(path(&tree, &id(6)), ["other"]);
    assert!(path(&tree, "bm_gone").is_empty());
    let row = placed(&tree, tree.get(&id(5)).unwrap());
    assert_eq!(row["path"], serde_json::json!(["bar"]));
    assert_eq!(row["display_url"], "Example.com");
    assert_eq!(row["index"], 1);
    assert!(placed(&tree, tree.get(&id(1)).unwrap()).get("display_url").is_none());
}

#[test]
fn the_status_finds_the_same_page_and_says_whether_the_bar_shows() {
    let tree = tree();
    let found = matches(
        &tree,
        &[
            "https://example.com/".into(),
            "https://nowhere.example/".into(),
            "HTTPS://GITHUB.COM".into(),
        ],
    );
    assert_eq!(found, vec![vec![id(5)], vec![], vec![id(6)]]);
    assert!(bar_filled(&tree));
    assert!(bar_filled(&Tree::from_listing(
        "default",
        [node(6, "other", "url", "G", Some("https://g/"))]
    )));
    assert!(!bar_filled(&Tree::new("default")));
}

#[test]
fn folder_choices_list_the_roots_and_every_folder_in_tree_order() {
    let choices = folders(&tree(), "Bookmarks Bar", "Other Bookmarks");
    let shape =
        |id: &str, title: &str, depth| FolderChoice { id: id.into(), title: title.into(), depth };
    assert_eq!(
        choices,
        vec![
            shape("bar", "Bookmarks Bar", 0),
            shape(&id(1), "Work", 1),
            shape(&id(3), "Deep", 2),
            shape("other", "Other Bookmarks", 0),
        ]
    );
}

#[test]
fn a_name_is_an_id_a_url_a_folder_title_or_the_best_match() {
    let tree = tree();
    assert_eq!(find(&tree, &id(6), false, NOW).unwrap().id, id(6));
    assert_eq!(find(&tree, "https://EXAMPLE.com/", false, NOW).unwrap().id, id(5));
    assert_eq!(find(&tree, "rust", false, NOW).unwrap().id, id(2));
    // A folder title ahead of a link whose title starts the same (the folder icon actions).
    assert_eq!(find(&tree, "deep", true, NOW).unwrap().id, id(3));
    assert_eq!(find(&tree, "deep", false, NOW).unwrap().id, id(4));
    // A folder is found by its title words too.
    assert_eq!(find(&tree, "wor", false, NOW).unwrap().id, id(1));
    assert!(find(&tree, "nothing here", false, NOW).is_none());
    assert!(find(&tree, "  ", false, NOW).is_none());
}

#[test]
fn an_exact_name_is_an_id_or_the_same_page_never_a_text_match() {
    // Only https://example.com/docs is bookmarked: the focused page https://example.com/
    // names nothing, though `find` would take the docs link by its text.
    let tree = Tree::from_listing(
        "default",
        [node(1, "bar", "url", "Docs", Some("https://example.com/docs"))],
    );
    assert_eq!(find(&tree, "https://example.com/", false, NOW).unwrap().id, id(1));
    assert!(find_exact(&tree, "https://example.com/").is_none());
    assert_eq!(find_exact(&tree, "HTTPS://Example.com/docs").unwrap().id, id(1));
    assert_eq!(find_exact(&tree, &id(1)).unwrap().id, id(1));
    assert!(find_exact(&tree, "docs").is_none());
    assert!(find_exact(&tree, " ").is_none());
}

#[test]
fn a_folder_name_is_a_root_an_id_or_a_title_and_none_is_the_last_one_used() {
    let tree = tree();
    let named = |text: Option<&str>, fallback: Option<&str>| {
        folder(&tree, text, fallback, "Bookmarks Bar", "Other Bookmarks")
    };
    assert_eq!(named(None, None).unwrap(), "bar");
    assert_eq!(named(None, Some(&id(3))).unwrap(), id(3));
    assert_eq!(named(None, Some(&id(5))).unwrap(), "bar", "a link is no folder");
    assert_eq!(named(Some("other"), None).unwrap(), "other");
    assert_eq!(named(Some("other bookmarks"), None).unwrap(), "other");
    assert_eq!(named(Some("WORK"), None).unwrap(), id(1));
    assert_eq!(named(Some(&id(1)), None).unwrap(), id(1));
    assert_eq!(named(Some("Example"), None), Err(Unresolved::NotFolder));
    assert_eq!(typed_url("example.com").unwrap(), "https://example.com");
    assert_eq!(typed_url("not a url"), Err(Unresolved::InvalidUrl));
}

#[test]
fn an_import_undo_draft_is_the_source_folder_as_it_is() {
    let mut imported = node(7, "bar", "folder", "Imported", None);
    imported.source_key = Some("chrome/Default".into());
    let tree = Tree::from_listing(
        "default",
        [imported, node(8, &id(7), "url", "A", Some("https://a.example/"))],
    );
    let draft = source_draft(&tree, "chrome/Default").unwrap();
    assert_eq!(draft.title, "Imported");
    let children = draft.children.unwrap();
    assert_eq!(children.len(), 1);
    assert_eq!(children[0].url.as_deref(), Some("https://a.example/"));
    assert!(source_draft(&tree, "safari").is_none());
}

#[test]
fn an_older_files_copy_keeps_ids_order_and_last_use_with_stable_keys() {
    let at = |mut node: Bookmark, index: usize| {
        node.index = index;
        node
    };
    let mut used = node(2, &id(1), "url", "A", Some("https://a.example/"));
    used.last_used_ms = Some(3);
    let nodes = [
        at(node(1, "bar", "folder", "Work", None), 0),
        at(used, 0),
        at(node(3, &id(1), "url", "B", Some("https://b.example/")), 1),
    ];
    // The app sends the file in batches: the ops of each batch, in turn, are the file's ops.
    let ops = [nodes[..2].to_vec(), nodes[2..].to_vec()]
        .into_iter()
        .flat_map(|batch| lookup::legacy_nodes("default", batch))
        .collect::<Vec<_>>();
    let keys = ops.iter().map(|op| op.key.clone()).collect::<Vec<_>>();
    assert_eq!(
        keys,
        [
            format!("migrate-file-{}.create", id(1)),
            format!("migrate-file-{}.create", id(2)),
            format!("migrate-file-{}.used", id(2)),
            format!("migrate-file-{}.create", id(3)),
        ]
    );
    let BookmarkOp::Create(input) = &ops[3].op else { panic!("a create") };
    assert_eq!((input.id.as_deref(), input.index), (Some(id(3).as_str()), Some(1)));
    assert_eq!(input.browser_profile_id, "default");
    // Applying them builds the same tree, and applying them again changes nothing.
    let mut tree = Tree::new("default");
    let mut mint = || id(99);
    for op in ops.iter().chain(ops.iter()) {
        tree.apply(op.op.clone(), NOW, &mut mint).unwrap();
    }
    let titles = tree.listing().into_iter().map(|node| node.title).collect::<Vec<_>>();
    assert_eq!(titles, ["Work", "A", "B"]);
    assert_eq!(tree.get(&id(2)).unwrap().last_used_ms, Some(3));
}
