//! The palette ranker equality corpus through the C ABI.
//!
//! `tests/corpus/palette-corpus.json` holds real palette requests and the answers of the
//! TypeScript ranker this crate replaced, taken from its native bridge
//! (`webviews/scripts/palette-ranker-corpus.ts`). Each request goes through the same C calls the
//! macOS app makes: install a snapshot's entries once per version, then one rank call per query.
//! Every ordered result, score and highlight must be identical.

use cmux_palette_ranker::ffi::{
    CmuxPaletteRanker, ERR_NOT_INSTALLED, OK, cmux_palette_ranker_free,
    cmux_palette_ranker_install, cmux_palette_ranker_new, cmux_palette_ranker_rank,
};
use serde_json::Value;
use std::collections::HashSet;

struct Handle(*mut CmuxPaletteRanker);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: a handle from cmux_palette_ranker_new, freed once.
        unsafe { cmux_palette_ranker_free(self.0) };
    }
}

impl Handle {
    fn install(&self, version: i64, entries: &Value) -> Result<(), String> {
        let bytes = serde_json::to_vec(entries).map_err(|error| error.to_string())?;
        // SAFETY: a live handle and a readable buffer.
        let code =
            unsafe { cmux_palette_ranker_install(self.0, version, bytes.as_ptr(), bytes.len()) };
        if code == OK { Ok(()) } else { Err(format!("install {version} returned {code}")) }
    }

    fn rank(&self, request: &Value) -> Result<(i32, Vec<u8>), String> {
        let bytes = serde_json::to_vec(request).map_err(|error| error.to_string())?;
        let mut response: *const u8 = std::ptr::null();
        let mut response_len = 0usize;
        // SAFETY: a live handle, a readable request and writable out pointers.
        let code = unsafe {
            cmux_palette_ranker_rank(
                self.0,
                bytes.as_ptr(),
                bytes.len(),
                &mut response,
                &mut response_len,
            )
        };
        if response.is_null() {
            return Err(format!("rank returned {code} with no response"));
        }
        // SAFETY: the response stays valid until the next call on this handle.
        let body = unsafe { std::slice::from_raw_parts(response, response_len) }.to_vec();
        Ok((code, body))
    }
}

fn corpus() -> Result<Value, String> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus/palette-corpus.json");
    let text = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    serde_json::from_str(&text).map_err(|error| format!("{path}: {error}"))
}

