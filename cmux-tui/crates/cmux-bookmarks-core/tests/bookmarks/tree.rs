//! The reducer corpus. The first tests port the Swift `BookmarkTreeTests`
//! of the app's hand copy (`CmuxNextBookmarks/Model/BookmarkTree+Apply.swift`,
//! suite deleted in 36f2381bf1a6) with the daemon's ids and refusals; the
//! rest pin daemon rules the Swift copy did not have. cmux-tui-core's
//! `bookmark_parity_tests` prove the same ops give the same trees in the
//! daemon.

use cmux_bookmarks_core::preview::{self, OpResult};
use cmux_bookmarks_core::{
    Applied, Bookmark, BookmarkError, BookmarkImport, BookmarkImportNode, BookmarkInput,
    BookmarkOp, BookmarkUpdate, MAX_BOOKMARK_DEPTH, Reason, Tree, has_url_scheme,
};
use serde_json::json;

const NOW: u64 = 1_700_000_000_000;
const PROFILE: &str = "default";

fn id(n: u32) -> String {
    format!("bm_{n:032x}")
}

fn a() -> String {
    id(0xa)
}
fn b() -> String {
    id(0xb)
}
fn work() -> String {
    id(0x30)
}
fn c() -> String {
    id(0xc)
}
fn deep() -> String {
    id(0xd0)
}

fn apply(tree: &mut Tree, op: BookmarkOp) -> Result<Applied, BookmarkError> {
    let mut next = 0x1000;
    tree.apply(op, NOW, &mut || {
        next += 1;
        id(next)
    })
}

fn bookmark(title: &str, url: &str, parent: &str, id: &str, index: Option<usize>) -> BookmarkOp {
    BookmarkOp::Create(BookmarkInput {
        id: Some(id.into()),
        browser_profile_id: PROFILE.into(),
        parent: parent.into(),
        index,
        kind: "url".into(),
        title: title.into(),
        url: Some(url.into()),
        ..BookmarkInput::default()
    })
}

fn folder(title: &str, parent: &str, id: &str) -> BookmarkOp {
    BookmarkOp::Create(BookmarkInput {
        id: Some(id.into()),
        browser_profile_id: PROFILE.into(),
        parent: parent.into(),
        kind: "folder".into(),
        title: title.into(),
        ..BookmarkInput::default()
    })
}

fn moved(id: &str, parent: &str, index: usize) -> BookmarkOp {
    BookmarkOp::Move { bookmark: id.into(), parent: parent.into(), index }
}

fn titles(tree: &Tree, parent: &str) -> Vec<String> {
    tree.children(parent).into_iter().map(|node| node.title.clone()).collect()
}

fn refusal(result: Result<Applied, BookmarkError>) -> (String, String) {
    let error = result.expect_err("the op must be refused");
    (error.code().to_string(), error.message().to_string())
}

fn invalid(message: &str) -> (String, String) {
    ("invalid_params".into(), message.into())
}

/// A, B and Work in the bar; C and Deep in Work.
fn sample() -> Tree {
    let mut tree = Tree::new(PROFILE);
    apply(&mut tree, bookmark("A", "https://a.com", "bar", &a(), None)).unwrap();
    apply(&mut tree, bookmark("B", "https://b.com", "bar", &b(), None)).unwrap();
    apply(&mut tree, folder("Work", "bar", &work())).unwrap();
    apply(&mut tree, bookmark("C", "https://c.com", &work(), &c(), None)).unwrap();
    apply(&mut tree, folder("Deep", &work(), &deep())).unwrap();
    tree
}

// MARK: Ported from BookmarkTreeTests.swift

