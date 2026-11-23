//! The Swift package's own tests of these readers, each assertion kept: the Rust readers give
//! what `CmuxNextAppTests` asserts of the Swift ones.
//!
//! - `FirefoxSafariSearchEngineTests.swift`
//! - `FirefoxSessionReaderTests.swift`
//! - `ImportedSearchEngineTests.swift`
//!
//! A fixture is the Swift test's own text. `FirefoxSafariSearchEngineTests` compresses
//! `search.json.mozlz4` with Apple's LZ4 encoder; here the same JSON goes in one literal run
//! (`FirefoxSessionReaderTests`' builder), which the same decoder reads.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

mod common;

use cmux_browser_import::search::{self, Setting};
use cmux_browser_import::{SearchEngine, chromium, firefox, safari};
use serde_json::json;
use std::path::PathBuf;

const BUILT_IN: [(&str, &str); 2] = [
    ("google", "https://www.google.com/search?q={searchTerms}"),
    ("duckduckgo", "https://duckduckgo.com/?q={searchTerms}"),
];

fn setting(engine: &SearchEngine) -> Setting {
    search::setting(engine, BUILT_IN)
}

// MARK: FirefoxSafariSearchEngineTests

/// A profile folder holding `json` as `search.json.mozlz4`.
fn firefox_profile(json: &str) -> (tempfile::TempDir, PathBuf) {
    let folder = tempfile::tempdir().unwrap();
    common::write(folder.path(), "search.json.mozlz4", &common::moz_lz4(json));
    let path = folder.path().to_path_buf();
    (folder, path)
}

#[test]
fn an_engine_added_in_firefox_keeps_its_addresses() {
    let (_keep, folder) = firefox_profile(
        r#"
        {"version":10,"engines":[{"id":"google","_name":"Google","_isAppProvided":true},
          {"id":"a1","_name":"Kagi","_definedAliases":["@kagi"],"_urls":[
            {"template":"https://kagi.com/search","params":[{"name":"q","value":"{searchTerms}"},{"name":"l","value":"{moz:locale}"}]},
            {"type":"application/x-suggestions+json","template":"https://kagi.com/api/autosuggest?q={searchTerms}","params":[]}]}],
         "metaData":{"defaultEngineId":"a1","appDefaultEngineId":"google"}}
        "#,
    );
    let engine = firefox::search_engine(&folder).expect("an engine");
    assert_eq!(engine.name, "Kagi");
    assert_eq!(engine.keyword.as_deref(), Some("@kagi"));
    assert_eq!(engine.search, "https://kagi.com/search?q={searchTerms}");
    assert_eq!(engine.suggest.as_deref(), Some("https://kagi.com/api/autosuggest?q={searchTerms}"));
    assert_eq!(setting(&engine).engine, "custom");
}

