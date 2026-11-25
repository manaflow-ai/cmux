//! Each reader on a fixture in its source's format, against the Swift reader's rules (the Swift
//! package has no test of these readers; each case below is the Swift code's branch it names).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

mod common;

use cmux_browser_import::time::UNIX_TO_REFERENCE;
use cmux_browser_import::{
    Bookmark, ReadError, arc, chromium, exported, firefox, lz4, pickle, safari, search, url,
};
use rusqlite::Connection;
use std::path::Path;

fn database(path: &Path, sql: &str) {
    let connection = Connection::open(path).unwrap();
    connection.execute_batch(sql).unwrap();
}

fn titles(bookmarks: &[Bookmark]) -> Vec<(String, String, Vec<String>)> {
    bookmarks.iter().map(|b| (b.title.clone(), b.url.clone(), b.folder_path.clone())).collect()
}

fn s(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| (*p).to_owned()).collect()
}

// MARK: Chromium

#[test]
fn chromium_bookmarks_walk_the_three_roots() {
    let data = br#"{"roots":{
        "bookmark_bar":{"name":"Bookmarks bar","children":[
            {"type":"url","name":"A","url":"https://a.example/","date_added":"13300000000000000"},
            {"type":"url","name":"","url":"https://untitled.example/"},
            {"type":"url","name":"Internal","url":"chrome://settings"},
            {"type":"folder","name":"Work","children":[{"type":"url","name":"B","url":"HTTP://b.example/"}]}]},
        "other":{"name":"","children":[{"type":"url","name":"C","url":"file:///tmp/c.html"}]},
        "synced":{"name":"Mobile","children":[{"type":"url","name":"D","url":"https://d.example/"}, 3]}}}"#;
    let bookmarks = chromium::bookmarks(data).unwrap();
    assert_eq!(
        titles(&bookmarks),
        [
            ("A".into(), "https://a.example/".into(), s(&["Bookmarks bar"])),
            (
                "https://untitled.example/".into(),
                "https://untitled.example/".into(),
                s(&["Bookmarks bar"])
            ),
            ("B".into(), "HTTP://b.example/".into(), s(&["Bookmarks bar", "Work"])),
            ("C".into(), "file:///tmp/c.html".into(), s(&["other"])),
        ]
    );
    // 13300000000000000 µs since 1601: 1655526400 s since 1970.
    assert_eq!(
        bookmarks[0].date_added,
        Some(13_300_000_000_000_000.0 / 1e6 - 11_644_473_600.0 - UNIX_TO_REFERENCE)
    );
    assert_eq!(bookmarks[1].date_added, None);
    assert_eq!(chromium::bookmarks(b"[1]"), Err(ReadError::Shape("notBookmarks")));
    assert!(matches!(chromium::bookmarks(b"not json"), Err(ReadError::Syntax(_))));
}

#[test]
fn chromium_history_is_newest_first_and_importable_only() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("History");
    database(
        &file,
        "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
         INSERT INTO urls VALUES (1, 'https://old.example/', 'Old', 2, 0, 13000000000000000, 0);
         INSERT INTO urls VALUES (2, 'https://new.example/', '', 5, 0, 13300000000000000, 0);
         INSERT INTO urls VALUES (3, 'chrome://history', 'H', 9, 0, 13400000000000000, 0);
         INSERT INTO urls VALUES (4, 'https://hidden.example/', 'X', 9, 0, 13400000000000000, 1);
         INSERT INTO urls VALUES (5, 'https://never.example/', 'X', 0, 0, 13400000000000000, 0);
         INSERT INTO urls VALUES (6, 'https://undated.example/', 'X', 1, 0, 0, 0);",
    );
    let entries = chromium::history(&file, 10).unwrap();
    let urls: Vec<&str> = entries.iter().map(|e| e.url.as_str()).collect();
    assert_eq!(urls, ["https://new.example/", "https://old.example/"]);
    assert_eq!(entries[0].title, None);
    assert_eq!(entries[0].visit_count, 5);
    assert_eq!(entries[1].title.as_deref(), Some("Old"));
    assert_eq!(chromium::history(&file, 1).unwrap().len(), 1);
    assert_eq!(chromium::history(&file, -3).unwrap().len(), 0);
    assert!(matches!(chromium::history(folder.path().join("missing"), 1), Err(ReadError::Copy(_))));
}

