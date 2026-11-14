use super::*;
use std::collections::BTreeMap;

fn run(pairs: &[(&str, &str)]) -> Option<String> {
    let env: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    custom_headers(|k| env.get(k).cloned())
}

#[test]
fn opt_in_adds_one_line_and_replaces_an_older_one() {
    let got = run(&[
        (HEADER_ENV, "1"),
        (KEY_ENV, "optchat-a-turn"),
        (HEADERS_ENV, "X-Subrouter-Agent: claude\nx-subrouter-session: old"),
    ]);
    assert_eq!(
        got.as_deref(),
        Some("X-Subrouter-Agent: claude\nX-Subrouter-Session: optchat-a-turn")
    );
}

#[test]
fn no_opt_in_or_unsafe_key_changes_nothing() {
    assert_eq!(run(&[(KEY_ENV, "optchat-a-sub")]), None);
    assert_eq!(run(&[(HEADER_ENV, "1"), (KEY_ENV, "a b")]), None);
    assert_eq!(run(&[(HEADER_ENV, "1"), (KEY_ENV, "a\nX-Evil: 1")]), None);
    assert_eq!(run(&[(HEADER_ENV, "1")]), None);
}