#[test]
fn an_engine_firefox_ships_maps_to_the_built_in() {
    let (_a, current) = firefox_profile(
        r#"{"engines":[{"id":"ddg","_name":"DuckDuckGo","_isAppProvided":true}],"metaData":{"defaultEngineId":"ddg"}}"#,
    );
    let (_b, older) = firefox_profile(
        r#"{"engines":[{"_name":"Google","_isAppProvided":true}],"metaData":{"current":"Google"}}"#,
    );
    let (_c, unset) =
        firefox_profile(r#"{"engines":[{"id":"google","_name":"Google"}],"metaData":{}}"#);
    assert_eq!(
        firefox::search_engine(&current).map(|e| setting(&e).engine).as_deref(),
        Some("duckduckgo")
    );
    assert_eq!(
        firefox::search_engine(&older).map(|e| setting(&e).engine).as_deref(),
        Some("google")
    );
    assert_eq!(firefox::search_engine(&unset), None);
}

#[test]
fn safaris_search_setting_maps_to_the_built_in() {
    let duck = json!({"NSWebServicesProviderWebSearch": {"NSDefaultDisplayName": "DuckDuckGo", "NSProviderIdentifier": "com.duckduckgo"}});
    assert_eq!(
        safari::search_engine(Some(&duck)).map(|e| setting(&e).engine).as_deref(),
        Some("duckduckgo")
    );
    let ecosia =
        json!({"NSWebServicesProviderWebSearch": {"NSProviderIdentifier": "org.ecosia.www"}});
    assert_eq!(
        safari::search_engine(Some(&ecosia)).map(|e| e.search).as_deref(),
        Some("https://www.ecosia.org/search?q={searchTerms}")
    );
    assert_eq!(safari::search_engine(None), None);
    let unknown = json!({"NSWebServicesProviderWebSearch": {"NSDefaultDisplayName": "Unknown"}});
    assert_eq!(safari::search_engine(Some(&unknown)), None);
}

// MARK: FirefoxSessionReaderTests

fn urls(index: Option<&str>) -> Vec<String> {
    let field = index.map(|i| format!("\"index\":{i},")).unwrap_or_default();
    let json = format!(
        r#"{{"windows":[{{"tabs":[{{{field}"entries":[{{"url":"https://a.example/"}},{{"url":"https://b.example/"}}]}}]}}]}}"#
    );
    firefox::session(&common::moz_lz4(&json)).into_iter().map(|t| t.url).collect()
}

#[test]
fn the_index_selects_the_tabs_current_entry() {
    assert_eq!(urls(Some("2")), ["https://b.example/"]);
    assert_eq!(urls(None), ["https://b.example/"]);
}

#[test]
fn an_index_outside_the_entries_is_clamped_not_a_trap() {
    assert_eq!(urls(Some("-9223372036854775808")), ["https://a.example/"]);
    assert_eq!(urls(Some("0")), ["https://a.example/"]);
    assert_eq!(urls(Some("9223372036854775807")), ["https://b.example/"]);
}

// MARK: ImportedSearchEngineTests

fn chromium_profile(preferences: &str) -> (tempfile::TempDir, PathBuf) {
    let folder = tempfile::tempdir().unwrap();
    common::write(folder.path(), "Preferences", preferences.as_bytes());
    let path = folder.path().to_path_buf();
    (folder, path)
}

#[test]
fn a_built_in_engine_maps_to_its_id() {
    let (_keep, folder) = chromium_profile(
        r#"
        {"default_search_provider_data":{"template_url_data":{"short_name":"DuckDuckGo","keyword":"duckduckgo.com",
          "url":"https://duckduckgo.com/?q={searchTerms}&t={google:originalQueryForSuggestion}"}}}
        "#,
    );
    let engine = chromium::search_engine(&folder).expect("an engine");
    assert_eq!(engine.search, "https://duckduckgo.com/?q={searchTerms}");
    assert_eq!(setting(&engine).engine, "duckduckgo");
}

#[test]
fn an_other_engine_is_custom_with_its_addresses() {
    let (_keep, folder) = chromium_profile(
        r#"
        {"default_search_provider_data":{"template_url_data":{"short_name":"Kagi","keyword":"kagi",
          "url":"https://kagi.com/search?q={searchTerms}","suggestions_url":"https://kagi.com/api/autosuggest?q={searchTerms}"}}}
        "#,
    );
    let engine = chromium::search_engine(&folder).expect("an engine");
    let setting = setting(&engine);
    assert_eq!(setting.engine, "custom");
    assert_eq!(setting.search.as_deref(), Some("https://kagi.com/search?q={searchTerms}"));
    assert_eq!(
        setting.suggest.as_deref(),
        Some("https://kagi.com/api/autosuggest?q={searchTerms}")
    );
}

#[test]
fn the_browsers_own_default_or_an_insecure_engine_is_nothing() {
    let (_a, plain) = chromium_profile(r#"{"profile":{"name":"Work"}}"#);
    let (_b, insecure) = chromium_profile(
        r#"{"default_search_provider_data":{"template_url_data":{"url":"http://example.com/?q={searchTerms}"}}}"#,
    );
    assert_eq!(chromium::search_engine(&plain), None);
    assert_eq!(chromium::search_engine(&insecure), None);
}
