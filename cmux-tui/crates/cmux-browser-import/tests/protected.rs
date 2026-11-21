//! Reads of a folder macOS protects: the app sends the files' bytes into an upload, in chunks,
//! and the readers read them from memory. Nothing of them is written to disk.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

mod common;

use base64::Engine as _;
use cmux_browser_import::ops::{OpError, call_with};
use cmux_browser_import::place::{Files, Place};
use cmux_browser_import::sqlite::{Snapshot, replay_wal};
use cmux_browser_import::upload::{IDLE, Uploads};
use cmux_browser_import::{chromium, firefox, safari};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, Instant};

fn encode(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn op(uploads: &Uploads, now: Instant, op: &str, request: Value) -> Value {
    call_with(op, &request, None, uploads, now).unwrap()
}

/// Sends `bytes` as file `name` of upload `id`, `chunk` bytes per request.
fn send(uploads: &Uploads, now: Instant, id: &str, name: &str, bytes: &[u8], chunk: usize) {
    for part in bytes.chunks(chunk) {
        let reply = op(
            uploads,
            now,
            "upload.append",
            json!({"upload": id, "name": name, "base64": encode(part)}),
        );
        assert_eq!(reply, json!({"ok": null}));
    }
}

/// A Safari `History.db` in WAL mode: the first visit checkpointed into the main file, the
/// second only in the WAL. The connection is kept open so the WAL stays.
fn wal_history(folder: &Path) -> (Connection, Vec<u8>, Vec<u8>) {
    let file = folder.join("History.db");
    let connection = Connection::open(&file).unwrap();
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
             CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
             CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
             INSERT INTO history_items VALUES (1, 'https://old.example/', 1);
             INSERT INTO history_visits VALUES (1, 1, 700000000.0, 'Old');
             PRAGMA wal_checkpoint(TRUNCATE);
             INSERT INTO history_items VALUES (2, 'https://new.example/', 2);
             INSERT INTO history_visits VALUES (2, 2, 710000000.0, 'New');",
        )
        .unwrap();
    let main = std::fs::read(&file).unwrap();
    let wal = std::fs::read(folder.join("History.db-wal")).unwrap();
    assert!(!wal.is_empty(), "the newest visit is only in the WAL");
    (connection, main, wal)
}

fn urls(reply: &Value) -> Vec<&str> {
    reply["ok"].as_array().unwrap().iter().map(|e| e["url"].as_str().unwrap()).collect()
}

#[test]
fn safari_history_reads_from_an_upload_with_its_wal() {
    let folder = tempfile::tempdir().unwrap();
    let (_open, main, wal) = wal_history(folder.path());
    let (uploads, now) = (Uploads::default(), Instant::now());
    // Small chunks: a file arrives in several appends, as one over 4 MiB must.
    send(&uploads, now, "u-1", "History.db", &main, 1000);
    send(&uploads, now, "u-1", "History.db-wal", &wal, 1000);
    let reply = op(
        &uploads,
        now,
        "safari.history",
        json!({"upload": "u-1", "path": "History.db", "limit": 10}),
    );
    assert_eq!(urls(&reply), ["https://new.example/", "https://old.example/"], "{reply}");
    // The same rows as the private copy of the file on disk.
    let disk = safari::history(folder.path().join("History.db"), 10).unwrap();
    assert_eq!(disk.len(), 2);
    // Without its WAL only the checkpointed visit is there.
    send(&uploads, now, "u-2", "History.db", &main, 1 << 20);
    let reply = op(
        &uploads,
        now,
        "safari.history",
        json!({"upload": "u-2", "path": "History.db", "limit": 10}),
    );
    assert_eq!(urls(&reply), ["https://old.example/"], "{reply}");
}

#[test]
fn a_torn_wal_tail_is_left_out() {
    let folder = tempfile::tempdir().unwrap();
    let (_open, main, wal) = wal_history(folder.path());
    let history = |wal: &[u8]| {
        let mut files = Files::new();
        files.append("History.db".into(), &main);
        files.append("History.db-wal".into(), wal);
        safari::history(Place::memory(&files).join("History.db"), 10).unwrap().len()
    };
    assert_eq!(history(&wal), 2);
    // A frame cut short, a frame whose checksum is wrong, and a WAL with a bad header.
    assert_eq!(history(&wal[..wal.len() - 100]), 1);
    let mut flipped = wal.clone();
    let last = flipped.len() - 1;
    flipped[last] ^= 0xff;
    assert_eq!(history(&flipped), 1);
    assert_eq!(history(b"not a wal"), 1);
    // The image is in rollback mode, so an in-memory open reads it.
    let image = replay_wal(&main, &wal);
    assert_eq!((image[18], image[19]), (1, 1));
    assert_eq!(history(&[]), 1);
    let garbage = Snapshot::from_memory(b"not sqlite", None);
    assert!(garbage.is_err() || garbage.unwrap().query("SELECT 1 FROM t", |_| true).is_err());
}

