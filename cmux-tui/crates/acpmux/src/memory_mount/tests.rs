//! The memory mount against an in-process fake of the store (`/v1/memory`, the contract
//! helper A's cmux-platform route serves): path rules, the three-way merge, conflict names, and
//! two machines' engines syncing through one store.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path as UrlPath, Query, State as AxState};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde_json::json;

use super::client::{Client, Entry, Tree};
use super::engine::Engine;
use super::merge::{Merged, conflict_name, three_way};
use super::*;

// ---- pure rules ----

#[test]
fn canonical_project_is_the_same_on_a_mac_and_linux() {
    assert_eq!(
        canonical_project("-Users-leo-Projects-cmux", Path::new("/Users/leo")),
        "Projects-cmux"
    );
    assert_eq!(
        canonical_project("-home-cmux-Projects-cmux", Path::new("/home/cmux")),
        "Projects-cmux"
    );
    assert_eq!(canonical_project("-home-cmux", Path::new("/home/cmux")), "home");
    assert_eq!(canonical_project("-srv-data", Path::new("/home/cmux")), "srv-data");
    assert_eq!(claude_slugify("/Users/leo.li/Projects/x_y"), "-Users-leo-li-Projects-x-y");
}

#[test]
fn editor_and_hidden_files_are_skipped() {
    for skipped in
        ["a.md.swp", "notes~", ".#notes.md", ".DS_Store", "dir/.hidden/a.md", ".a.md.memtmp-1-2"]
    {
        assert!(skipped_name(skipped), "{skipped}");
    }
    for kept in ["MEMORY.md", "claude/Projects-cmux/feedback.md", "agent-memory/notes.jsonl"] {
        assert!(!skipped_name(kept), "{kept}");
    }
    assert!(engine::safe_rel("a/b.md"));
    for bad in ["../a", "a/../b", "/a", "a//b", ""] {
        assert!(!engine::safe_rel(bad), "{bad}");
    }
}

#[test]
fn three_way_merges_separate_edits_and_refuses_overlapping_ones() {
    let base = "one\ntwo\nthree\nfour\nfive\n";
    let ours = "ONE\ntwo\nthree\nfour\nfive\n";
    let theirs = "one\ntwo\nthree\nfour\nFIVE\n";
    assert_eq!(
        three_way("a.md", base.as_bytes(), ours.as_bytes(), theirs.as_bytes()),
        Merged::Clean(b"ONE\ntwo\nthree\nfour\nFIVE\n".to_vec())
    );
    assert_eq!(
        three_way(
            "a.md",
            base.as_bytes(),
            b"one\nX\nthree\nfour\nfive\n",
            b"one\nY\nthree\nfour\nfive\n"
        ),
        Merged::Conflict
    );
    // One side unchanged: the other side, whatever it is.
    assert_eq!(three_way("a.bin", b"\xff", b"\xff", b"\xfe"), Merged::Clean(b"\xfe".to_vec()));
    assert_eq!(three_way("a.bin", b"\xff", b"\xfd", b"\xfe"), Merged::Conflict);
}

#[test]
fn jsonl_merges_by_lines_keeping_both_sides_appends() {
    let base = "{\"a\":1}\n";
    let ours = "{\"a\":1}\n{\"b\":2}\n";
    let theirs = "{\"a\":1}\n{\"c\":3}\n";
    let Merged::Clean(out) =
        three_way("notes.jsonl", base.as_bytes(), ours.as_bytes(), theirs.as_bytes())
    else {
        panic!("jsonl always merges");
    };
    assert_eq!(String::from_utf8(out).unwrap(), "{\"a\":1}\n{\"c\":3}\n{\"b\":2}\n");
}

#[test]
fn conflict_names_stay_beside_the_file() {
    assert_eq!(conflict_name("notes/a.md", "lane-1", 17), "notes/a.conflict-lane-1-17.md");
    assert_eq!(conflict_name("MEMORY.md", "mac.local", 5), "MEMORY.conflict-mac_local-5.md");
    assert_eq!(conflict_name("README", "h/x", 5), "README.conflict-h_x-5");
}

// ---- the fake store ----

#[derive(Clone)]
struct Version {
    version: u64,
    bytes: Vec<u8>,
    deleted: bool,
    seq: u64,
    author: String,
}

#[derive(Default)]
struct Store {
    seq: u64,
    files: BTreeMap<(String, String), Vec<Version>>,
    puts: u64,
}

type Shared = Arc<Mutex<Store>>;

