use super::{NewVisit, RETENTION_MS, VisitStore};

const T0: i64 = 1_800_000_000_000;

fn visit(url: &str, title: Option<&str>, tab: Option<&str>, at_ms: i64) -> NewVisit {
    NewVisit {
        url: url.to_owned(),
        title: title.map(str::to_owned),
        tab: tab.map(str::to_owned),
        at_ms,
    }
}

fn urls(store: &VisitStore) -> Vec<String> {
    store.visits("", None, 500).unwrap().into_iter().map(|visit| visit.url).collect()
}

#[test]
fn records_lists_and_updates_titles() {
    let store = VisitStore::open_in_memory().unwrap();
    store.record(&visit("https://a.example/1", None, Some("home/tab_1"), T0)).unwrap();
    store.record(&visit("https://b.example/", Some("B"), None, T0 + 10_000)).unwrap();
    assert_eq!(store.update_title("https://a.example/1", "A one").unwrap(), 1);
    let visits = store.visits("", None, 500).unwrap();
    assert_eq!(urls(&store), ["https://b.example/", "https://a.example/1"]);
    assert_eq!(visits[1].title.as_deref(), Some("A one"));
    assert_eq!(visits[1].tab.as_deref(), Some("home/tab_1"));
}

#[test]
fn title_update_touches_only_the_newest_visit() {
    let store = VisitStore::open_in_memory().unwrap();
    let old = store.record(&visit("https://a/", Some("old"), None, T0)).unwrap();
    store.record(&visit("https://a/", None, None, T0 + 1)).unwrap();
    store.update_title("https://a/", "new").unwrap();
    assert_eq!(store.visit(old).unwrap().unwrap().title.as_deref(), Some("old"));
    assert_eq!(store.visits("", None, 1).unwrap()[0].title.as_deref(), Some("new"));
}

#[test]
fn search_matches_url_and_title_tokens() {
    let store = VisitStore::open_in_memory().unwrap();
    store
        .record(&visit("https://docs.swift.org/guide", Some("The Swift Guide"), None, T0))
        .unwrap();
    store.record(&visit("https://example.com/100%", Some("Percent"), None, T0)).unwrap();
    assert_eq!(store.visits("guide swift", None, 500).unwrap().len(), 1);
    assert_eq!(store.visits("100%", None, 500).unwrap().len(), 1);
    assert!(store.visits("_", None, 500).unwrap().is_empty());
}

#[test]
fn summaries_count_visits_per_url() {
    let store = VisitStore::open_in_memory().unwrap();
    for offset in 0..3 {
        store.record(&visit("https://a/", Some(&format!("A{offset}")), None, T0 + offset)).unwrap();
    }
    store.record(&visit("https://b/", None, None, T0)).unwrap();
    let summaries = store.summaries(5_000).unwrap();
    assert_eq!(summaries[0].url, "https://a/");
    assert_eq!((summaries[0].visit_count, summaries[0].title.as_deref()), (3, Some("A2")));
    assert_eq!(summaries[0].last_visit_ms, T0 + 2);
    assert_eq!((summaries[1].url.as_str(), summaries[1].title.as_deref()), ("https://b/", None));
}

#[test]
fn removes_by_url_host_and_range() {
    let store = VisitStore::open_in_memory().unwrap();
    store.record(&visit("https://mail.example.com/x", None, None, T0)).unwrap();
    store.record(&visit("https://example.com/", None, None, T0 + 5_000)).unwrap();
    store.record(&visit("https://notexample.com/", None, None, T0 + 6_000)).unwrap();
    store.record(&visit("https://other.org/", None, None, T0 + 3_600_000)).unwrap();
    assert_eq!(store.remove_host("Example.com").unwrap(), 2);
    assert_eq!(store.remove_url("https://notexample.com/").unwrap(), 1);
    store.record(&visit("https://recent.org/", None, None, T0 + 7_200_000)).unwrap();
    assert_eq!(store.remove_since(Some(T0 + 7_000_000)).unwrap(), 1);
    assert_eq!(urls(&store), ["https://other.org/"]);
    assert_eq!(store.remove_since(None).unwrap(), 1);
    assert_eq!(store.count().unwrap(), 0);
}

#[test]
fn prune_drops_visits_past_retention_and_beyond_the_cap() {
    let store = VisitStore::open_in_memory().unwrap();
    store.record(&visit("https://old/", None, None, T0 - RETENTION_MS - 60_000)).unwrap();
    store.record(&visit("https://new/", None, None, T0)).unwrap();
    assert_eq!(store.prune(T0).unwrap(), 1);
    assert_eq!(urls(&store), ["https://new/"]);
    for n in 1..=4 {
        store.record(&visit(&format!("https://n{n}/"), None, None, T0 + n)).unwrap();
    }
    assert_eq!(store.prune_to(T0, RETENTION_MS, 2).unwrap(), 3);
    assert_eq!(urls(&store), ["https://n4/", "https://n3/"]);
}

#[test]
fn entries_use_the_profile_qualified_id_and_fall_back_to_the_url() {
    let store = VisitStore::open_in_memory().unwrap();
    let id = store.record(&visit("https://a/", Some(""), None, T0)).unwrap();
    let entries = store.entries("work", "", Some(T0), 10).unwrap();
    assert_eq!(entries[0].id, format!("page:work:{id}"));
    assert_eq!(entries[0].title, "https://a/");
    assert_eq!(entries[0].profile.as_deref(), Some("work"));
    assert!(store.entries("work", "", Some(T0 + 1), 10).unwrap().is_empty());
}