/// A pickle of int32 fields and strings, 4-byte aligned, with its size header.
struct PickleWriter(Vec<u8>);

impl PickleWriter {
    fn int32(mut self, v: i32) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn string(mut self, text: &str) -> Self {
        self = self.int32(text.len() as i32);
        self.0.extend_from_slice(text.as_bytes());
        while !self.0.len().is_multiple_of(4) {
            self.0.push(0);
        }
        self
    }
    fn string16(mut self, text: &str) -> Self {
        let units: Vec<u16> = text.encode_utf16().collect();
        self = self.int32(units.len() as i32);
        for unit in units {
            self.0.extend_from_slice(&unit.to_le_bytes());
        }
        while !self.0.len().is_multiple_of(4) {
            self.0.push(0);
        }
        self
    }
    fn pickled(self) -> Vec<u8> {
        let mut out = (self.0.len() as u32).to_le_bytes().to_vec();
        out.extend(self.0);
        out
    }
}

fn command(id: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = ((payload.len() + 1) as u16).to_le_bytes().to_vec();
    out.push(id);
    out.extend_from_slice(payload);
    out
}

fn raw(fields: &[i32]) -> Vec<u8> {
    fields.iter().flat_map(|f| f.to_le_bytes()).collect()
}

fn navigation(tab: i32, index: i32, url: &str, title: &str) -> Vec<u8> {
    command(
        6,
        &PickleWriter(Vec::new()).int32(tab).int32(index).string(url).string16(title).pickled(),
    )
}

#[test]
fn chromium_session_replays_tabs_windows_and_closes() {
    let mut data = b"SNSS".to_vec();
    data.extend_from_slice(&3u32.to_le_bytes());
    // Tab 1 in window 10 at index 1, two navigations, the first selected.
    data.extend(command(0, &raw(&[10, 1])));
    data.extend(command(2, &raw(&[1, 1])));
    data.extend(navigation(1, 0, "https://first.example/", "Fïrst"));
    data.extend(navigation(1, 1, "https://second.example/", "Second"));
    data.extend(command(7, &raw(&[1, 0])));
    // Tab 2 in window 10 at index 0, pinned, no selection: its newest navigation.
    data.extend(command(0, &raw(&[10, 2])));
    data.extend(command(2, &raw(&[2, 0])));
    data.extend(command(12, &raw(&[2, 1])));
    data.extend(navigation(2, 0, "https://a.example/", ""));
    data.extend(navigation(2, 3, "https://pinned.example/", ""));
    // Tab 3 in window 20; tab 4 closed; window 30 closed.
    data.extend(command(0, &raw(&[20, 3])));
    data.extend(navigation(3, 0, "https://other-window.example/", "W"));
    data.extend(navigation(4, 0, "https://closed.example/", "C"));
    data.extend(command(16, &raw(&[4])));
    data.extend(command(0, &raw(&[30, 5])));
    data.extend(navigation(5, 0, "https://closed-window.example/", "CW"));
    data.extend(command(17, &raw(&[30])));
    // An internal page and a cut-off command at the end.
    data.extend(command(0, &raw(&[20, 6])));
    data.extend(command(2, &raw(&[6, 1])));
    data.extend(navigation(6, 0, "chrome://newtab/", "New Tab"));
    data.extend_from_slice(&[0xFF, 0x00, 6, 1]);
    let tabs = chromium::session(&data);
    let got: Vec<(&str, Option<&str>, usize, bool)> =
        tabs.iter().map(|t| (t.url.as_str(), t.title.as_deref(), t.window, t.pinned)).collect();
    assert_eq!(
        got,
        [
            ("https://pinned.example/", None, 0, true),
            ("https://first.example/", Some("Fïrst"), 0, false),
            ("https://other-window.example/", Some("W"), 1, false),
        ]
    );
    let mut encrypted = b"SNSS".to_vec();
    encrypted.extend_from_slice(&4u32.to_le_bytes());
    encrypted.extend(navigation(1, 0, "https://a.example/", "A"));
    assert!(chromium::session(&encrypted).is_empty());
    assert!(chromium::session(b"SNS").is_empty());
}