#[test]
fn every_corpus_request_ranks_like_the_typescript_ranker() -> Result<(), String> {
    let corpus = corpus()?;
    let sets = corpus["sets"].as_object().ok_or("corpus has no sets")?;
    let cases = corpus["cases"].as_array().ok_or("corpus has no cases")?;
    assert!(cases.len() >= 200, "the corpus has {} requests, fewer than 200", cases.len());
    let handle = Handle(cmux_palette_ranker_new());
    let mut installed = None;
    let mut failures = Vec::new();
    let mut operations = HashSet::new();
    let mut inline = 0;
    for case in cases {
        let name = case["name"].as_str().unwrap_or("?");
        let set = &sets[case["set"].as_str().ok_or("case without set")?];
        let version = set["version"].as_i64().ok_or("set without version")?;
        // An inline request carries its own entries; the others rank the installed snapshot.
        if case["inline"].as_bool() == Some(true) {
            inline += 1;
        } else if installed != Some(version) {
            handle.install(version, &set["entries"])?;
            installed = Some(version);
        }
        operations.insert(case["request"]["operation"].as_str().unwrap_or("").to_owned());
        let (code, body) = handle.rank(&case["request"])?;
        if code != OK {
            failures.push(format!("{name}: code {code}: {}", String::from_utf8_lossy(&body)));
            continue;
        }
        let actual: Value =
            serde_json::from_slice(&body).map_err(|error| format!("{name}: {error}"))?;
        if actual != case["expected"] {
            failures
                .push(format!("{name}:\n  expected {}\n  actual   {}", case["expected"], actual));
        }
    }
    assert!(
        operations.contains("rank") && operations.contains("rankEmpty"),
        "operations {operations:?}"
    );
    assert!(inline > 0, "the corpus has no inline-entries request");
    assert!(
        failures.is_empty(),
        "{} of {} requests differ:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
    Ok(())
}

#[test]
fn a_request_for_a_version_that_is_not_installed_is_refused() -> Result<(), String> {
    let handle = Handle(cmux_palette_ranker_new());
    handle.install(1, &serde_json::json!([{ "title": "Split Right" }]))?;
    let (code, body) =
        handle.rank(&serde_json::json!({ "operation": "rank", "version": 2, "query": "split" }))?;
    assert_eq!(code, ERR_NOT_INSTALLED);
    assert_eq!(
        String::from_utf8_lossy(&body),
        "palette ranker: no entries installed for version 2"
    );
    let (code, body) =
        handle.rank(&serde_json::json!({ "operation": "rank", "version": 1, "query": "split" }))?;
    assert_eq!(code, OK);
    let ranked: Value = serde_json::from_slice(&body).map_err(|error| error.to_string())?;
    assert_eq!(ranked[0]["rows"][0]["index"], 0);
    Ok(())
}

/// Rows like the macOS palette sends them: titles, keywords and the keycaps of each live shortcut.
fn shortcut_entries() -> Value {
    serde_json::json!([
        { "title": "Split Right", "keywords": ["pane"], "hasShortcut": true, "keycaps": ["⌘", "D"], "actionID": "pane.splitRight" },
        { "title": "Toggle Inspector", "hasShortcut": true, "keycaps": ["⌘", "I"], "actionID": "app.inspector" },
        { "title": "Command Palette", "hasShortcut": true, "keycaps": ["⇧", "⌘", "P"], "actionID": "palette.open" },
        { "title": "Print", "keywords": ["paper"], "hasShortcut": true, "keycaps": ["⌘", "P"], "actionID": "app.print" },
        { "title": "Next Tab", "hasShortcut": true, "keycaps": ["⌃", "⇥"], "actionID": "tab.next" },
        { "title": "Kill Line", "hasShortcut": true, "keycaps": ["⌥", "⇧", "K"], "actionID": "edit.killLine" },
        { "title": "Select Workspace 1…9", "hasShortcut": true, "keycaps": ["⌘", "1…9"], "actionID": "workspace.select" },
        { "title": "Leader Close", "hasShortcut": true, "keycaps": ["⌃", "B", "C"], "actionID": "leader.close" },
        { "title": "Scroll To Bottom", "hasShortcut": true, "keycaps": ["G"], "actionID": "browser.bottom" },
        { "title": "Inspect Element", "keywords": ["devtools"], "actionID": "browser.inspect" },
        { "title": "Disabled Thing", "isEnabled": false, "hasShortcut": true, "keycaps": ["⌘", "J"], "actionID": "x.disabled" },
        { "title": "Zoom Out", "hasShortcut": true, "keycaps": ["⌘", "-"], "actionID": "view.zoomOut" },
        { "title": "Show Help", "hasShortcut": true, "keycaps": ["⇧", "⌘", "/"], "actionID": "app.help" },
        { "title": "Next Sidebar Tab", "hasShortcut": true, "keycaps": ["⌃", "\u{f72d}"], "actionID": "sidebar.next" },
        { "title": "Quick Look", "hasShortcut": true, "keycaps": ["⌘", "␣"], "actionID": "app.quickLook" },
        { "title": "Find In Page", "hasShortcut": true, "keycaps": ["⌘", "F"], "actionID": "browser.find" }
    ])
}

fn first_titles(
    handle: &Handle,
    version: i64,
    query: &str,
    count: usize,
) -> Result<Vec<String>, String> {
    let entries = shortcut_entries();
    let (code, body) = handle.rank(&serde_json::json!({
        "operation": "rank", "version": version, "query": query
    }))?;
    if code != OK {
        return Err(format!("{query}: code {code}: {}", String::from_utf8_lossy(&body)));
    }
    let sections: Value = serde_json::from_slice(&body).map_err(|error| error.to_string())?;
    let titles = sections
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|section| section["rows"].as_array().cloned().unwrap_or_default())
        .filter_map(|row| row["index"].as_u64())
        .filter_map(|index| entries[index as usize]["title"].as_str().map(str::to_owned))
        .take(count)
        .collect();
    Ok(titles)
}

