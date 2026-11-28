//! `TabWatcher` decisions.

use crate::tab_watcher::*;

fn change(last: Option<&str>, url: Option<&str>, loading: bool, provisional: bool) -> UrlChange {
    UrlChange { last_url: last.map(Into::into), url: url.map(Into::into), loading, provisional }
}

#[test]
fn fragment_only_changes() {
    assert!(differ_only_in_fragment("https://a/p", "https://a/p#x"));
    assert!(differ_only_in_fragment("https://a/p#x", "https://a/p#y"));
    assert!(differ_only_in_fragment("https://a/p#x", "https://a/p"));
    assert!(!differ_only_in_fragment("https://a/p#x", "https://a/p#x"));
    assert!(!differ_only_in_fragment("https://a/p", "https://a/q#x"));
}

#[test]
fn a_fragment_change_is_same_document_even_while_loading() {
    let out = url_changed(&change(Some("https://a/p"), Some("https://a/p#x"), true, true));
    assert!(out.same_document);
    assert_eq!(out.last_url.as_deref(), Some("https://a/p#x"));
}

#[test]
fn a_url_change_outside_a_load_is_pushstate() {
    let moved = |loading, provisional| {
        url_changed(&change(Some("https://a/1"), Some("https://a/2"), loading, provisional))
            .same_document
    };
    assert!(moved(false, false));
    assert!(!moved(true, false));
    assert!(!moved(false, true));
}

#[test]
fn an_echo_changes_nothing_and_a_missing_url_only_updates() {
    let out = url_changed(&change(Some("https://a/"), Some("https://a/"), false, false));
    assert!(!out.same_document);
    let out = url_changed(&change(None, Some("https://a/"), false, false));
    assert!(!out.same_document);
    assert_eq!(out.last_url.as_deref(), Some("https://a/"));
    let out = url_changed(&change(Some("https://a/"), None, false, false));
    assert!(!out.same_document);
    assert_eq!(out.last_url, None);
}

#[test]
fn a_new_process_exit_crashes_the_tab() {
    assert!(process_exit_is_new(Some(&1), None));
    assert!(process_exit_is_new(Some(&2), Some(&1)));
    assert!(!process_exit_is_new(Some(&1), Some(&1)));
    assert!(!process_exit_is_new::<i32>(None, Some(&1)));
}