#[test]
fn create_appends_and_inserts_at_index() {
    let mut tree = sample();
    assert_eq!(titles(&tree, "bar"), ["A", "B", "Work"]);
    apply(&mut tree, bookmark("Z", "https://z.com", "bar", &id(0x2), Some(1))).unwrap();
    assert_eq!(titles(&tree, "bar"), ["A", "Z", "B", "Work"]);
    apply(&mut tree, bookmark("Y", "https://y.com", "bar", &id(0x3), Some(99))).unwrap();
    assert_eq!(titles(&tree, "bar").last().map(String::as_str), Some("Y"));
    let indexes = tree.children("bar").into_iter().map(|node| node.index).collect::<Vec<_>>();
    assert_eq!(indexes, [0, 1, 2, 3, 4]);
}

#[test]
fn create_is_idempotent_for_an_existing_id() {
    let mut tree = sample();
    let again = apply(&mut tree, bookmark("Again", "https://a.com", "other", &a(), None)).unwrap();
    assert!(!again.changed);
    assert_eq!(again.result["bookmark"]["title"], "A");
    assert_eq!(tree.get(&a()).map(|node| node.title.as_str()), Some("A"));
    assert!(tree.children("other").is_empty());
}

#[test]
fn create_refuses_unknown_parent_folder_url_and_relative_url() {
    let mut tree = sample();
    let before = tree.clone();
    assert_eq!(
        refusal(apply(&mut tree, bookmark("X", "https://x.com", "nope", &id(0x4), None))),
        invalid("parent must be \"bar\", \"other\" or a folder id")
    );
    assert_eq!(
        refusal(apply(&mut tree, bookmark("X", "https://x.com", &a(), &id(0x4), None))),
        invalid(&format!("parent {} is not a folder of browser profile default", a()))
    );
    assert_eq!(
        refusal(apply(&mut tree, bookmark("X", "https://x.com", &id(0x77), &id(0x4), None))),
        invalid(&format!("parent {} is not a folder of browser profile default", id(0x77)))
    );
    let mut folder_with_url = folder("F", "bar", &id(0x5));
    if let BookmarkOp::Create(input) = &mut folder_with_url {
        input.url = Some("https://f.com".into());
    }
    assert_eq!(refusal(apply(&mut tree, folder_with_url)), invalid("a folder has no url"));
    assert_eq!(
        refusal(apply(&mut tree, bookmark("R", "relative/path", "bar", &id(0x6), None))),
        invalid("url must be an absolute URL")
    );
    assert_eq!(tree, before, "a refused op changes nothing");
}

#[test]
fn move_uses_the_final_index_within_the_same_parent() {
    let mut tree = sample();
    assert!(apply(&mut tree, moved(&a(), "bar", 2)).unwrap().changed);
    assert_eq!(titles(&tree, "bar"), ["B", "Work", "A"]);
    apply(&mut tree, moved(&a(), "bar", 0)).unwrap();
    assert_eq!(titles(&tree, "bar"), ["A", "B", "Work"]);
    let unchanged = apply(&mut tree, moved(&a(), "bar", 0)).unwrap();
    assert!(!unchanged.changed);
    // Past the end clamps to the last position.
    let last = apply(&mut tree, moved(&a(), "bar", 50)).unwrap();
    assert_eq!(last.result["bookmark"]["index"], 2);
    assert_eq!(titles(&tree, "bar"), ["B", "Work", "A"]);
}

#[test]
fn move_between_folders_and_clamps_index() {
    let mut tree = sample();
    apply(&mut tree, moved(&b(), &work(), 0)).unwrap();
    assert_eq!(titles(&tree, "bar"), ["A", "Work"]);
    assert_eq!(titles(&tree, &work()), ["B", "C", "Deep"]);
    apply(&mut tree, moved(&c(), "other", 50)).unwrap();
    assert_eq!(titles(&tree, "other"), ["C"]);
    assert_eq!(tree.get(&c()).map(|node| node.parent.as_str()), Some("other"));
    assert_eq!(tree.get(&deep()).map(|node| node.index), Some(1));
}