#[test]
fn chromium_session_files_pick_the_newest() {
    let profile = tempfile::tempdir().unwrap();
    assert_eq!(chromium::session_file(profile.path()), None);
    common::write(profile.path(), "Current Session", b"");
    assert_eq!(
        chromium::session_file(profile.path()),
        Some(profile.path().join("Current Session"))
    );
    for name in ["Session_9", "Session_13", "Session_x", "Tabs_99"] {
        common::write(profile.path(), &format!("Sessions/{name}"), b"");
    }
    assert_eq!(
        chromium::session_file(profile.path()),
        Some(profile.path().join("Sessions/Session_13"))
    );
}

#[test]
fn chromium_extensions_keep_store_installs_only() {
    let profile = tempfile::tempdir().unwrap();
    let p = profile.path();
    let id = |c: char| c.to_string().repeat(32);
    let (store, policy, default, theme, unpacked, localized, disabled) =
        (id('a'), id('b'), id('c'), id('d'), id('e'), id('f'), id('g'));
    let preferences = format!(
        r#"{{"extensions":{{"settings":{{
        "{store}":{{"location":1,"from_webstore":true,"state":1,"manifest":{{"name":"Zeta","version":"0.1"}}}},
        "{policy}":{{"location":7,"manifest":{{"name":"Policy"}}}},
        "{default}":{{"location":1,"was_installed_by_default":true,"manifest":{{"name":"Default"}}}},
        "{theme}":{{"location":1,"manifest":{{"name":"Theme","theme":{{}}}}}},
        "{unpacked}":{{"location":4,"manifest":{{"name":"Unpacked"}}}},
        "{disabled}":{{"location":1,"state":0,"manifest":{{"name":"alpha"}}}},
        "nmmhkkegccagdldgiimedpiccmgmieda":{{"location":1,"manifest":{{"name":"Payments"}}}},
        "not-an-id":{{"manifest":{{"name":"Bad"}}}}}}}}}}"#
    );
    common::write(p, "Preferences", preferences.as_bytes());
    // Secure Preferences wins per field.
    common::write(
        p,
        "Secure Preferences",
        format!(r#"{{"extensions":{{"settings":{{"{store}":{{"disable_reasons":1}}}}}}}}"#)
            .as_bytes(),
    );
    // A localized name in the newest version folder; only the manifest knows this one.
    common::write(p, &format!("Extensions/{localized}/1.9_0/manifest.json"), br#"{"name":"old"}"#);
    common::write(
        p,
        &format!("Extensions/{localized}/1.10_0/manifest.json"),
        br#"{"name":"__MSG_appName__","default_locale":"de","version":"1.10","update_url":"https://clients2.google.com/service/update2/crx"}"#,
    );
    common::write(
        p,
        &format!("Extensions/{localized}/1.10_0/_locales/de/messages.json"),
        br#"{"APPNAME":{"message":"Mittel"}}"#,
    );
    let found = chromium::extensions(p);
    let got: Vec<(&str, &str, Option<&str>, bool)> = found
        .iter()
        .map(|e| (e.id.as_str(), e.name.as_str(), e.version.as_deref(), e.enabled))
        .collect();
    assert_eq!(
        got,
        [
            (disabled.as_str(), "alpha", None, false),
            (localized.as_str(), "Mittel", Some("1.10"), true),
            (store.as_str(), "Zeta", Some("0.1"), false),
        ]
    );
}

// MARK: Arc

#[test]
fn arc_reads_favorites_then_pinned_spaces_of_the_profile() {
    let data = br#"{"sidebar":{"containers":[{"global":{}},{
        "topAppsContainerIDs":[{"default":true},"top",{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"top2"],
        "items":["top",{"id":"top","childrenIds":["fav"]},
                 "fav",{"id":"fav","title":"","data":{"tab":{"savedURL":"https://mail.example/","savedTitle":"Mail"}},"createdAt":700000000.5},
                 "pin",{"id":"pin","childrenIds":["t1","list","bad"]},
                 "t1",{"id":"t1","title":"Docs","data":{"tab":{"savedURL":"https://docs.example/"}}},
                 "list",{"id":"list","title":"Reading","data":{"list":{}},"childrenIds":["t2"]},
                 "t2",{"id":"t2","data":{"tab":{"savedURL":"https://read.example/"}}},
                 "bad",{"id":"bad","data":{"tab":{"savedURL":"arc://boost"}}},
                 "top2",{"id":"top2","childrenIds":["t1"]}],
        "spaces":["s1",{"id":"s1","title":"","profile":{"default":true},"containerIDs":["unpinned","u","pinned","pin"]},
                  "s2",{"id":"s2","title":"Other","profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"containerIDs":["pinned","pin"]}]}]}}"#;
    let bookmarks = arc::bookmarks(data, "Default").unwrap();
    assert_eq!(
        titles(&bookmarks),
        [
            ("Mail".into(), "https://mail.example/".into(), s(&["Favorites"])),
            ("Docs".into(), "https://docs.example/".into(), s(&["Space"])),
            (
                "https://read.example/".into(),
                "https://read.example/".into(),
                s(&["Space", "Reading"])
            ),
        ]
    );
    assert_eq!(bookmarks[0].date_added, Some(700_000_000.5));
    let other = arc::bookmarks(data, "Profile 1").unwrap();
    assert_eq!(other.len(), 3);
    assert_eq!(other[0].folder_path, s(&["Favorites"]));
    assert_eq!(other[1].folder_path, s(&["Other"]));
    assert_eq!(
        arc::bookmarks(br#"{"sidebar":{"containers":[1]}}"#, "Default"),
        Err(ReadError::Shape("notSidebar"))
    );
    assert_eq!(arc::bookmarks(br#"{"sidebar":{"containers":[{}]}}"#, "Default"), Ok(Vec::new()));
}

// MARK: Firefox

#[test]
fn firefox_places_bookmarks_and_history() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("places.sqlite");
    database(
        &file,
        "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER);
         CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, guid TEXT);
         INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 0, 'root________');
         INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'toolbar', 0, 'toolbar_____');
         INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 2, 0, 'Dev', 0, 'devfolder___');
         INSERT INTO moz_bookmarks VALUES (4, 2, NULL, 1, 1, 'tags', 0, 'tags________');
         INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 4, 0, 'rust', 0, 'tagrust_____');
         INSERT INTO moz_places VALUES (10, 'https://a.example/', 'A page', 3, 0, 1700000000000000);
         INSERT INTO moz_places VALUES (11, 'https://b.example/', NULL, 1, 0, 1600000000000000);
         INSERT INTO moz_places VALUES (12, 'place:sort=8', 'Recent', 1, 0, 1800000000000000);
         INSERT INTO moz_places VALUES (13, 'https://never.example/', 'N', 1, 0, NULL);
         INSERT INTO moz_bookmarks VALUES (20, 1, 10, 3, 1, 'Second', 1650000000000000, 'b1__________');
         INSERT INTO moz_bookmarks VALUES (21, 1, 11, 3, 0, '', 0, 'b2__________');
         INSERT INTO moz_bookmarks VALUES (22, 1, 10, 5, 0, 'tagged', 0, 'b3__________');
         INSERT INTO moz_bookmarks VALUES (23, 1, 12, 2, 0, 'smart', 0, 'b4__________');",
    );
    let bookmarks = firefox::bookmarks(&file).unwrap();
    assert_eq!(
        titles(&bookmarks),
        [
            (
                "https://b.example/".into(),
                "https://b.example/".into(),
                s(&["Bookmarks Toolbar", "Dev"])
            ),
            ("Second".into(), "https://a.example/".into(), s(&["Bookmarks Toolbar", "Dev"])),
        ]
    );
    assert_eq!(bookmarks[0].date_added, None);
    assert_eq!(bookmarks[1].date_added, Some(1_650_000_000.0 - UNIX_TO_REFERENCE));
    let history = firefox::history(&file, 10).unwrap();
    let urls: Vec<&str> = history.iter().map(|e| e.url.as_str()).collect();
    assert_eq!(urls, ["https://a.example/", "https://b.example/"]);
    assert_eq!(history[0].visit_count, 3);
    assert_eq!(history[1].title, None);
}

#[test]
fn firefox_session_files_in_order() {
    let profile = tempfile::tempdir().unwrap();
    assert_eq!(firefox::session_file(profile.path()), None);
    common::write(profile.path(), "sessionstore-backups/previous.jsonlz4", b"");
    common::write(profile.path(), "sessionstore.jsonlz4", b"");
    assert_eq!(
        firefox::session_file(profile.path()),
        Some(profile.path().join("sessionstore.jsonlz4"))
    );
}

#[test]
fn firefox_session_reads_windows_titles_and_pins() {
    let json = r#"{"windows":[{"tabs":[{"entries":[{"url":"https://a.example/","title":"A"}],"pinned":true},
        {"entries":[]},{"entries":[{"url":"about:config"}]}]},{"tabs":[{"index":1.0,"entries":[{"url":"https://b.example/","title":""}],"pinned":1}]}]}"#;
    let tabs = firefox::session(&common::moz_lz4(json));
    let got: Vec<(&str, Option<&str>, usize, bool)> =
        tabs.iter().map(|t| (t.url.as_str(), t.title.as_deref(), t.window, t.pinned)).collect();
    assert_eq!(
        got,
        [("https://a.example/", Some("A"), 0, true), ("https://b.example/", None, 1, true)]
    );
    assert!(firefox::session(b"mozLz40\0\x05\0\0\0").is_empty());
}

