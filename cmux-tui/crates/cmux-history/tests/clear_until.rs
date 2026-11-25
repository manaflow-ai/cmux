//! A history clear that waited in the app's queue carries its click time
//! (`until_ms`): visits after it stay (cmux#38186).

use cmux_history::{NewVisit, VisitStore};

fn visit(url: &str, at_ms: i64) -> NewVisit {
    NewVisit { url: url.to_owned(), title: None, tab: None, at_ms }
}

#[test]
fn a_clear_until_its_click_time_keeps_the_visits_after_it() {
    let store = VisitStore::open_in_memory().unwrap();
    for (url, at_ms) in
        [("https://before/", 1_000), ("https://in/", 2_000), ("https://after/", 3_000)]
    {
        store.record(&visit(url, at_ms)).unwrap();
    }
    assert_eq!(store.remove_between(Some(1_500), 2_500, "backup-a").unwrap(), 1);
    let left: Vec<String> =
        store.visits("", None, 10).unwrap().into_iter().map(|v| v.url).collect();
    assert_eq!(left, vec!["https://after/".to_owned(), "https://before/".to_owned()]);
    // No start: everything up to the click time.
    assert_eq!(store.remove_between(None, 2_500, "backup-b").unwrap(), 1);
    assert_eq!(store.count().unwrap(), 1);
}