#[test]
fn a_typed_shortcut_finds_its_action_first() -> Result<(), String> {
    let handle = Handle(cmux_palette_ranker_new());
    handle.install(7, &shortcut_entries())?;
    let cases: &[(&str, &str)] = &[
        ("cmd i", "Toggle Inspector"),
        ("cmd+i", "Toggle Inspector"),
        ("CMD I", "Toggle Inspector"),
        ("⌘I", "Toggle Inspector"),
        ("command-i", "Toggle Inspector"),
        ("cmd shift p", "Command Palette"),
        ("shift cmd p", "Command Palette"),
        ("⌘⇧P", "Command Palette"),
        ("⇧⌘P", "Command Palette"),
        ("cmd+shift+P", "Command Palette"),
        ("cmd p", "Print"),
        ("ctrl-tab", "Next Tab"),
        ("control tab", "Next Tab"),
        ("⌃⇥", "Next Tab"),
        ("⌥⇧K", "Kill Line"),
        ("opt shift k", "Kill Line"),
        ("alt+shift+k", "Kill Line"),
        ("cmd 3", "Select Workspace 1…9"),
        ("ctrl b c", "Leader Close"),
        ("cmd -", "Zoom Out"),
        ("cmd+-", "Zoom Out"),
        ("cmd d", "Split Right"),
        ("Cmd + P", "Print"),
        ("⌘-D", "Split Right"),
        ("cmd ?", "Show Help"),
        ("cmd shift /", "Show Help"),
        ("ctrl pagedown", "Next Sidebar Tab"),
        ("cmd space", "Quick Look"),
        ("⌘␣", "Quick Look"),
        ("cmd f", "Find In Page"),
    ];
    let mut failures = Vec::new();
    for (query, title) in cases {
        let first = first_titles(&handle, 7, query, 1)?;
        if first.first().map(String::as_str) != Some(*title) {
            failures.push(format!("{query:?}: first {first:?}, want {title:?}"));
        }
    }
    // A disabled row bound to the shortcut still shows, after the enabled rows.
    if !first_titles(&handle, 7, "cmd j", 20)?.iter().any(|title| title == "Disabled Thing") {
        failures.push("\"cmd j\" lost the disabled row".to_owned());
    }
    // The user's own alias for the query still wins over the bound shortcut.
    let (code, body) = handle.rank(&serde_json::json!({
        "operation": "rank", "version": 7, "query": "cmd i",
        "aliases": { "browser.find": ["cmd i"] }
    }))?;
    let ranked: Value = serde_json::from_slice(&body).map_err(|error| error.to_string())?;
    let order: Vec<u64> = ranked
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|section| section["rows"].as_array().cloned().unwrap_or_default())
        .filter_map(|row| row["index"].as_u64())
        .take(2)
        .collect();
    if code != OK || order != [15, 1] {
        failures.push(format!("alias \"cmd i\": code {code}, first rows {order:?}, want [15, 1]"));
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    Ok(())
}

#[test]
fn word_queries_rank_the_same_with_and_without_keycaps() -> Result<(), String> {
    let with_caps = shortcut_entries();
    let mut without_caps = with_caps.clone();
    for entry in without_caps.as_array_mut().into_iter().flatten() {
        if let Some(entry) = entry.as_object_mut() {
            entry.remove("keycaps");
        }
    }
    let with_handle = Handle(cmux_palette_ranker_new());
    with_handle.install(1, &with_caps)?;
    let without_handle = Handle(cmux_palette_ranker_new());
    without_handle.install(1, &without_caps)?;
    let mut failures = Vec::new();
    // Words, a lone modifier, a modifier with a word that is not a key, and a key with no modifier.
    for query in [
        "split",
        "inspect",
        "cmd",
        "command",
        "opt",
        "alt",
        "shift",
        "p",
        "g",
        "tab",
        "alt text",
        "cmd palette",
        "print paper",
        "i cmd",
    ] {
        let request = serde_json::json!({ "operation": "rank", "version": 1, "query": query });
        let (with_code, with_body) = with_handle.rank(&request)?;
        let with_body = with_body.clone();
        let (without_code, without_body) = without_handle.rank(&request)?;
        if (with_code, &with_body) != (without_code, &without_body) {
            failures.push(format!(
                "{query:?}:\n  with keycaps    {}\n  without keycaps {}",
                String::from_utf8_lossy(&with_body),
                String::from_utf8_lossy(&without_body)
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    Ok(())
}