fn entry(path: &str, v: &Version) -> Entry {
    Entry {
        path: path.to_owned(),
        version: v.version,
        sha256: if v.deleted { String::new() } else { sha256_hex(&v.bytes) },
        size: v.bytes.len() as u64,
        mtime: None,
        deleted: v.deleted,
        seq: v.seq,
        author: Some(v.author.clone()),
    }
}

fn tree_since(store: &Store, scope: &str, since: u64) -> Tree {
    let entries = store
        .files
        .iter()
        .filter(|((s, _), _)| s == scope)
        .filter_map(|((_, path), versions)| versions.last().map(|v| entry(path, v)))
        .filter(|e| e.seq > since)
        .collect();
    Tree { seq: store.seq, entries }
}

async fn tree(
    AxState(store): AxState<Shared>,
    UrlPath(scope): UrlPath<String>,
    Query(q): Query<BTreeMap<String, String>>,
) -> Response {
    let since = q.get("since").and_then(|s| s.parse().ok()).unwrap_or(0);
    axum::Json(tree_since(&store.lock().unwrap(), &scope, since)).into_response()
}

async fn file_get(
    AxState(store): AxState<Shared>,
    UrlPath((scope, path)): UrlPath<(String, String)>,
) -> Response {
    let store = store.lock().unwrap();
    match store.files.get(&(scope, path)).and_then(|v| v.last()) {
        Some(v) if !v.deleted => v.bytes.clone().into_response(),
        _ => {
            (StatusCode::NOT_FOUND, axum::Json(json!({"code": "memory.not_found"}))).into_response()
        }
    }
}

fn write(
    store: &Shared,
    scope: String,
    path: String,
    headers: &HeaderMap,
    bytes: Option<Bytes>,
) -> Response {
    let mut store = store.lock().unwrap();
    let want: u64 = headers
        .get("If-Match-Version")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok())
        .unwrap_or(u64::MAX);
    let author =
        headers.get("X-Memory-Author").and_then(|v| v.to_str().ok()).unwrap_or("").to_owned();
    if let Some(bytes) = &bytes
        && bytes.windows(9).any(|w| w == b"refuse-me")
    {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            axum::Json(json!({"code": "memory.secret_refused"})),
        )
            .into_response();
    }
    let key = (scope, path);
    let current = store.files.get(&key).and_then(|v| v.last()).cloned();
    let current_version = current.as_ref().map(|v| v.version).unwrap_or(0);
    // A tombstone's version must be named too (0 matches only "never existed").
    if want != current_version {
        let sha = current
            .as_ref()
            .filter(|v| !v.deleted)
            .map(|v| sha256_hex(&v.bytes))
            .unwrap_or_default();
        return (
            StatusCode::CONFLICT,
            axum::Json(json!({"code": "memory.conflict", "current": {"version": current_version, "sha256": sha}})),
        )
            .into_response();
    }
    store.seq += 1;
    store.puts += 1;
    let seq = store.seq;
    let version = current_version + 1;
    let deleted = bytes.is_none();
    store.files.entry(key).or_default().push(Version {
        version,
        bytes: bytes.map(|b| b.to_vec()).unwrap_or_default(),
        deleted,
        seq,
        author,
    });
    axum::Json(json!({"version": version, "seq": seq})).into_response()
}

