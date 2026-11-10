//! The routed `bookmarks` namespace over the connection message handler:
//! the reads, the batched ops with their replay keys, the HTML import and
//! export, the browser source import, and the origin rules.

use serde_json::{Value, json};

use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn connect(mux: &Arc<Mux>, role: &str, verified: bool) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    set_role_for_test(mux, client, role);
    set_peer_key_for_test(mux, client, "token:30.1");
    set_verified_app_for_test(mux, client, verified);
    Conn { client, writer, outbound, scheduler }
}

fn send(mux: &Arc<Mux>, conn: &Conn, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    serde_json::from_str(&conn.outbound.try_pop().expect("a synchronous reply")).unwrap()
}

fn ok(reply: Value) -> Value {
    assert_eq!(reply["ok"], true, "{reply}");
    reply["result"].clone()
}

fn titles(listing: &Value) -> Vec<String> {
    listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| node["title"].as_str().unwrap().to_string())
        .collect()
}

fn app() -> (Arc<Mux>, Conn) {
    let mux = Mux::new_for_test("bookmarks-routed", crate::SurfaceOptions::default());
    let conn = connect(&mux, "main", true);
    (mux, conn)
}

const FOLDER: &str = "bm_00000000000000000000000000000001";

fn create_ops() -> Value {
    json!([
        {"op": "create", "id": FOLDER, "browser_profile_id": "default", "parent": "bar",
         "index": null, "kind": "folder", "title": "Work", "url": null, "favicon_key": null,
         "source_key": null, "created_ms": 1_700_000_000_000u64},
        {"op": "create", "id": null, "browser_profile_id": "default", "parent": FOLDER,
         "index": null, "kind": "url", "title": "Rust docs", "url": "https://doc.rust-lang.org/",
         "favicon_key": null, "source_key": null, "created_ms": null},
        {"op": "create", "id": null, "browser_profile_id": "default", "parent": "other",
         "index": null, "kind": "url", "title": "GitHub", "url": "https://github.com/",
         "favicon_key": null, "source_key": null, "created_ms": null},
    ])
}

#[test]
fn apply_runs_each_op_and_a_retry_replays() {
    let (mux, conn) = app();
    let events = mux.subscribe();
    let applied =
        ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some("k1")));
    assert_eq!(applied["results"].as_array().unwrap().len(), 3);
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(titles(&listing), ["Work", "Rust docs", "GitHub"]);
    let revision = listing["bookmarks_revision"].clone();
    assert!(
        events
            .try_iter()
            .any(|event| subscribed_event_json(&event)["event"] == "bookmarks-changed")
    );
    // The same key: every op replays, nothing changes.
    let again = ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some("k1")));
    assert!(again["results"].as_array().unwrap().iter().all(|result| result["replayed"] == true));
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(listing["bookmarks_revision"], revision);
    mux.shutdown();
}

#[test]
fn a_refused_op_stops_the_batch_and_names_its_rule() {
    let (mux, conn) = app();
    ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some("k1")));
    let ops = json!([
        {"op": "update", "bookmark": FOLDER, "title": "Projects"},
        {"op": "move", "bookmark": FOLDER, "parent": FOLDER, "index": 0},
        {"op": "delete", "bookmark": FOLDER},
    ]);
    let reply = send(&mux, &conn, "bookmarks.apply", json!({"ops": ops}), Some("k2"));
    assert_eq!(reply["ok"], false, "{reply}");
    let extra = &reply["error"]["details"]["extra"];
    assert_eq!(extra["code"], "bookmarks.invalid_params", "{reply}");
    assert!(extra["reason"].is_string(), "{reply}");
    assert_eq!(extra["applied"], 1, "{reply}");
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(titles(&listing), ["Projects", "Rust docs", "GitHub"]);
    mux.shutdown();
}

