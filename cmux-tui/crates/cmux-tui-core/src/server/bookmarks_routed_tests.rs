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
