use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::{
    Build, Feed, area_groups, find, parse_index, parse_notes, pr_number, previous, select,
    whats_in_human, whats_in_json, which_human, which_json,
};
use crate::localization::NightlyMessages;

fn messages() -> &'static NightlyMessages {
    &crate::localization::catalog().app_control.nightly
}

fn key_pair() -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap()
}

fn encode(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn index_json() -> Value {
    json!({ "version": 1, "builds": [
        { "build": "300", "shortVersion": "1.0.0-nightly.300", "date": "2026-11-26", "head": "cccccccc11", "highlights": 1 },
        { "build": "200", "shortVersion": "1.0.0-nightly.200", "date": "2026-11-25", "head": "bbbbbbbb11", "highlights": 0 },
        { "build": "100", "shortVersion": "1.0.0-nightly.100", "date": "2026-11-24", "head": "aaaaaaaa11", "highlights": 0 },
    ]})
}

fn notes_json(build: &str, items: Value) -> Value {
    json!({ "build": build, "builtAt": format!("2026-11-2{}T10:00:00Z", &build[..1]), "date": "2026-11-25",
            "head": "deadbeef99", "items": items })
}

fn builds() -> Vec<Build> {
    parse_index(index_json().to_string().as_bytes()).unwrap()
}

#[test]
fn the_index_lists_builds_newest_first() {
    let builds = builds();
    assert_eq!(builds.len(), 3);
    assert_eq!(builds[0].build, "300");
    assert_eq!(builds[0].short_version, "1.0.0-nightly.300");
    assert_eq!(builds[2].date, "2026-11-24");
    assert_eq!(builds[1].head, "bbbbbbbb11");
    assert!(parse_index(b"{\"builds\": 3}").is_err());
    assert!(parse_index(b"not json").is_err());
}

#[test]
fn notes_items_keep_pr_author_area_and_internal() {
    let notes = parse_notes(
        notes_json(
            "300",
            json!([
                { "title": "Faster tabs", "author": "Leo", "pr": 57008, "area": "Terminal" },
                { "title": "ci: retry", "author": "Lawrence", "pr": 57010, "internal": true },
                { "title": "chore: autofix", "author": "github-actions[bot]" },
            ]),
        )
        .to_string()
        .as_bytes(),
    )
    .unwrap();
    assert_eq!(notes.built_at.as_deref(), Some("2026-11-23T10:00:00Z"));
    assert_eq!(notes.items.len(), 3);
    assert_eq!(notes.items[0].pr, Some(57008));
    assert_eq!(notes.items[0].area.as_deref(), Some("Terminal"));
    assert!(!notes.items[0].internal);
    assert!(notes.items[1].internal);
    assert_eq!(notes.items[2].pr, None);
    assert!(notes.contains(57010));
    assert!(!notes.contains(1));
}

#[test]
fn a_pr_is_a_number_a_hash_number_or_a_pull_url() {
    assert_eq!(pr_number("57008"), Some(57008));
    assert_eq!(pr_number("#57008"), Some(57008));
    assert_eq!(pr_number("https://github.com/manaflow-ai/cmux/pull/57008"), Some(57008));
    assert_eq!(pr_number("https://github.com/manaflow-ai/cmux/pull/57008/files"), Some(57008));
    assert_eq!(pr_number("github.com/manaflow-ai/cmux/pull/57008#discussion"), Some(57008));
    assert_eq!(pr_number("abc"), None);
    assert_eq!(pr_number("#"), None);
    assert_eq!(pr_number("0"), None);
    assert_eq!(pr_number("https://github.com/manaflow-ai/cmux/issues/57008"), None);
}

#[test]
fn select_picks_the_newest_or_a_named_build_and_previous_is_the_next_older() {
    let builds = builds();
    assert_eq!(select(&builds, None).map(|build| build.build.as_str()), Some("300"));
    assert_eq!(select(&builds, Some("200")).map(|build| build.build.as_str()), Some("200"));
    assert!(select(&builds, Some("7")).is_none());
    assert_eq!(previous(&builds, "300").map(|build| build.build.as_str()), Some("200"));
    assert!(previous(&builds, "100").is_none());
}

#[test]
fn items_group_by_area_with_other_last() {
    let notes = parse_notes(
        notes_json(
            "300",
            json!([
                { "title": "b", "author": "x", "pr": 2 },
                { "title": "a", "author": "x", "pr": 1, "area": "Terminal" },
                { "title": "c", "author": "x", "pr": 3, "area": "Agents" },
                { "title": "d", "author": "x", "pr": 4, "area": "" },
                { "title": "e", "author": "x", "pr": 5, "area": "Terminal" },
            ]),
        )
        .to_string()
        .as_bytes(),
    )
    .unwrap();
    let groups = area_groups(&notes.items, messages().whats_in_other);
    let names: Vec<&str> = groups.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(names, ["Agents", "Terminal", messages().whats_in_other]);
    let terminal: Vec<Option<u64>> = groups[1].1.iter().map(|item| item.pr).collect();
    assert_eq!(terminal, [Some(1), Some(5)]);
    assert_eq!(groups[2].1.len(), 2);
}

#[test]
fn whats_in_prints_one_line_per_pr_with_its_url() {
    let builds = builds();
    let notes = parse_notes(
        notes_json(
            "300",
            json!([
                { "title": "Faster tabs", "author": "Leo", "pr": 57008, "area": "Terminal" },
                { "title": "ci: retry", "author": "Lawrence", "pr": 57010, "internal": true },
                { "title": "chore: autofix", "author": "github-actions[bot]" },
            ]),
        )
        .to_string()
        .as_bytes(),
    )
    .unwrap();
    let text = whats_in_human(&builds[0], &notes, previous(&builds, "300"), messages());
    assert!(text.lines().next().unwrap().contains("300"), "{text}");
    assert!(text.lines().next().unwrap().contains("200"), "{text}");
    assert!(text.contains("#57008 Faster tabs (Leo)"), "{text}");
    assert!(text.contains("https://github.com/manaflow-ai/cmux/pull/57008"), "{text}");
    assert!(text.contains("#57010 ci: retry (Lawrence)"), "{text}");
    assert!(text.contains("chore: autofix (github-actions[bot])"), "{text}");
    assert!(text.find("Terminal").unwrap() < text.find(messages().whats_in_other).unwrap());

    let value = whats_in_json(&builds[0], &notes, previous(&builds, "300"));
    assert_eq!(value["build"], "300");
    assert_eq!(value["date"], "2026-11-26");
    assert_eq!(value["head"], "cccccccc11");
    assert_eq!(value["since"], "200");
    assert_eq!(value["items"][0]["pr"], 57008);
    assert_eq!(value["items"][0]["area"], "Terminal");
    assert_eq!(value["items"][0]["url"], "https://github.com/manaflow-ai/cmux/pull/57008");
    assert_eq!(value["items"][1]["internal"], true);
    assert_eq!(value["items"][1]["area"], Value::Null);
    assert_eq!(value["items"][2]["pr"], Value::Null);
    assert_eq!(value["items"][2]["url"], Value::Null);
    assert_eq!(whats_in_json(&builds[2], &notes, None)["since"], Value::Null);
}

#[test]
fn which_says_the_build_or_plainly_that_it_is_not_there() {
    let builds = builds();
    let notes = parse_notes(notes_json("200", json!([])).to_string().as_bytes()).unwrap();
    let line = which_human(57008, Some((&builds[1], &notes)), &builds, messages());
    assert!(
        line.contains("#57008") && line.contains("200") && line.contains("2026-11-25"),
        "{line}"
    );
    let value = which_json(57008, Some((&builds[1], &notes)));
    assert_eq!(value["pr"], 57008);
    assert_eq!(value["build"], "200");
    assert_eq!(value["date"], "2026-11-25");
    assert_eq!(value["head"], "bbbbbbbb11");
    assert_eq!(value["built_at"], "2026-11-22T10:00:00Z");
    let missing = which_human(57008, None, &builds, messages());
    assert!(missing.contains("#57008") && missing.contains('3'), "{missing}");
    assert_eq!(which_json(57008, None)["build"], Value::Null);
}

/// A fixture feed on disk, signed with the test key: index 300/200/100, 200 has no notes.
fn fixture(dir: &std::path::Path, tamper: bool) {
    let pair = key_pair();
    let write = |name: &str, value: &Value| {
        let bytes = value.to_string().into_bytes();
        std::fs::write(dir.join(name), &bytes).unwrap();
        let signed: &[u8] = if tamper && name == "300.json" { b"{}" } else { &bytes };
        std::fs::write(dir.join(format!("{name}.sig")), encode(pair.sign(signed).as_ref()))
            .unwrap();
    };
    write("index.json", &index_json());
    write("100.json", &notes_json("100", json!([{ "title": "old", "author": "a", "pr": 10 }])));
    write(
        "300.json",
        &notes_json(
            "300",
            json!([{ "title": "new", "author": "a", "pr": 30 }, { "title": "again", "author": "a", "pr": 10 }]),
        ),
    );
}

fn feed(dir: &std::path::Path) -> Feed {
    Feed::dir(dir.to_path_buf(), encode(key_pair().public_key().as_ref()))
}

fn block_on<F: Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(future)
}