#[test]
fn search_rank_and_export_read_the_stored_tree() {
    let (mux, conn) = app();
    ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some("k1")));
    let found = ok(send(
        &mux,
        &conn,
        "bookmarks.search",
        json!({"browser_profile_id": "default", "text": "rust"}),
        None,
    ));
    assert_eq!(titles(&found), ["Rust docs"]);
    let ranked = ok(send(
        &mux,
        &conn,
        "bookmarks.rank",
        json!({"browser_profile_id": "default", "text": "git", "limit": 5}),
        None,
    ));
    assert_eq!(ranked["matches"][0]["bookmark"]["title"], "GitHub", "{ranked}");
    let export = ok(send(
        &mux,
        &conn,
        "bookmarks.export",
        json!({"browser_profile_id": "default", "bar_title": "Bookmarks Bar"}),
        None,
    ));
    assert_eq!(export["count"], 3);
    let html = export["html"].as_str().unwrap();
    assert!(html.contains("<H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks Bar</H3>"), "{html}");
    assert!(html.contains("HREF=\"https://github.com/\""), "{html}");
    mux.shutdown();
}

#[test]
fn import_html_makes_one_folder_and_an_empty_file_is_refused() {
    let (mux, conn) = app();
    let html = "<DL><DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bar</H3><DL><DT><A HREF=\"https://a.test\">A</A></DL><DT><A HREF=\"https://b.test\">B</A></DL>";
    let params = |html: &str| {
        json!({"browser_profile_id": "default", "html": html, "folder_title": "Imported",
               "bar_title": "Bookmarks Bar"})
    };
    let imported = ok(send(&mux, &conn, "bookmarks.import_html", params(html), Some("h1")));
    assert_eq!(imported["count"], 4, "{imported}");
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(titles(&listing), ["Imported", "Bookmarks Bar", "A", "B"]);
    let empty = send(&mux, &conn, "bookmarks.import_html", params("<p>none</p>"), Some("h2"));
    assert_eq!(empty["error"]["details"]["extra"]["code"], "bookmarks.empty", "{empty}");
    mux.shutdown();
}

#[test]
fn import_source_replaces_its_folder_and_no_items_removes_it() {
    let (mux, conn) = app();
    let params = |items: Value| {
        json!({"browser_profile_id": "default", "title": "Imported from Chrome",
               "source_key": "chrome:Default", "items": items})
    };
    let items = json!([
        {"title": "A", "url": "https://a.test", "folder_path": ["Bar"]},
        {"title": "A twice", "url": "https://a.test", "folder_path": ["Bar"]},
    ]);
    let first = ok(send(&mux, &conn, "bookmarks.import_source", params(items), Some("s1")));
    assert_eq!((first["added"].clone(), first["duplicates"].clone()), (json!(1), json!(1)));
    let items = json!([{"title": "B", "url": "https://b.test", "folder_path": ["Bar"]}]);
    ok(send(&mux, &conn, "bookmarks.import_source", params(items), Some("s2")));
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(titles(&listing), ["Imported from Chrome", "B"]);
    ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("s3")));
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(listing["bookmarks"], json!([]));
    mux.shutdown();
}

#[test]
fn a_mutation_needs_a_key_and_a_page_relay_without_a_page_gets_nothing() {
    let (mux, conn) = app();
    let reply = send(&mux, &conn, "bookmarks.apply", json!({"ops": []}), None);
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
    let relay = connect(&mux, "page_relay", false);
    for (operation, params, key) in [
        ("bookmarks.list", json!({"browser_profile_id": "default"}), None),
        ("bookmarks.apply", json!({"ops": create_ops()}), Some("k9")),
    ] {
        let reply = send(&mux, &relay, operation, params, key);
        assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    }
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(listing["bookmarks"], json!([]));
    mux.shutdown();
}

/// Review F1: removing an emptied source records its key even when no folder was there, so a
/// retry after another import made the folder replays instead of deleting it.
#[test]
fn a_retried_source_removal_never_deletes_a_folder_made_since() {
    let (mux, conn) = app();
    let params = |items: Value| {
        json!({"browser_profile_id": "default", "title": "Imported from Chrome",
               "source_key": "chrome:Default", "items": items})
    };
    // Nothing to remove yet: the key is still recorded.
    ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("r1")));
    let items = json!([{"title": "A", "url": "https://a.test", "folder_path": []}]);
    ok(send(&mux, &conn, "bookmarks.import_source", params(items), Some("r2")));
    // The first request's retry replays: the new folder stays.
    let retry = ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("r1")));
    assert_eq!((retry["replayed"].clone(), retry["deleted"].clone()), (json!(true), json!([])));
    assert_eq!(retry["skipped"], 0, "{retry}");
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(titles(&listing), ["Imported from Chrome", "A"]);
    // A new removal takes it, and its retry is a replay too.
    ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("r3")));
    ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("r3")));
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(listing["bookmarks"], json!([]));
    mux.shutdown();
}