#[test]
fn move_refuses_cycles() {
    let mut tree = sample();
    let cycle = invalid("a folder cannot move into itself or a descendant");
    assert_eq!(refusal(apply(&mut tree, moved(&work(), &deep(), 0))), cycle);
    assert_eq!(refusal(apply(&mut tree, moved(&work(), &work(), 0))), cycle);
    assert_eq!(tree.get(&work()).map(|node| node.parent.as_str()), Some("bar"));
}

#[test]
fn delete_removes_the_subtree() {
    let mut tree = sample();
    let deleted = apply(&mut tree, BookmarkOp::Delete { bookmark: work() }).unwrap();
    // The daemon's order: by level, then by id.
    assert_eq!(deleted.result, json!({"deleted": [work(), c(), deep()]}));
    assert_eq!(tree.len(), 2);
    assert_eq!(titles(&tree, "bar"), ["A", "B"]);
    assert!(tree.children(&work()).is_empty());
    assert_eq!(
        refusal(apply(&mut tree, BookmarkOp::Delete { bookmark: work() })),
        ("not_found".into(), format!("unknown bookmark {}", work()))
    );
}

#[test]
fn update_edits_fields_and_refuses_url_on_folder() {
    let mut tree = sample();
    let update = BookmarkUpdate {
        title: Some("Alpha".into()),
        url: Some("https://alpha.com".into()),
        last_used_ms: Some(Some(5)),
        ..BookmarkUpdate::default()
    };
    assert!(apply(&mut tree, BookmarkOp::Update { bookmark: a(), update }).unwrap().changed);
    let node = tree.get(&a()).unwrap();
    assert_eq!(
        (node.title.as_str(), node.url.as_deref(), node.last_used_ms),
        ("Alpha", Some("https://alpha.com"), Some(5))
    );
    let clear = BookmarkUpdate { last_used_ms: Some(None), ..BookmarkUpdate::default() };
    apply(&mut tree, BookmarkOp::Update { bookmark: a(), update: clear.clone() }).unwrap();
    assert_eq!(tree.get(&a()).unwrap().last_used_ms, None);
    // Clearing what is clear changes nothing.
    assert!(
        !apply(&mut tree, BookmarkOp::Update { bookmark: a(), update: clear }).unwrap().changed
    );
    let url = BookmarkUpdate { url: Some("https://x.com".into()), ..BookmarkUpdate::default() };
    assert_eq!(
        refusal(apply(&mut tree, BookmarkOp::Update { bookmark: work(), update: url })),
        invalid("a folder has no url")
    );
}

#[test]
fn listing_is_preorder_and_round_trips() {
    let tree = sample();
    let ids = tree.listing().into_iter().map(|node| node.id).collect::<Vec<_>>();
    assert_eq!(ids, [a(), b(), work(), c(), deep()]);
    assert_eq!(Tree::from_listing(PROFILE, tree.listing()), tree);
    // Children may arrive before their parents.
    let mut reversed = tree.listing();
    reversed.reverse();
    assert_eq!(Tree::from_listing(PROFILE, reversed).listing(), tree.listing());
}

/// The Swift copy moved an orphan to Other Bookmarks (a file store rule).
/// The daemon never lists one and lists one last, grouped by parent; the
/// tree keeps it the same way.
#[test]
fn an_orphan_is_kept_and_listed_last() {
    let orphan = Bookmark {
        id: id(0x99),
        browser_profile_id: PROFILE.into(),
        parent: id(0x98),
        kind: "url".into(),
        index: 0,
        title: "O".into(),
        url: Some("https://o.com".into()),
        favicon_key: None,
        source_key: None,
        created_ms: 1,
        last_used_ms: None,
        icon: None,
    };
    let mut listing = sample().listing();
    listing.insert(0, orphan);
    let tree = Tree::from_listing(PROFILE, listing);
    assert_eq!(tree.listing().last().map(|node| node.title.as_str()), Some("O"));
    assert_eq!(tree.len(), 6);
}

