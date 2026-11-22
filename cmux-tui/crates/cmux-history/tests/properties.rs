//! Property tests: the query is a sorted, limited, idempotent subset that
//! matches every token; the hidden merge is commutative and idempotent; the
//! visit store round-trips through a file.

use std::collections::BTreeSet;

use cmux_history::{
    HiddenHistory, HistoryEntry, HistoryKind, HistoryQuery, HistoryRange, NewVisit, VisitStore,
    apply, fold, search_text, tokens,
};
use proptest::prelude::*;

const NOW: i64 = 1_800_000_000_000;
const DAY_START: i64 = NOW - 8 * 3_600_000;

fn kind() -> impl Strategy<Value = HistoryKind> {
    prop::sample::select(HistoryKind::ALL.to_vec())
}

fn word() -> impl Strategy<Value = String> {
    prop::sample::select(vec![
        "swift", "Résumé", "RESUME", "api", "Ｗork", "cargo", "~", "zsh", "docs",
    ])
    .prop_map(str::to_owned)
}

fn url() -> impl Strategy<Value = Option<String>> {
    prop::option::of(prop::sample::select(vec![
        "https://forums.swift.org/t/1",
        "http://example.com/api",
        "file:///tmp/dir/",
        "file:///tmp/notes.txt",
        "cmux://history",
        "about:blank",
        "not a url",
    ]))
    .prop_map(|url| url.map(str::to_owned))
}

prop_compose! {
    fn entry()(
        kind in kind(),
        n in 0u32..40,
        at in (NOW - 40 * 86_400_000)..(NOW + 5_000),
        title in word(),
        detail in prop::option::of(word()),
        machine in prop::option::of(word()),
        url in url(),
        cwd in prop::option::of(word()),
    ) -> HistoryEntry {
        let mut entry = HistoryEntry::new(format!("{}:{n}", kind.as_str()), kind, at, title);
        entry.detail = detail;
        entry.machine = machine;
        entry.url = url;
        entry.cwd = cwd.clone();
        entry.workspace = cwd.clone();
        entry.command = cwd.clone();
        entry.provider = cwd;
        entry
    }
}

prop_compose! {
    fn query()(
        kinds in prop::collection::vec(kind(), 0..3),
        words in prop::collection::vec(word(), 0..3),
        range in prop::sample::select(vec![HistoryRange::Hour, HistoryRange::Today, HistoryRange::Week, HistoryRange::Month, HistoryRange::All]),
        limit in prop::option::of(0usize..12),
    ) -> HistoryQuery {
        HistoryQuery { kinds, text: words.join(" "), range, limit }
    }
}

fn is_directory(path: &str) -> bool {
    path.trim_end_matches('/') == "/tmp/dir"
}

proptest! {
    #[test]
    fn apply_is_a_sorted_limited_idempotent_subset(
        entries in prop::collection::vec(entry(), 0..30),
        query in query(),
    ) {
        let result = apply(&query, &entries, NOW, DAY_START, is_directory);
        for pair in result.windows(2) {
            prop_assert!((pair[0].at_ms, &pair[0].id) >= (pair[1].at_ms, &pair[1].id));
        }
        for entry in &result {
            prop_assert!(entries.contains(entry));
            prop_assert!(query.wants(entry.kind));
        }
        if let Some(limit) = query.limit {
            prop_assert!(result.len() <= limit);
        }
        let folded_tokens = tokens(&query.text);
        for entry in &result {
            let haystack = fold(&search_text(entry));
            for token in &folded_tokens {
                prop_assert!(haystack.contains(token.as_str()), "{} lacks {}", entry.id, token);
            }
        }
        prop_assert_eq!(apply(&query, &result, NOW, DAY_START, is_directory), result);
    }

    #[test]
    fn apply_without_limit_keeps_every_match(
        entries in prop::collection::vec(entry(), 0..30),
        query in query(),
    ) {
        let unlimited = HistoryQuery { limit: None, ..query.clone() };
        let all = apply(&unlimited, &entries, NOW, DAY_START, is_directory);
        let limited = apply(&query, &entries, NOW, DAY_START, is_directory);
        let expected_len = query.limit.map_or(all.len(), |limit| all.len().min(limit));
        prop_assert_eq!(limited.len(), expected_len);
        prop_assert_eq!(&all[..limited.len()], &limited[..]);
    }
}