/// Review F2: a batch keyed with the longest valid envelope key runs, and its retry replays.
#[test]
fn a_batch_with_a_maximum_length_key_runs_and_replays() {
    let (mux, conn) = app();
    let key = "k".repeat(128);
    let applied =
        ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some(&key)));
    assert_eq!(applied["results"].as_array().unwrap().len(), 3);
    let again = ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some(&key)));
    assert!(again["results"].as_array().unwrap().iter().all(|result| result["replayed"] == true));
    assert_eq!(super::op_key(&key, 0).len(), "sha256:".len() + 64 + 2);
    assert_eq!(super::op_key("short", 3), "short.3");
    // A key shaped like a hashed one is hashed too: it never collides with another key's hash.
    let hashed = super::op_key(&key, 0);
    let lookalike = hashed.trim_end_matches(".0");
    assert_ne!(super::op_key(lookalike, 0), hashed);
    assert!(super::op_key(lookalike, 0).starts_with("sha256:"));
    mux.shutdown();
}

/// Review F4: a search or rank query is bounded in bytes and terms.
#[test]
fn an_oversized_query_is_refused() {
    let (mux, conn) = app();
    for operation in ["bookmarks.search", "bookmarks.rank"] {
        for text in ["x".repeat(2048), "a ".repeat(40)] {
            let reply = send(
                &mux,
                &conn,
                operation,
                json!({"browser_profile_id": "default", "text": text}),
                None,
            );
            assert_eq!(reply["error"]["code"], "validation.invalid", "{operation}: {reply}");
        }
    }
    mux.shutdown();
}

/// A file nested past the depth limit is refused as too deep, not walked (third review F1).
#[test]
fn a_too_deep_file_is_refused() {
    let (mux, conn) = app();
    let depth = 10_000;
    let mut html = String::from("<DL>");
    for level in 0..depth {
        html.push_str(&format!("<DT><H3>F{level}</H3><DL>"));
    }
    html.push_str(&"</DL>".repeat(depth + 1));
    let reply = send(
        &mux,
        &conn,
        "bookmarks.import_html",
        json!({"browser_profile_id": "default", "html": html, "folder_title": "Imported",
               "bar_title": "Bookmarks Bar"}),
        Some("d1"),
    );
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["details"]["extra"]["reason"], "too_deep", "{reply}");
    mux.shutdown();
}

/// Review 4 F1: a browser import whose rows are all unusable is refused and leaves the source's
/// folder as it was.
#[test]
fn an_all_bad_source_import_leaves_the_folder_intact() {
    let (mux, conn) = app();
    let params = |items: Value| {
        json!({"browser_profile_id": "default", "title": "Imported from Chrome",
               "source_key": "chrome:Default", "items": items})
    };
    let items = json!([{"title": "A", "url": "https://a.test", "folder_path": []}]);
    ok(send(&mux, &conn, "bookmarks.import_source", params(items), Some("b1")));
    let bad = json!([{"title": "Bad", "url": "http://[bad", "folder_path": []}]);
    let reply = send(&mux, &conn, "bookmarks.import_source", params(bad), Some("b2"));
    assert_eq!(reply["ok"], false, "{reply}");
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(titles(&listing), ["Imported from Chrome", "A"]);
    mux.shutdown();
}

#[test]
fn children_reads_one_level_or_a_bounded_subtree() {
    let (mux, conn) = app();
    ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some("k1")));
    let read = |params: Value| ok(send(&mux, &conn, "bookmarks.children", params, None));
    // The bar's own row: its folder, not what the folder holds.
    let bar = read(json!({"browser_profile_id": "default", "parent": "bar"}));
    assert_eq!(titles(&bar), ["Work"]);
    assert_eq!(bar["total"], 1);
    assert_eq!(bar["truncated"], false);
    assert_eq!(bar["bookmarks"][0]["index"], 0);
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(bar["bookmarks_revision"], listing["bookmarks_revision"]);
    // A folder menu's subtree, in listing order.
    let deep = read(json!({"browser_profile_id": "default", "parent": "bar", "depth": 64}));
    assert_eq!(titles(&deep), ["Work", "Rust docs"]);
    // Other Bookmarks counted without its rows.
    let other = read(json!({"browser_profile_id": "default", "parent": "other", "limit": 0}));
    assert_eq!(titles(&other), Vec::<String>::new());
    assert_eq!(other["total"], 1);
    assert_eq!(other["truncated"], true);
    // A cut subtree says so.
    let cut =
        read(json!({"browser_profile_id": "default", "parent": "bar", "depth": 2, "limit": 1}));
    assert_eq!(titles(&cut), ["Work"]);
    assert_eq!(cut["truncated"], true);
    // An unknown parent has no children.
    let none = read(json!({"browser_profile_id": "default", "parent": "bm_missing"}));
    assert_eq!(none["total"], 0);
    assert_eq!(titles(&none), Vec::<String>::new());
    mux.shutdown();
}