#[test]
fn depth_limit_is_enforced() {
    let mut tree = Tree::new(PROFILE);
    let mut parent = "bar".to_string();
    for level in 0..MAX_BOOKMARK_DEPTH {
        let folder_id = id(0x100 + level as u32);
        apply(&mut tree, folder(&format!("L{level}"), &parent, &folder_id)).unwrap();
        parent = folder_id;
    }
    assert_eq!(
        refusal(apply(&mut tree, folder("Too", &parent, &id(0x9999)))),
        invalid("bookmarks nest at most 64 deep")
    );
    // A two-level folder may not move below level 63 either.
    apply(&mut tree, folder("Top", "bar", &id(0x7000))).unwrap();
    apply(&mut tree, folder("Inner", &id(0x7000), &id(0x7001))).unwrap();
    assert_eq!(
        refusal(apply(&mut tree, moved(&id(0x7000), &id(0x100 + 63), 0))),
        invalid("bookmarks nest at most 64 deep")
    );
}

// MARK: Daemon rules the Swift copy lacked

#[test]
fn ids_profiles_and_icons_follow_the_daemon() {
    let mut tree = sample();
    assert_eq!(
        refusal(apply(&mut tree, bookmark("X", "https://x.com", "bar", "a", None))),
        invalid("bookmark id must be \"bm_\" and 32 lowercase hex digits")
    );
    let mut other = bookmark("X", "https://x.com", "bar", &id(0x41), None);
    if let BookmarkOp::Create(input) = &mut other {
        input.browser_profile_id = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d".into();
    }
    assert_eq!(
        refusal(apply(&mut tree, other)),
        ("not_found".into(), "unknown browser profile 3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d".into())
    );
    let icon = BookmarkUpdate { icon: Some(Some("star".into())), ..BookmarkUpdate::default() };
    assert_eq!(
        refusal(apply(&mut tree, BookmarkOp::Update { bookmark: a(), update: icon.clone() })),
        invalid("only a folder has an icon")
    );
    apply(&mut tree, BookmarkOp::Update { bookmark: work(), update: icon }).unwrap();
    assert_eq!(tree.get(&work()).unwrap().icon.as_deref(), Some("star"));
    let mut tagged = bookmark("X", "https://x.com", "bar", &id(0x42), None);
    if let BookmarkOp::Create(input) = &mut tagged {
        input.source_key = Some("chrome".into());
    }
    assert_eq!(
        refusal(apply(&mut tree, tagged)),
        invalid("source_key marks an imported folder; a url has none")
    );
}

fn node(
    kind: &str,
    title: &str,
    url: Option<&str>,
    children: Option<Vec<BookmarkImportNode>>,
) -> BookmarkImportNode {
    BookmarkImportNode {
        kind: kind.into(),
        title: title.into(),
        url: url.map(String::from),
        created_ms: None,
        children,
    }
}

fn import(
    parent: &str,
    index: Option<usize>,
    replace: bool,
    nodes: Vec<BookmarkImportNode>,
) -> BookmarkOp {
    BookmarkOp::Import(BookmarkImport {
        browser_profile_id: PROFILE.into(),
        parent: parent.into(),
        index,
        source_key: Some("chrome".into()),
        replace,
        nodes,
    })
}