#[derive(Debug, Clone)]
enum Hide {
    Range(Option<i64>, i64, Option<&'static str>),
    Entry(String),
}

fn hide() -> impl Strategy<Value = Hide> {
    prop_oneof![
        (
            prop::option::of(0i64..1_000),
            0i64..2_000,
            prop::option::of(prop::sample::select(vec!["agent", "command"]))
        )
            .prop_map(|(since, now, kind)| Hide::Range(since, now, kind)),
        (0u32..20).prop_map(|n| Hide::Entry(format!("m/p/{n}"))),
    ]
}

fn hidden() -> impl Strategy<Value = HiddenHistory> {
    prop::collection::vec(hide(), 0..12).prop_map(|hides| {
        let mut document = HiddenHistory::new();
        for hide in hides {
            match hide {
                Hide::Range(since, now, kind) => document.hide_range(since, now, kind),
                Hide::Entry(id) => document.hide_entry(&id),
            }
        }
        document
    })
}

fn entry_set(document: &HiddenHistory) -> BTreeSet<String> {
    document.entries().iter().cloned().collect()
}

proptest! {
    #[test]
    fn hidden_merge_is_commutative(a in hidden(), b in hidden()) {
        let ab = a.merged(&b);
        let ba = b.merged(&a);
        prop_assert_eq!(ab.ranges(), ba.ranges());
        prop_assert_eq!(entry_set(&ab), entry_set(&ba));
        for at in [-1i64, 0, 500, 1_500, 2_500] {
            for kind in [None, Some("agent"), Some("command")] {
                for n in 0..20 {
                    let id = format!("m/p/{n}");
                    prop_assert_eq!(ab.hides(&id, at, kind), ba.hides(&id, at, kind));
                }
            }
        }
    }

    #[test]
    fn hidden_merge_is_idempotent_and_keeps_every_hide(a in hidden(), b in hidden()) {
        let merged = a.merged(&b);
        prop_assert_eq!(&merged.merged(&merged), &merged);
        prop_assert_eq!(&merged.merged(&b), &merged);
        prop_assert_eq!(&merged.merged(&a), &merged);
        for document in [&a, &b] {
            for id in document.entries() {
                prop_assert!(merged.entries().contains(id));
            }
            for range in document.ranges() {
                prop_assert!(merged.ranges().contains(range));
            }
        }
    }

    #[test]
    fn hidden_survives_its_json_shape(a in hidden()) {
        let json = serde_json::to_string(&a).unwrap();
        let back: HiddenHistory = serde_json::from_str(&json).unwrap();
        prop_assert_eq!(back, a);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(16))]

    #[test]
    fn visit_store_round_trips_through_a_file(
        visits in prop::collection::vec((0u8..5, prop::option::of("[a-zA-Z é%_]{0,12}"), 0i64..1_000_000), 1..20),
    ) {
        let dir = std::env::temp_dir().join(format!("cmux-history-prop-{}-{}", std::process::id(), unique()));
        let path = dir.join("profile.sqlite");
        let mut expected = Vec::new();
        {
            let store = VisitStore::open(&path).unwrap();
            for (host, title, at_ms) in &visits {
                let visit = NewVisit { url: format!("https://h{host}.example/"), title: title.clone(), tab: None, at_ms: NOW - at_ms };
                let id = store.record(&visit).unwrap();
                expected.push((id, visit));
            }
        }
        let reopened = VisitStore::open(&path).unwrap();
        let stored = reopened.visits("", None, 1_000).unwrap();
        prop_assert_eq!(stored.len(), expected.len());
        for pair in stored.windows(2) {
            prop_assert!((pair[0].at_ms, pair[0].id) > (pair[1].at_ms, pair[1].id));
        }
        for (id, visit) in &expected {
            let found = reopened.visit(*id).unwrap().unwrap();
            prop_assert_eq!(&found.url, &visit.url);
            prop_assert_eq!(&found.title, &visit.title);
            prop_assert_eq!(found.at_ms, visit.at_ms);
        }
        drop(reopened);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

fn unique() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}