#[test]
fn which_finds_the_oldest_build_that_carried_the_pr_and_skips_builds_without_notes() {
    let dir = tempfile::tempdir().unwrap();
    fixture(dir.path(), false);
    let feed = feed(dir.path());
    let builds = block_on(feed.index()).unwrap();
    assert_eq!(builds.len(), 3);
    let hit = block_on(find(&feed, &builds, 10)).unwrap().unwrap();
    assert_eq!(hit.0.build, "100");
    let hit = block_on(find(&feed, &builds, 30)).unwrap().unwrap();
    assert_eq!(hit.0.build, "300");
    assert!(block_on(find(&feed, &builds, 99)).unwrap().is_none());
    assert!(block_on(feed.notes("200")).unwrap().is_none());
    assert_eq!(block_on(feed.notes("300")).unwrap().unwrap().items.len(), 2);
}

#[test]
fn a_feed_whose_signature_does_not_verify_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    fixture(dir.path(), true);
    let feed = feed(dir.path());
    assert!(block_on(feed.index()).is_ok());
    let error = block_on(feed.notes("300")).unwrap_err();
    assert!(error.contains("signature"), "{error}");
    let stranger = Ed25519KeyPair::from_seed_unchecked(&[9u8; 32]).unwrap();
    let other_key = Feed::dir(dir.path().to_path_buf(), encode(stranger.public_key().as_ref()));
    assert!(block_on(other_key.index()).is_err());
}