#[test]
fn an_import_writes_a_tree_and_a_replace_keeps_the_folder() {
    let mut tree = sample();
    let first = vec![
        node(
            "folder",
            "Chrome",
            None,
            Some(vec![node("url", "x", Some("https://x.example"), None)]),
        ),
        node("url", "after", Some("https://after.example"), None),
    ];
    let applied = apply(&mut tree, import("bar", Some(1), false, first)).unwrap();
    assert_eq!(applied.result["count"], 3);
    assert_eq!(titles(&tree, "bar"), ["A", "Chrome", "after", "B", "Work"]);
    let chrome = tree.children("bar")[1].clone();
    assert_eq!(chrome.source_key.as_deref(), Some("chrome"));
    assert_eq!(chrome.created_ms, NOW);
    assert_eq!(tree.get(&tree.children("bar")[2].id).unwrap().source_key, None);
    // An import stores no favicon key (the Swift copy derived one).
    assert_eq!(tree.children(&chrome.id)[0].favicon_key, None);

    // Move it, then replace it: it keeps its id and place, takes the new
    // title and children, and further nodes follow it.
    apply(&mut tree, moved(&chrome.id, "other", 0)).unwrap();
    let second = vec![
        node(
            "folder",
            "Chrome 2",
            None,
            Some(vec![
                node("url", "y", Some("https://y.example"), None),
                node("folder", "z", None, None),
            ]),
        ),
        node("url", "next", Some("https://next.example"), None),
    ];
    let replaced = apply(&mut tree, import("bar", None, true, second)).unwrap();
    assert_eq!(replaced.result["root_ids"][0], chrome.id.as_str());
    assert_eq!(titles(&tree, "other"), ["Chrome 2", "next"]);
    assert_eq!(titles(&tree, &chrome.id), ["y", "z"]);
    assert_eq!(tree.len(), 5 + 3 + 1 + 2 - 1);

    assert_eq!(
        refusal(apply(&mut tree, import("bar", None, false, vec![]))),
        invalid("nodes cannot be empty")
    );
    assert_eq!(
        refusal(apply(
            &mut tree,
            import("bar", None, true, vec![node("url", "u", Some("https://u.example"), None)])
        )),
        invalid("replace needs a folder as the first node")
    );
    assert_eq!(
        refusal(apply(
            &mut tree,
            import(
                "bar",
                None,
                false,
                vec![node("url", "u", Some("https://u.example"), Some(vec![]))]
            )
        )),
        invalid("only a folder has children")
    );
}

#[test]
fn op_json_is_the_daemon_fingerprint_shape_and_reads_back() {
    let update = BookmarkOp::Update {
        bookmark: a(),
        update: BookmarkUpdate { favicon_key: Some(None), ..BookmarkUpdate::default() },
    };
    let value = serde_json::to_value(&update).unwrap();
    assert_eq!(value, json!({"op": "update", "bookmark": a(), "favicon_key": null}));
    let back: BookmarkOp = serde_json::from_value(value).unwrap();
    let BookmarkOp::Update { update, .. } = back else { panic!("an update") };
    assert_eq!(update.favicon_key, Some(None), "null clears, absent keeps");
    assert_eq!(update.last_used_ms, None);
    let create = serde_json::to_value(bookmark("A", "https://a.com", "bar", &a(), None)).unwrap();
    assert_eq!(
        create,
        json!({"op": "create", "id": a(), "browser_profile_id": "default", "parent": "bar", "index": null,
               "kind": "url", "title": "A", "url": "https://a.com", "favicon_key": null, "source_key": null,
               "created_ms": null})
    );
}

/// The app maps each reason to its own localized text (BookmarkAppStrings).
#[test]
fn each_refusal_names_its_rule() {
    let mut tree = sample();
    let mut reason = |op| apply(&mut tree, op).expect_err("refused").reason();
    assert_eq!(reason(BookmarkOp::Delete { bookmark: id(0x7777) }), Reason::NotFound);
    assert_eq!(
        reason(bookmark("X", "https://x.com", "nope", &id(0x4), None)),
        Reason::InvalidParent
    );
    assert_eq!(reason(bookmark("X", "https://x.com", &a(), &id(0x4), None)), Reason::InvalidParent);
    assert_eq!(reason(moved(&work(), &deep(), 0)), Reason::Cycle);
    assert_eq!(reason(bookmark("R", "relative/path", "bar", &id(0x6), None)), Reason::InvalidUrl);
    let url = BookmarkUpdate { url: Some("https://x.com".into()), ..BookmarkUpdate::default() };
    assert_eq!(reason(BookmarkOp::Update { bookmark: work(), update: url }), Reason::InvalidKind);
    assert_eq!(
        reason(bookmark(&"t".repeat(4097), "https://x.com", "bar", &id(0x6), None)),
        Reason::TooLarge
    );
    assert_eq!(reason(bookmark("X", "https://x.com", "bar", "a", None)), Reason::Invalid);
}