#[test]
fn a_chromium_profile_reads_from_an_upload() {
    let (uploads, now) = (Uploads::default(), Instant::now());
    let id = "a".repeat(32);
    let manifest = br#"{"name":"Ad Block","version":"2.0"}"#;
    let preferences = format!(
        r#"{{"extensions":{{"settings":{{"{id}":{{"location":1,"from_webstore":true}}}}}},
            "default_search_provider_data":{{"template_url_data":{{"short_name":"Kagi","keyword":"k","url":"https://kagi.com/search?q={{searchTerms}}"}}}}}}"#
    );
    send(&uploads, now, "p", "Preferences", preferences.as_bytes(), 64);
    send(&uploads, now, "p", &format!("Extensions/{id}/2.0_0/manifest.json"), manifest, 64);
    send(&uploads, now, "p", "Sessions/Session_7", b"SNSS", 64);
    send(&uploads, now, "p", "Sessions/Session_12", b"SNSS", 64);
    let read = |reader: &str| op(&uploads, now, reader, json!({"upload": "p", "profile": "."}));
    assert_eq!(read("chromium.session_file"), json!({"ok": "Sessions/Session_12"}));
    let found = read("chromium.extensions");
    assert_eq!(found["ok"][0]["name"], "Ad Block", "{found}");
    assert_eq!(read("chromium.search_engine")["ok"]["name"], "Kagi");
    let tabs = op(
        &uploads,
        now,
        "chromium.session",
        json!({"upload": "p", "path": "Sessions/Session_12"}),
    );
    assert_eq!(tabs, json!({"ok": []}));
    let latest = op(
        &uploads,
        now,
        "chromium.latest_session_file",
        json!({"upload": "p", "sessions": "Sessions"}),
    );
    assert_eq!(latest, json!({"ok": "Sessions/Session_12"}));
    // The readers take the same place on disk or in memory.
    let mut files = Files::new();
    files.append("Current Session".into(), b"");
    assert_eq!(chromium::session_file(Place::memory(&files)), Some("Current Session".into()));
    files.append("sessionstore.jsonlz4".into(), b"");
    assert_eq!(firefox::session_file(Place::memory(&files)), Some("sessionstore.jsonlz4".into()));
}

#[test]
fn names_in_an_upload_stay_inside_it() {
    let (uploads, now) = (Uploads::default(), Instant::now());
    send(&uploads, now, "n", "History", b"x", 8);
    for name in ["/etc/passwd", "../History", "a/../../b"] {
        let request = json!({"upload": "n", "name": name, "base64": encode(b"x")});
        assert_eq!(
            call_with("upload.append", &request, None, &uploads, now),
            Err(OpError::Refused)
        );
        let request = json!({"upload": "n", "path": name});
        assert_eq!(
            call_with("chromium.history", &request, None, &uploads, now),
            Err(OpError::Refused)
        );
    }
    let bad_id = json!({"upload": "../x", "name": "a", "base64": ""});
    assert_eq!(call_with("upload.append", &bad_id, None, &uploads, now), Err(OpError::Invalid));
    assert_eq!(
        call_with("upload.append", &json!({"upload": "n", "name": "a"}), None, &uploads, now),
        Err(OpError::Invalid)
    );
}

#[test]
fn an_upload_over_its_cap_is_refused_and_dropped() {
    let (uploads, now) = (Uploads::with_caps(10, 15), Instant::now());
    send(&uploads, now, "a", "History.db", &[0; 8], 8);
    let over = op(
        &uploads,
        now,
        "upload.append",
        json!({"upload": "a", "name": "History.db-wal", "base64": encode(&[0; 3])}),
    );
    assert_eq!(over["error"]["kind"], "tooLarge", "{over}");
    assert!(uploads.is_empty(), "the upload over its cap is dropped, not kept");
    let gone = op(&uploads, now, "safari.history", json!({"upload": "a", "path": "History.db"}));
    assert_eq!(gone["error"]["kind"], "read", "{gone}");
    // All uploads together are capped too.
    send(&uploads, now, "b", "x", &[0; 10], 10);
    let over = op(
        &uploads,
        now,
        "upload.append",
        json!({"upload": "c", "name": "x", "base64": encode(&[0; 6])}),
    );
    assert_eq!(over["error"]["kind"], "tooLarge");
    assert_eq!(uploads.len(), 1);
}

#[test]
fn an_upload_is_dropped_when_asked_or_left_idle() {
    let (uploads, now) = (Uploads::default(), Instant::now());
    send(&uploads, now, "d", "Bookmarks", b"{}", 8);
    assert_eq!(op(&uploads, now, "upload.drop", json!({"upload": "d"})), json!({"ok": null}));
    assert!(uploads.is_empty());
    send(&uploads, now, "e", "Bookmarks", b"{}", 8);
    let used = now + IDLE - Duration::from_secs(1);
    let read =
        op(&uploads, used, "chromium.bookmarks", json!({"upload": "e", "path": "Bookmarks"}));
    assert_eq!(read["error"]["kind"], "notBookmarks", "a read keeps it: {read}");
    let later = used + IDLE + Duration::from_secs(1);
    let gone =
        op(&uploads, later, "chromium.bookmarks", json!({"upload": "e", "path": "Bookmarks"}));
    assert_eq!(gone["error"]["kind"], "read", "{gone}");
    assert!(uploads.is_empty());
}