#[test]
fn the_apps_reads_answer_from_the_stored_tree() {
    let (mux, conn) = app();
    ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": create_ops()}), Some("k1")));
    let profile = "default";
    // The star and the bar: the same page in any case, and whether the bar has anything.
    let status = ok(send(
        &mux,
        &conn,
        "bookmarks.status",
        json!({"browser_profile_id": profile, "urls": ["HTTPS://GitHub.com", "https://nowhere.test/"]}),
        None,
    ));
    assert_eq!(status["bar_filled"], true);
    let matches = status["matches"].as_array().unwrap();
    assert_eq!(matches[0].as_array().unwrap().len(), 1);
    assert_eq!(matches[1], json!([]));
    // A row by id, placed.
    let github = matches[0][0].clone();
    let got = ok(send(
        &mux,
        &conn,
        "bookmarks.get",
        json!({"browser_profile_id": profile, "ids": [github, "bm_ffffffffffffffffffffffffffffffff"]}),
        None,
    ));
    assert_eq!(titles(&got), ["GitHub"]);
    assert_eq!(got["bookmarks"][0]["path"], json!(["other"]));
    assert_eq!(got["bookmarks"][0]["display_url"], "github.com");
    // The CLI's search: index and path from the stored tree.
    let found = ok(send(
        &mux,
        &conn,
        "bookmarks.search",
        json!({"browser_profile_id": profile, "text": "rust", "places": true}),
        None,
    ));
    assert_eq!(found["bookmarks"][0]["path"], json!(["bar", "Work"]));
    assert_eq!(found["bookmarks"][0]["index"], 0);
    // The edit bubble's folders.
    let folders = ok(send(
        &mux,
        &conn,
        "bookmarks.folders",
        json!({"browser_profile_id": profile, "bar_title": "Bar", "other_title": "Other"}),
        None,
    ));
    let ids =
        folders["folders"].as_array().unwrap().iter().map(|f| f["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids, [json!("bar"), json!(FOLDER), json!("other")]);
    // The CLI's names: a bookmark, a folder and a typed URL in one read.
    let titles_ = json!({"bar_title": "Bar", "other_title": "Other"});
    let mut params = json!({"browser_profile_id": profile, "bookmark": "github",
                            "folder": "work", "url": "example.com"});
    params.as_object_mut().unwrap().extend(titles_.as_object().unwrap().clone());
    let resolved = ok(send(&mux, &conn, "bookmarks.resolve", params, None));
    assert_eq!(resolved["bookmark"]["title"], "GitHub");
    assert_eq!(resolved["folder"], FOLDER);
    assert_eq!(resolved["url"], "https://example.com");
    let refused = send(
        &mux,
        &conn,
        "bookmarks.resolve",
        json!({"browser_profile_id": profile, "bookmark": "zzz", "bar_title": "Bar", "other_title": "Other"}),
        None,
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["details"]["extra"]["code"], "bookmarks.not_found");
    let default_folder = ok(send(
        &mux,
        &conn,
        "bookmarks.resolve",
        json!({"browser_profile_id": profile, "folder": null, "fallback_folder": FOLDER,
               "bar_title": "Bar", "other_title": "Other"}),
        None,
    ));
    assert_eq!(default_folder["folder"], FOLDER);
    mux.shutdown();
}

#[test]
fn an_exact_resolve_names_the_focused_page_only() {
    // Only https://example.com/docs is bookmarked; the focused page is https://example.com/.
    let (mux, conn) = app();
    let docs = json!([{"op": "create", "id": FOLDER, "browser_profile_id": "default",
        "parent": "bar", "index": null, "kind": "url", "title": "Docs",
        "url": "https://example.com/docs", "favicon_key": null, "source_key": null,
        "created_ms": null}]);
    ok(send(&mux, &conn, "bookmarks.apply", json!({"ops": docs}), Some("k1")));
    let resolve = |bookmark: &str, exact: bool| {
        send(
            &mux,
            &conn,
            "bookmarks.resolve",
            json!({"browser_profile_id": "default", "bookmark": bookmark, "exact": exact,
                   "bar_title": "Bar", "other_title": "Other"}),
            None,
        )
    };
    // Typed text still matches the way the omnibar does.
    assert_eq!(ok(resolve("https://example.com/", false))["bookmark"]["title"], "Docs");
    // The focused page names no other page's bookmark.
    let refused = resolve("https://example.com/", true);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["details"]["extra"]["code"], "bookmarks.not_found");
    assert_eq!(ok(resolve("HTTPS://example.com/docs", true))["bookmark"]["id"], FOLDER);
    mux.shutdown();
}

#[test]
fn a_source_import_says_what_its_undo_puts_back() {
    let (mux, conn) = app();
    let params = |items: Value| {
        json!({"browser_profile_id": "default", "title": "Imported from Chrome",
               "source_key": "chrome:Default", "items": items})
    };
    let first = ok(send(
        &mux,
        &conn,
        "bookmarks.import_source",
        params(json!([{"title": "A", "url": "https://a.test"}])),
        Some("s1"),
    ));
    assert_eq!(first["previous"], Value::Null);
    let second = ok(send(
        &mux,
        &conn,
        "bookmarks.import_source",
        params(json!([{"title": "B", "url": "https://b.test"}])),
        Some("s2"),
    ));
    assert_eq!(second["previous"]["title"], "Imported from Chrome");
    assert_eq!(second["previous"]["children"][0]["title"], "A");
    // A re-import of an emptied source removes the folder and still says what it held.
    let emptied = ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("s3")));
    assert_eq!(emptied["deleted"].as_array().map(Vec::is_empty), Some(false), "{emptied}");
    assert_eq!(emptied["previous"]["title"], "Imported from Chrome");
    assert_eq!(emptied["previous"]["children"][0]["title"], "B");
    // Nothing left to remove: nothing to put back.
    let again = ok(send(&mux, &conn, "bookmarks.import_source", params(json!([])), Some("s4")));
    assert_eq!(again["previous"], Value::Null);
    mux.shutdown();
}