#[test]
fn lz4_blocks_with_matches_decode() {
    // "abcabcabcabc!": literals "abc", a match of 9 at offset 3, then the literal "!".
    let block = [0x35, b'a', b'b', b'c', 3, 0, 0x10, b'!'];
    assert_eq!(lz4::block(&block, 13).as_deref(), Some(b"abcabcabcabc!".as_slice()));
    // The output fills before the block ends: the stated size is what is kept.
    assert_eq!(lz4::block(&block, 5).as_deref(), Some(b"abcab".as_slice()));
    // A block shorter than the stated size, or a match before the output's start.
    assert_eq!(lz4::block(&block, 20), None);
    assert_eq!(lz4::block(&[0x10, b'a', 9, 0, 0x00], 9), None);
    let mut file = b"mozLz40\0".to_vec();
    file.extend_from_slice(&13u32.to_le_bytes());
    file.extend_from_slice(&block);
    assert_eq!(lz4::decompress(&file).as_deref(), Some(b"abcabcabcabc!".as_slice()));
    assert_eq!(lz4::decompress(b"mozLz40\0\0\0\0\0x"), None);
    assert_eq!(lz4::decompress(b"mozLz41\0\x01\0\0\0\x10a"), None);
}

#[test]
fn firefox_search_engine_without_metadata_or_engines_is_nothing() {
    assert_eq!(
        firefox::search_engine_json(br#"{"engines":[],"metaData":{"defaultEngineId":"x"}}"#),
        None
    );
    assert_eq!(firefox::search_engine_json(br#"{"engines":[1],"metaData":{"current":"x"}}"#), None);
    // `alias` when `_definedAliases` has none; the page template is the first text/html one.
    let engine = firefox::search_engine_json(
        br#"{"engines":[{"id":"x","_name":"","alias":"ex","_definedAliases":[],"_urls":[{"type":"application/json","template":"https://ex.example/j?q={searchTerms}"},{"template":"https://www.ex.example/s?q={searchTerms}"}]}],"metaData":{"defaultEngineId":"x"}}"#,
    )
    .unwrap();
    assert_eq!(engine.name, "ex.example");
    assert_eq!(engine.keyword.as_deref(), Some("ex"));
    assert_eq!(engine.search, "https://www.ex.example/s?q={searchTerms}");
    assert_eq!(engine.suggest, None);
}

// MARK: Safari

#[test]
fn safari_bookmarks_name_the_built_in_folders() {
    let plist = br#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Children</key><array>
  <dict><key>WebBookmarkType</key><string>WebBookmarkTypeProxy</string><key>Title</key><string>History</string></dict>
  <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>BookmarksBar</string>
    <key>Children</key><array>
      <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string><key>URLString</key><string>https://apple.example/</string>
        <key>URIDictionary</key><dict><key>title</key><string>Apple</string></dict></dict>
      <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>Work</string>
        <key>Children</key><array><dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string><key>URLString</key><string>https://w.example/</string></dict></array></dict>
    </array></dict>
  <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>com.apple.ReadingList</string>
    <key>Children</key><array><dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string><key>URLString</key><string>javascript:void(0)</string></dict>
      <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string><key>URLString</key><string>https://r.example/</string><key>URIDictionary</key><dict><key>title</key><string></string></dict></dict></array></dict>
</array></dict></plist>"#;
    assert_eq!(
        titles(&safari::bookmarks(plist).unwrap()),
        [
            ("Apple".into(), "https://apple.example/".into(), s(&["Favorites"])),
            ("https://w.example/".into(), "https://w.example/".into(), s(&["Favorites", "Work"])),
            ("https://r.example/".into(), "https://r.example/".into(), s(&["Reading List"])),
        ]
    );
    // The same tree as a binary plist.
    let value = plist::Value::from_reader(std::io::Cursor::new(&plist[..])).unwrap();
    let mut binary = Vec::new();
    value.to_writer_binary(&mut binary).unwrap();
    assert_eq!(safari::bookmarks(&binary).unwrap().len(), 3);
    assert!(matches!(safari::bookmarks(b"nope"), Err(ReadError::Syntax(_))));
}

#[test]
fn safari_history_takes_the_newest_visit_and_its_title() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("History.db");
    database(
        &file,
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
         CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
         INSERT INTO history_items VALUES (1, 'https://a.example/', 4);
         INSERT INTO history_items VALUES (2, 'https://b.example/', 1);
         INSERT INTO history_items VALUES (3, 'feed://c.example/', 1);
         INSERT INTO history_visits VALUES (1, 1, 700000000.0, 'Old title');
         INSERT INTO history_visits VALUES (2, 1, 710000000.25, 'New title');
         INSERT INTO history_visits VALUES (3, 2, 705000000.0, NULL);
         INSERT INTO history_visits VALUES (4, 3, 720000000.0, 'C');",
    );
    let entries = safari::history(&file, 10).unwrap();
    let got: Vec<(&str, Option<&str>, i64, f64)> = entries
        .iter()
        .map(|e| (e.url.as_str(), e.title.as_deref(), e.visit_count, e.last_visit))
        .collect();
    assert_eq!(
        got,
        [
            ("https://a.example/", Some("New title"), 4, 710_000_000.25),
            ("https://b.example/", None, 1, 705_000_000.0)
        ]
    );
}

// MARK: Exported history

#[test]
fn exported_history_merges_rows_per_url() {
    assert!(exported::looks_like_history(r#"{"history": ["#));
    assert!(exported::looks_like_history(r#"{"Browser History":"#));
    assert!(!exported::looks_like_history(r#" {"history":"#));
    let safari = br#"{"history":[
        {"url":"https://a.example/","title":"A1","time_usec":1700000000000000,"visit_count":3},
        {"url":"https://a.example/","title":"","time_usec":1800000000000000,"visit_count":0},
        {"url":"https://b.example/","time_usec":1750000000000000},
        {"url":"about:blank","time_usec":1900000000000000}]}"#;
    let read = exported::parse(safari, 10).unwrap();
    assert_eq!(read.format, exported::Format::Safari);
    let got: Vec<(&str, Option<&str>, i64, f64)> = read
        .entries
        .iter()
        .map(|e| (e.url.as_str(), e.title.as_deref(), e.visit_count, e.last_visit))
        .collect();
    assert_eq!(
        got,
        [
            ("https://a.example/", Some("A1"), 4, 1_800_000_000.0 - UNIX_TO_REFERENCE),
            ("https://b.example/", None, 1, 1_750_000_000.0 - UNIX_TO_REFERENCE),
        ]
    );
    assert_eq!(exported::parse(safari, 1).unwrap().entries.len(), 1);
    let takeout = br#"{"Browser History":[{"url":"https://c.example/","title":"C","time_usec":1,"visit_count":50},
        {"url":"https://c.example/","title":"C2","time_usec":2}]}"#;
    let read = exported::parse(takeout, 10).unwrap();
    assert_eq!(read.format, exported::Format::ChromeTakeout);
    assert_eq!(read.entries[0].visit_count, 2);
    assert_eq!(read.entries[0].title.as_deref(), Some("C2"));
    assert_eq!(exported::parse(br#"{"history":[1]}"#, 10), None);
    assert_eq!(exported::parse(b"[]", 10), None);
}

// MARK: Shared rules

#[test]
fn importable_urls_and_hosts() {
    assert_eq!(url::importable("HTTPS://a.example/x y"), Some("HTTPS://a.example/x y"));
    assert_eq!(url::importable("ftp://f.example/"), Some("ftp://f.example/"));
    for text in
        ["chrome://settings", "javascript:alert(1)", "", "no scheme", "1http://x/", "about:blank"]
    {
        assert_eq!(url::importable(text), None, "{text}");
    }
    assert_eq!(
        url::host("https://user:pw@WWW.Example.com:8080/p?q#f").as_deref(),
        Some("www.example.com")
    );
    assert_eq!(url::host("https://[::1]:80/").as_deref(), Some("::1"));
    assert_eq!(url::host("mailto:a@b.example"), None);
    assert_eq!(
        search::host("https://www.google.com/search?q={searchTerms}").as_deref(),
        Some("google.com")
    );
    assert_eq!(search::host("https://kagi.com/search?q=%s").as_deref(), Some("kagi.com"));
}

#[test]
fn clean_drops_placeholders_and_empty_items() {
    assert_eq!(
        search::clean(
            "https://e.example/s?{google:RLZ}q={searchTerms}&ie={inputEncoding}&t=&flag&#top"
        ),
        "https://e.example/s?q={searchTerms}&flag#top"
    );
    assert_eq!(
        search::clean("https://e.example/s?a=%7Bx%7D&q={searchTerms}"),
        "https://e.example/s?q={searchTerms}"
    );
    assert_eq!(search::clean("https://e.example/s?t={google:x}"), "https://e.example/s");
    assert_eq!(
        search::clean("https://e.example/{google:1}/{searchTerms}"),
        "https://e.example/{google:1}/{searchTerms}"
    );
    assert_eq!(
        search::well_known(&[Some("com.google.www")]).map(|e| e.name).as_deref(),
        Some("Google")
    );
    assert_eq!(search::well_known(&[None, Some("")]), None);
}

#[test]
fn pickle_reads_are_bounded() {
    assert!(pickle::Pickle::new(&[8, 0, 0, 0, 1, 0, 0, 0]).is_none());
    let mut p = pickle::Pickle::new(&[4, 0, 0, 0, 2, 0, 0, 0, b'h', b'i']).unwrap();
    assert_eq!(p.string().as_deref(), Some("hi"));
    assert_eq!(p.int32(), None);
    let mut raw = pickle::Pickle::raw(&[1, 0, 0, 0, 2, 0, 0, 0]);
    assert_eq!(raw.int64(), Some((2 << 32) | 1));
    let mut short = pickle::Pickle::raw(&[0xFF, 0xFF, 0xFF, 0x7F]);
    assert_eq!(short.string16(), None);
}
