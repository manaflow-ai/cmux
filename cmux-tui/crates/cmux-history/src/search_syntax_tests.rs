use super::*;

const NOW: i64 = 1_763_500_000_000; // 2025-11-18T21:06:40Z
const DAY_START: i64 = 1_763_424_000_000; // 2025-11-18T00:00:00Z

fn kind(name: &str) -> Option<&'static str> {
    ["chat", "command"].into_iter().find(|kind| *kind == name)
}

fn parse(text: &str) -> SearchFilter<&'static str> {
    SearchFilter::parse(text, NOW, DAY_START, kind)
}

#[test]
fn plain_words_fold_and_all_must_match() {
    let filter = parse("Café  Build");
    assert_eq!(filter.words, vec!["Café", "Build"]);
    assert!(filter.matches("the build at the CAFÉ"));
    assert!(!filter.matches("the cafe"));
}

#[test]
fn kinds_known_to_the_surface_filter_and_unknown_stay_words() {
    let filter = parse("is:Chat kind:command is:page deploy");
    assert_eq!(filter.kinds, vec!["chat", "command"]);
    assert_eq!(filter.words, vec!["is:page", "deploy"]);
    assert!(filter.wants(&"chat") && !filter.wants(&"tab"));
    assert!(parse("deploy").wants(&"tab"));
}

#[test]
fn ages_today_yesterday_and_dates_bound_the_time() {
    assert_eq!(parse("since:7d").after_ms, Some(NOW - 7 * DAY_MS));
    assert_eq!(parse("after:2h").after_ms, Some(NOW - 2 * HOUR_MS));
    assert_eq!(parse("after:30m").after_ms, Some(NOW - 30 * MINUTE_MS));
    assert_eq!(parse("since:today").after_ms, Some(DAY_START));
    assert_eq!(parse("before:yesterday").before_ms, Some(DAY_START - DAY_MS));
    assert_eq!(parse("after:2025-11-18").after_ms, Some(DAY_START));
    assert_eq!(parse("before:1970-01-02").before_ms, Some(DAY_MS));
    let window = parse("since:2w before:1w");
    assert!(window.covers(NOW - 10 * DAY_MS));
    assert!(!window.covers(NOW - 3 * DAY_MS));
    assert!(!window.covers(NOW - 20 * DAY_MS));
}

#[test]
fn dates_follow_the_local_zone() {
    // Local midnight of 2025-11-18 in UTC-8 is 08:00Z.
    let pacific = DAY_START + 8 * HOUR_MS;
    let filter = SearchFilter::parse("after:2025-11-17", NOW, pacific, kind);
    assert_eq!(filter.after_ms, Some(pacific - DAY_MS));
    // UTC+9: the local day began at 15:00Z the day before.
    let tokyo = DAY_START - 9 * HOUR_MS;
    let filter = SearchFilter::parse("before:2025-11-18", NOW, tokyo, kind);
    assert_eq!(filter.before_ms, Some(tokyo));
    // UTC+13 (New Zealand summer) and UTC-10 (Hawaii), the ends
    // of the zones a date reads exactly.
    for offset_h in [12, 13, -10] {
        let start = DAY_START - offset_h * HOUR_MS;
        let filter = SearchFilter::parse("after:2025-11-18", NOW, start, kind);
        assert_eq!(filter.after_ms, Some(start), "UTC{offset_h:+}");
    }
}

#[test]
fn impossible_dates_stay_words() {
    assert_eq!(parse("after:2025-02-29").after_ms, None);
    assert_eq!(parse("after:2025-04-31").after_ms, None);
    assert!(parse("after:2024-02-29").after_ms.is_some());
}

#[test]
fn values_that_are_not_times_stay_words() {
    let filter = parse("before:lunch since:7x after:2025-13-01 https://example.com");
    assert_eq!(filter.after_ms, None);
    assert_eq!(filter.before_ms, None);
    assert_eq!(
        filter.words,
        vec!["before:lunch", "since:7x", "after:2025-13-01", "https://example.com"]
    );
}

#[test]
fn exclusions_and_phrases() {
    let filter = parse("deploy -staging -\"dry run\" \"cargo test\"");
    assert_eq!(filter.words, vec!["deploy", "cargo test"]);
    assert_eq!(filter.excluded, vec!["staging", "dry run"]);
    assert!(filter.matches("deploy prod; cargo test"));
    assert!(!filter.matches("deploy staging; cargo test"));
    assert!(!filter.matches("deploy prod; cargo  test"));
    assert!(!filter.matches("deploy prod dry run cargo test"));
    // A lone dash and a quoted flag are words.
    assert_eq!(parse("a - b").words, vec!["a", "-", "b"]);
    assert_eq!(parse("rm \"-rf\"").words, vec!["rm", "-rf"]);
    // An unclosed quote runs to the end.
    assert_eq!(parse("\"half open").words, vec!["half open"]);
}

#[test]
fn operators_alone_match_every_text() {
    let filter = parse("is:chat since:1d");
    assert!(filter.words.is_empty() && filter.excluded.is_empty());
    assert!(filter.matches("anything"));
}