/// An older build's file, `count` rows in tree order (parents first): a folder on the bar per
/// 200 rows, then its links, each with its `index` among its siblings as the app sends it; every
/// third link has a last use.
fn legacy_rows(count: usize) -> Vec<Value> {
    let mut rows = Vec::with_capacity(count);
    let (mut folder, mut folders, mut links) = (String::new(), 0, 0);
    for n in 0..count {
        let id = format!("bm_{n:032x}");
        if n % 200 == 0 {
            rows.push(json!({"id": id, "parent": "bar", "kind": "folder", "index": folders,
                             "title": format!("Folder {folders}"), "created_ms": 1}));
            (folder, folders, links) = (id, folders + 1, 0);
            continue;
        }
        let mut row = json!({"id": id, "parent": folder, "kind": "url", "index": links,
                             "title": format!("Bookmark {n} with a longer title"),
                             "url": format!("https://example.test/{n}/a/somewhat/long/path?q={n}"),
                             "created_ms": 2});
        if n % 3 == 0 {
            row["last_used_ms"] = json!(3);
        }
        rows.push(row);
        links += 1;
    }
    rows
}

/// The app's byte budget for one migration request (`BookmarkRoutedClient.legacyBatchBytes`).
const LEGACY_BATCH_BYTES: usize = 1 << 20;

/// `rows` as the app sends them: in order, at most 256 rows and [`LEGACY_BATCH_BYTES`] each.
fn legacy_batches(rows: &[Value]) -> Vec<Value> {
    let mut batches = Vec::new();
    let (mut batch, mut bytes) = (Vec::new(), 0);
    for row in rows {
        let size = row.to_string().len() + 1;
        if !batch.is_empty() && (batch.len() == 256 || bytes + size > LEGACY_BATCH_BYTES - 256) {
            batches.push(json!({"browser_profile_id": "default", "nodes": batch}));
            (batch, bytes) = (Vec::new(), 0);
        }
        batch.push(row.clone());
        bytes += size;
    }
    if !batch.is_empty() {
        batches.push(json!({"browser_profile_id": "default", "nodes": batch}));
    }
    batches
}