// MARK: The app's preview

/// V-11: two quick edits both show before either echo arrives.
#[test]
fn the_preview_shows_every_pending_edit_on_the_confirmed_tree() {
    let confirmed = sample().listing();
    let rename = BookmarkUpdate { title: Some("Alpha".into()), ..BookmarkUpdate::default() };
    let ops = vec![
        BookmarkOp::Update { bookmark: a(), update: rename },
        moved(&a(), &work(), 0),
        BookmarkOp::Delete { bookmark: id(0x7777) },
    ];
    let request =
        json!({"browser_profile_id": PROFILE, "tree": confirmed, "ops": ops, "now_ms": NOW});
    let response = preview::respond(serde_json::from_value(request).unwrap());
    let tree = Tree::from_listing(PROFILE, response.tree.clone());
    assert_eq!(titles(&tree, &work()), ["Alpha", "C", "Deep"]);
    assert!(matches!(response.results[0], OpResult::Applied { changed: true, .. }));
    assert!(matches!(response.results[1], OpResult::Applied { changed: true, .. }));
    assert_eq!(
        response.results[2],
        OpResult::Refused {
            error_code: "not_found",
            reason: Reason::NotFound,
            message: format!("unknown bookmark {}", id(0x7777))
        }
    );
    // Once the daemon's listing holds the edits, the same pending ops change
    // nothing more: the view does not jump when the echo lands.
    let echo = preview::respond(preview::Request {
        browser_profile_id: PROFILE.into(),
        tree: response.tree.clone(),
        ops: vec![moved(&a(), &work(), 0)],
        now_ms: NOW,
        seed: None,
    });
    assert_eq!(echo.tree, response.tree);
}

#[test]
fn the_preview_mints_well_formed_unique_ids_for_an_import() {
    let request = preview::Request {
        browser_profile_id: PROFILE.into(),
        tree: sample().listing(),
        ops: vec![import(
            "other",
            None,
            false,
            vec![node("folder", "F", None, Some(vec![node("folder", "G", None, None)]))],
        )],
        now_ms: NOW,
        seed: Some(7),
    };
    let response = preview::respond(request.clone());
    assert_eq!(response.tree.len(), 7);
    let mut ids = response.tree.iter().map(|node| node.id.clone()).collect::<Vec<_>>();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 7);
    assert!(ids.iter().all(|value| cmux_bookmarks_core::validate_bookmark_id(value).is_ok()));
    assert_eq!(preview::respond(request), response, "a seed gives the same ids");
}

// MARK: The app's URL check

/// Without the `url` feature (the app) a URL needs a scheme. That accepts
/// every URL the daemon's parser accepts, so the app never refuses an edit
/// the daemon would take.
#[test]
fn the_scheme_check_accepts_every_url_the_parser_accepts() {
    let corpus = [
        "https://a.com",
        "HTTPS://A.COM/",
        "http://localhost:3000/x?y#z",
        "file:///Users/me/a.html",
        "about:blank",
        "javascript:alert(1)",
        "mailto:me@example.com",
        "data:text/html,hi",
        "chrome://settings",
        "cmux://bookmarks",
        "a+b-c.d:rest",
        "  https://padded.example  ",
        "http://exa mple.com",
        "http://[::1",
        "https://",
        "relative/path",
        "/absolute/path",
        "//host/path",
        ":nothing",
        "1http://a.com",
        "",
        "ht tp://a.com",
        "http://ünïcode.example/",
    ];
    for url in corpus {
        let parsed = url::Url::parse(url).is_ok();
        assert!(
            !parsed || has_url_scheme(url),
            "{url:?}: the parser accepts it, the scheme check must too"
        );
    }
    assert!(!has_url_scheme("relative/path"));
    assert!(!has_url_scheme("1http://a.com"));
}