async fn file_put(
    AxState(store): AxState<Shared>,
    UrlPath((scope, path)): UrlPath<(String, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    write(&store, scope, path, &headers, Some(body))
}

async fn file_delete(
    AxState(store): AxState<Shared>,
    UrlPath((scope, path)): UrlPath<(String, String)>,
    headers: HeaderMap,
) -> Response {
    write(&store, scope, path, &headers, None)
}

async fn history(
    AxState(store): AxState<Shared>,
    UrlPath((scope, path)): UrlPath<(String, String)>,
) -> Response {
    let store = store.lock().unwrap();
    let versions: Vec<Entry> = store
        .files
        .get(&(scope, path.clone()))
        .map(|v| v.iter().map(|v| entry(&path, v)).collect())
        .unwrap_or_default();
    axum::Json(json!({"versions": versions})).into_response()
}

async fn fake() -> (Client, Shared) {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let store: Shared = Arc::default();
    let router = Router::new()
        .route("/v1/memory/{scope}/tree", get(tree))
        .route("/v1/memory/{scope}/watch", get(tree))
        .route("/v1/memory/{scope}/file/{*path}", get(file_get).put(file_put).delete(file_delete))
        .route("/v1/memory/{scope}/history/{*path}", get(history))
        .with_state(store.clone());
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
    (Client::new(origin, "cmm_test".into()).unwrap(), store)
}

fn machine(client: &Client, root: &Path, host: &str) -> Engine {
    Engine::new(client.clone(), Scope::Team, root, host.to_owned()).unwrap()
}

fn put_file(root: &Path, rel: &str, text: &str) {
    let path = scope_dir(root, Scope::Team).join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn read(root: &Path, rel: &str) -> Option<String> {
    std::fs::read_to_string(scope_dir(root, Scope::Team).join(rel)).ok()
}

// ---- two machines through one store ----

#[tokio::test]
async fn a_note_written_on_one_machine_reaches_the_other() {
    let (client, store) = fake().await;
    let (a_root, b_root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) =
        (machine(&client, a_root.path(), "a"), machine(&client, b_root.path(), "b"));

    put_file(a_root.path(), "notes/fleet.md", "hello\n");
    put_file(a_root.path(), "notes/fleet.md.swp", "editor junk");
    let report = a.pass().await.unwrap();
    assert_eq!(report.pushed, vec!["notes/fleet.md"]);
    b.pass().await.unwrap();
    assert_eq!(read(b_root.path(), "notes/fleet.md").as_deref(), Some("hello\n"));
    assert!(read(b_root.path(), "notes/fleet.md.swp").is_none());

    // A pass with nothing new publishes nothing (no echo of what it just pulled).
    let puts = store.lock().unwrap().puts;
    a.pass().await.unwrap();
    b.pass().await.unwrap();
    assert_eq!(store.lock().unwrap().puts, puts);
    assert!(a.pending().is_empty() && b.pending().is_empty());

    // An edit there comes back here; a delete there removes it here.
    put_file(b_root.path(), "notes/fleet.md", "hello again\n");
    b.pass().await.unwrap();
    a.pass().await.unwrap();
    assert_eq!(read(a_root.path(), "notes/fleet.md").as_deref(), Some("hello again\n"));
    std::fs::remove_file(scope_dir(a_root.path(), Scope::Team).join("notes/fleet.md")).unwrap();
    assert_eq!(a.pass().await.unwrap().deleted, vec!["notes/fleet.md"]);
    b.pass().await.unwrap();
    assert!(read(b_root.path(), "notes/fleet.md").is_none());

    // No temps left behind.
    for root in [a_root.path(), b_root.path()] {
        let names: Vec<_> = std::fs::read_dir(scope_dir(root, Scope::Team).join("notes"))
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains("memtmp"))
            .collect();
        assert!(names.is_empty(), "{names:?}");
    }
}

#[tokio::test]
async fn edits_to_different_lines_on_two_machines_merge() {
    let (client, _store) = fake().await;
    let (a_root, b_root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) =
        (machine(&client, a_root.path(), "a"), machine(&client, b_root.path(), "b"));
    put_file(a_root.path(), "m.md", "one\ntwo\nthree\nfour\nfive\n");
    a.pass().await.unwrap();
    b.pass().await.unwrap();

    put_file(a_root.path(), "m.md", "ONE\ntwo\nthree\nfour\nfive\n");
    put_file(b_root.path(), "m.md", "one\ntwo\nthree\nfour\nFIVE\n");
    a.pass().await.unwrap();
    let report = b.pass().await.unwrap(); // 409, pulls, merges, publishes the merge
    assert_eq!(report.merged, vec!["m.md"]);
    a.pass().await.unwrap();
    let want = "ONE\ntwo\nthree\nfour\nFIVE\n";
    assert_eq!(read(a_root.path(), "m.md").as_deref(), Some(want));
    assert_eq!(read(b_root.path(), "m.md").as_deref(), Some(want));
    assert!(a.pending().is_empty() && b.pending().is_empty());
}

#[tokio::test]
async fn overlapping_edits_keep_both_sides_and_publish_both() {
    let (client, store) = fake().await;
    let (a_root, b_root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) =
        (machine(&client, a_root.path(), "a"), machine(&client, b_root.path(), "b"));
    put_file(a_root.path(), "m.md", "one\ntwo\nthree\n");
    a.pass().await.unwrap();
    b.pass().await.unwrap();

    put_file(a_root.path(), "m.md", "one\nFROM A\nthree\n");
    put_file(b_root.path(), "m.md", "one\nFROM B\nthree\n");
    a.pass().await.unwrap();
    let report = b.pass().await.unwrap();
    assert_eq!(report.conflicts.len(), 1);
    let side = &report.conflicts[0];
    assert!(side.starts_with("m.conflict-b-") && side.ends_with(".md"), "{side}");
    // Theirs keeps the name; ours is beside it; both are in the store.
    assert_eq!(read(b_root.path(), "m.md").as_deref(), Some("one\nFROM A\nthree\n"));
    assert_eq!(read(b_root.path(), side).as_deref(), Some("one\nFROM B\nthree\n"));
    a.pass().await.unwrap();
    assert_eq!(read(a_root.path(), side).as_deref(), Some("one\nFROM B\nthree\n"));
    assert!(store.lock().unwrap().files.contains_key(&("team".to_owned(), side.clone())));
}

#[tokio::test]
async fn a_change_here_survives_a_delete_there() {
    let (client, _store) = fake().await;
    let (a_root, b_root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) =
        (machine(&client, a_root.path(), "a"), machine(&client, b_root.path(), "b"));
    put_file(a_root.path(), "m.md", "v1\n");
    a.pass().await.unwrap();
    b.pass().await.unwrap();
    std::fs::remove_file(scope_dir(a_root.path(), Scope::Team).join("m.md")).unwrap();
    a.pass().await.unwrap();
    put_file(b_root.path(), "m.md", "v2 from b\n");
    b.pass().await.unwrap();
    assert_eq!(read(b_root.path(), "m.md").as_deref(), Some("v2 from b\n"));
    a.pass().await.unwrap();
    assert_eq!(read(a_root.path(), "m.md").as_deref(), Some("v2 from b\n"));
}

#[tokio::test]
async fn refused_files_stay_local_until_they_change() {
    let (client, store) = fake().await;
    let root = tempfile::tempdir().unwrap();
    let mut a = machine(&client, root.path(), "a");
    put_file(root.path(), "s.md", "please refuse-me\n");
    let report = a.pass().await.unwrap();
    assert_eq!(report.refused, vec!["s.md"]);
    assert_eq!(a.state.refused["s.md"].reason, "memory.secret_refused");
    let report = a.pass().await.unwrap();
    assert!(report.refused.is_empty() && report.pushed.is_empty(), "not retried while unchanged");
    put_file(root.path(), "s.md", "fine now\n");
    assert_eq!(a.pass().await.unwrap().pushed, vec!["s.md"]);
    assert!(a.state.refused.is_empty());
    assert_eq!(store.lock().unwrap().puts, 1);
}

#[tokio::test]
async fn one_sync_per_scope_and_state_survives_a_restart() {
    let (client, _store) = fake().await;
    let root = tempfile::tempdir().unwrap();
    let mut a = machine(&client, root.path(), "a");
    assert!(Engine::new(client.clone(), Scope::Team, root.path(), "a".into()).is_err());
    put_file(root.path(), "x.md", "x\n");
    a.pass().await.unwrap();
    let seq = a.state.last_seq;
    drop(a);
    let again = machine(&client, root.path(), "a");
    assert_eq!(again.state.last_seq, seq);
    assert!(again.pending().is_empty());
    let history = client.history(Scope::Team, "x.md").await.unwrap();
    assert_eq!(history["versions"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn link_merges_the_old_folder_then_symlinks_it() {
    let home = tempfile::tempdir().unwrap();
    let mount = tempfile::tempdir().unwrap();
    let private = mount.path().join("private");
    let slug = claude_slugify(&home.path().join("Projects/cmux").to_string_lossy());
    let old = home.path().join(".claude/projects").join(&slug).join("memory");
    std::fs::create_dir_all(&old).unwrap();
    std::fs::write(old.join("MEMORY.md"), "mine\n").unwrap();
    std::fs::create_dir_all(private.join("claude/Projects-cmux")).unwrap();
    std::fs::write(private.join("claude/Projects-cmux/other.md"), "from the fleet\n").unwrap();

    let links = link::plan(link::Harness::Claude, home.path(), &private).unwrap();
    assert_eq!(links.len(), 1);
    assert_eq!(links[0].rel, "claude/Projects-cmux");
    assert_eq!(links[0].files, vec!["MEMORY.md"]);
    assert!(old.join("MEMORY.md").exists(), "a dry run changes nothing");

    let applied = link::apply(&links, None, "a").await.unwrap();
    let kept = applied[0].kept.clone().unwrap();
    assert_eq!(std::fs::read_link(&old).unwrap(), private.join("claude/Projects-cmux"));
    assert_eq!(std::fs::read_to_string(old.join("MEMORY.md")).unwrap(), "mine\n");
    assert_eq!(std::fs::read_to_string(old.join("other.md")).unwrap(), "from the fleet\n");
    assert_eq!(std::fs::read_to_string(kept.join("MEMORY.md")).unwrap(), "mine\n");
    // Linked now: a second plan says so and apply leaves it.
    let again = link::plan(link::Harness::Claude, home.path(), &private).unwrap();
    assert!(again[0].linked);
}