fn ids(listing: &Value) -> Vec<String> {
    listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| node["id"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn an_older_builds_file_copies_in_once() {
    let (mux, conn) = app();
    let rows = legacy_rows(3);
    let params = json!({"browser_profile_id": "default", "nodes": rows});
    let copied = ok(send(&mux, &conn, "bookmarks.import_legacy_file", params.clone(), Some("m1")));
    assert_eq!(copied["ops"], 3);
    // A copy that runs again (it stopped before the file was deleted) adds nothing.
    ok(send(&mux, &conn, "bookmarks.import_legacy_file", params, Some("m2")));
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(
        titles(&listing),
        ["Folder 0", "Bookmark 1 with a longer title", "Bookmark 2 with a longer title"]
    );
    assert_eq!(listing["bookmarks"][0]["browser_profile_id"], "default");
    mux.shutdown();
}

/// Review F1 (P1): a 20,000-bookmark file no longer goes in one request past the 4 MiB cap; its
/// bounded batches all land, in order, with their last uses.
#[test]
fn a_twenty_thousand_bookmark_file_lands_in_bounded_batches() {
    let (mux, conn) = app();
    let rows = legacy_rows(20_000);
    let whole = json!({"browser_profile_id": "default", "nodes": rows}).to_string().len();
    assert!(whole > crate::resource::MAX_MESSAGE_BYTES, "the fixture is past the cap: {whole}");
    let batches = legacy_batches(&rows);
    assert_eq!(batches.len(), 20_000_usize.div_ceil(256));
    let mut ops = 0;
    for (n, batch) in batches.into_iter().enumerate() {
        assert!(batch.to_string().len() <= LEGACY_BATCH_BYTES, "batch {n}");
        let copied =
            ok(send(&mux, &conn, "bookmarks.import_legacy_file", batch, Some(&format!("b{n}"))));
        ops += copied["ops"].as_u64().unwrap();
    }
    let used = rows.iter().filter(|row| row.get("last_used_ms").is_some()).count() as u64;
    assert_eq!(ops, 20_000 + used);
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    let expected =
        rows.iter().map(|row| row["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(ids(&listing), expected);
    assert_eq!(listing["bookmarks"][3]["last_used_ms"], 3);
    mux.shutdown();
}

/// A copy interrupted after batch k (and half way through batch k + 1) resumes on the next
/// launch from the first batch, with fresh envelope keys: exactly the file's set, no duplicate.
#[test]
fn an_interrupted_file_copy_resumes_with_no_duplicate_and_no_loss() {
    let (mux, conn) = app();
    let rows = legacy_rows(3_000);
    let batches = legacy_batches(&rows);
    let k = 5;
    for (n, batch) in batches.iter().take(k).enumerate() {
        ok(send(
            &mux,
            &conn,
            "bookmarks.import_legacy_file",
            batch.clone(),
            Some(&format!("a{n}")),
        ));
    }
    let half = json!({"browser_profile_id": "default",
                      "nodes": batches[k]["nodes"].as_array().unwrap()[..100].to_vec()});
    ok(send(&mux, &conn, "bookmarks.import_legacy_file", half, Some("a-half")));
    let partial =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert_eq!(ids(&partial).len(), k * 256 + 100);
    for (n, batch) in batches.into_iter().enumerate() {
        ok(send(&mux, &conn, "bookmarks.import_legacy_file", batch, Some(&format!("r{n}"))));
    }
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    let expected =
        rows.iter().map(|row| row["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(ids(&listing), expected);
    mux.shutdown();
}

#[test]
fn a_migration_batch_past_256_nodes_is_refused() {
    let (mux, conn) = app();
    let params = json!({"browser_profile_id": "default", "nodes": legacy_rows(257)});
    let reply = send(&mux, &conn, "bookmarks.import_legacy_file", params, Some("big"));
    assert_eq!(reply["ok"], false, "{reply}");
    let listing =
        ok(send(&mux, &conn, "bookmarks.list", json!({"browser_profile_id": "default"}), None));
    assert!(ids(&listing).is_empty());
    mux.shutdown();
}
