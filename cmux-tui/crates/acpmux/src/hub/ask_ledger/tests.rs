use super::*;

fn captured(id: &str, sid: &str, ts: u64, text: &str) -> Line {
    Line::Event {
        ask: id.into(),
        sid: sid.into(),
        ts,
        by: "leo@test".into(),
        kind: Kind::Captured { row: json!({"id": id, "sessionId": sid, "text": text}) },
    }
}

fn event(id: &str, sid: &str, ts: u64, by: &str, kind: Kind) -> Line {
    Line::Event { ask: id.into(), sid: sid.into(), ts, by: by.into(), kind }
}

fn file(dir: &std::path::Path) -> String {
    std::fs::read_to_string(dir.join(store::FILE)).unwrap_or_default()
}

#[test]
fn ask_ledger_is_bounded_deduplicated_and_forgets_purged_chats() {
    let ledger = AskLedger::default();
    assert_eq!(ledger.page()["entries"], json!([]));
    for n in 0..LIMIT + 10 {
        assert!(ledger.record(captured(&n.to_string(), "s", n as u64, "t"), None));
    }
    assert!(!ledger.record(captured(&(LIMIT + 9).to_string(), "s", 0, "again"), None));
    let page = ledger.page();
    let rows = page["entries"].as_array().unwrap();
    assert_eq!(rows.len(), LIMIT);
    assert_eq!(rows[0]["id"], (LIMIT + 9).to_string());
    assert_eq!(rows[0]["text"], "t", "a repeated capture replaced the first");
    assert_eq!(rows[LIMIT - 1]["id"], "10");
    let gone = AtomicBool::new(true);
    assert!(!ledger.record(captured("late", "s2", 0, "t"), Some(&gone)));
    ledger.purge("s");
    assert_eq!(ledger.page()["entries"], json!([]));
}

/// Status and owner are folded from events, never stored: "ask to owner" is a query. An event on
/// an ask the ledger never captured adds nothing.
#[test]
fn status_and_owner_are_folded_from_events() {
    let ledger = AskLedger::default();
    ledger.record(captured("a", "s", 1_000, "ship it"), None);
    let row = |l: &AskLedger| l.page()["entries"][0].clone();
    assert_eq!(row(&ledger)["status"], "open");
    assert!(row(&ledger).get("owner").is_none());

    ledger
        .record(event("a", "s", 6_000, "rfd-idle", Kind::Routed { to: "host/lane".into() }), None);
    assert_eq!(row(&ledger)["status"], "routed");
    assert_eq!(row(&ledger)["owner"], "host/lane");
    assert_eq!(row(&ledger)["ownedAfterMs"], 5_000);

    let pr = || ("manaflow-ai/cmux".to_string(), 7);
    let (repo, number) = pr();
    ledger.record(event("a", "s", 7_000, "host/lane", Kind::PrOpened { repo, number }), None);
    assert_eq!(row(&ledger)["status"], "inProgress");
    let (repo, number) = pr();
    ledger.record(event("a", "s", 8_000, "github", Kind::PrMerged { repo, number }), None);
    assert_eq!(row(&ledger)["status"], "landed");
    assert_eq!(row(&ledger)["events"].as_array().unwrap().len(), 3);
    assert_eq!(row(&ledger)["events"][2]["kind"], "prMerged");
    assert_eq!(row(&ledger)["events"][2]["number"], 7);

    ledger.record(event("a", "s", 9_000, "leo@test", Kind::Reopened), None);
    assert_eq!(row(&ledger)["status"], "open");
    assert!(row(&ledger).get("owner").is_none(), "a reopened ask kept its old owner");
    ledger.record(event("a", "s", 9_500, "other/lane", Kind::Picked), None);
    assert_eq!(row(&ledger)["owner"], "other/lane");
    assert_eq!(row(&ledger)["ownedAfterMs"], 8_500);
    let reason = "superseded".to_string();
    ledger.record(event("a", "s", 9_900, "leo@test", Kind::Dropped { reason }), None);
    assert_eq!(row(&ledger)["status"], "dropped");

    assert!(!ledger.record(event("never", "s", 1, "x", Kind::Answered), None));
    assert_eq!(ledger.page()["entries"].as_array().unwrap().len(), 1);
}

/// The events outlive the daemon: a second ledger on the same folder folds the same asks, and a
/// line torn by a crash is cut so the next append starts its own line.
#[test]
fn events_survive_a_restart_and_a_torn_tail_is_cut() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(DIR);
    {
        let ledger = AskLedger::open(Some(path.clone()));
        assert!(!path.exists(), "an unused ledger made its folder");
        ledger.record(captured("a", "s", 1, "first"), None);
        ledger
            .record(event("a", "s", 2, "host/lane", Kind::Routed { to: "host/lane".into() }), None);
        ledger.record(captured("b", "s", 3, "second"), None);
        assert!(ledger.close(std::time::Duration::from_secs(5)));
        ledger.record(captured("c", "s", 4, "after close"), None);
    }
    let text = file(&path);
    assert_eq!(text.lines().count(), 3, "{text}");
    assert!(!text.contains("after close"), "an event after close reached the file");
    std::fs::write(path.join(store::FILE), format!("{text}{{\"t\":\"event\",\"ask\":")).unwrap();

    let again = AskLedger::open(Some(path.clone()));
    let page = again.page();
    let rows = page["entries"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["id"], "b");
    assert_eq!(rows[1]["status"], "routed");
    assert_eq!(rows[1]["owner"], "host/lane");
    assert_eq!(file(&path), text, "the torn tail was not cut");
    again.record(captured("d", "s", 5, "third"), None);
    again.flush();
    assert_eq!(file(&path).lines().count(), 4);
    assert_eq!(AskLedger::open(Some(path)).page()["entries"].as_array().unwrap().len(), 3);
}

/// A purge takes the chat's words off the disk, not only out of the view; a purge line left by a
/// crash before the rewrite is rewritten at the next start.
#[test]
fn a_purge_rewrites_the_file_without_the_chats_words() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(DIR);
    let ledger = AskLedger::open(Some(path.clone()));
    ledger.record(captured("a", "gone", 1, "secret words"), None);
    ledger.record(captured("b", "kept", 2, "kept words"), None);
    ledger.flush();
    assert!(file(&path).contains("secret words"));
    ledger.purge("gone");
    ledger.flush();
    let text = file(&path);
    assert!(!text.contains("secret words"), "{text}");
    assert!(text.contains("kept words"));
    assert!(ledger.close(std::time::Duration::from_secs(5)));

    let purge = serde_json::to_string(&Line::Purge { sid: "kept".into() }).unwrap();
    std::fs::write(path.join(store::FILE), format!("{text}{purge}\n")).unwrap();
    let again = AskLedger::open(Some(path.clone()));
    again.flush();
    assert_eq!(again.page()["entries"], json!([]));
    assert_eq!(file(&path), "", "the folded purge left the chat's words on disk");
}

#[test]
fn ask_ledger_identity_is_stable_and_tuple_boundaries_matter() {
    assert_eq!(identity("claude", "a", "b"), identity("claude", "a", "b"));
    assert_ne!(identity("claude", "a", "bc"), identity("claude", "ab", "c"));
    assert_ne!(identity("claude", "a", "b"), identity("codex", "a", "b"));
}

/// Leo's ledger size (6,490 asks, RFD 0010), each with a routing and a merge event: the start
/// folds it once, linearly, and a read stays the newest page whatever the history. Bounded loosely
/// so a quadratic fold fails on any machine; the times print for the PR's measurement.
#[test]
fn six_thousand_asks_fold_once_and_read_in_constant_pages() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(DIR);
    let words = "x".repeat(600);
    let ledger = AskLedger::open(Some(path.clone()));
    for n in 0..6_490u64 {
        let (id, sid) = (format!("ask-{n}"), format!("s{}", n % 300));
        ledger.record(captured(&id, &sid, n, &words), None);
        ledger
            .record(event(&id, &sid, n + 1, "rfd-idle", Kind::Routed { to: "lane".into() }), None);
        let merged = Kind::PrMerged { repo: "r".into(), number: n };
        ledger.record(event(&id, &sid, n + 2, "github", merged), None);
    }
    assert!(ledger.close(std::time::Duration::from_secs(30)));
    let bytes = std::fs::metadata(path.join(store::FILE)).unwrap().len();
    let start = std::time::Instant::now();
    let again = AskLedger::open(Some(path));
    let fold = start.elapsed();
    let start = std::time::Instant::now();
    let page = again.page();
    let read = start.elapsed();
    assert_eq!(page["entries"].as_array().unwrap().len(), LIMIT);
    assert_eq!(page["entries"][0]["status"], "landed");
    eprintln!("ask ledger: 6490 asks, {bytes} bytes, fold {fold:?}, newest page {read:?}");
    assert!(fold < std::time::Duration::from_secs(5), "fold took {fold:?}");
    assert!(read < std::time::Duration::from_millis(500), "a page took {read:?}");
}

fn related_ids(ledger: &AskLedger, text: &str, sid: Option<&str>) -> Vec<String> {
    ledger.related(text, sid, None)["matches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["ask"]["id"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn ask_ledger_matcher_finds_a_reworded_repeat_and_ignores_unrelated_asks() {
    let ledger = AskLedger::default();
    ledger.record(
        captured("a", "s1", 1, "make the sidebar collapse when the window is narrow"),
        None,
    );
    ledger.record(captured("b", "s1", 2, "rename the billing page title to Plans"), None);
    ledger.record(captured("c", "s2", 3, "upgrade the tokio dependency everywhere"), None);
    let ids = related_ids(&ledger, "the sidebar should collapse on a narrow window", None);
    assert_eq!(ids.first().map(String::as_str), Some("a"), "{ids:?}");
    assert!(!ids.contains(&"c".to_string()), "unrelated ask above the floor: {ids:?}");
    let reply = ledger.related("the sidebar should collapse on a narrow window", None, None);
    let top = &reply["matches"][0];
    for part in ["score", "cosine", "structure", "keyword"] {
        assert!(top[part].is_number(), "{part} missing: {top}");
    }
    assert_eq!(top["ask"]["status"], "open", "the match carries the ask's folded row");
    assert!(related_ids(&ledger, "zzqx wvvk", None).is_empty(), "nonsense matched");
}

#[test]
fn ask_ledger_matcher_keeps_keyword_hits_for_rare_identifiers() {
    let ledger = AskLedger::default();
    ledger.record(captured("pr", "s1", 1, "why is #60862 still not merged"), None);
    ledger.record(captured("prose", "s1", 2, "why is the merge still not done for that PR"), None);
    let ids = related_ids(&ledger, "you forgot 60862", None);
    assert_eq!(ids.first().map(String::as_str), Some("pr"), "{ids:?}");
    let file = AskLedger::default();
    file.record(captured("f", "s1", 1, "the bug in hub/ask_ledger/store.rs"), None);
    file.record(captured("g", "s1", 2, "a bug in the hub store"), None);
    let ids = related_ids(&file, "store.rs again", None);
    assert_eq!(ids.first().map(String::as_str), Some("f"), "{ids:?}");
}

#[test]
fn ask_ledger_matcher_prefers_the_same_session_and_skips_the_ask_itself() {
    let ledger = AskLedger::default();
    let now = crate::store::now_ms();
    ledger.record(captured("other", "s2", now, "add a dark theme toggle"), None);
    ledger.record(captured("mine", "s1", now, "add a dark theme toggle"), None);
    let ids = related_ids(&ledger, "add a dark theme toggle", Some("s1"));
    assert_eq!(ids, ["mine", "other"]);
    let reply = ledger.related("add a dark theme toggle", Some("s1"), Some("mine"));
    assert_eq!(reply["matches"].as_array().unwrap().len(), 1);
    assert_eq!(reply["matches"][0]["ask"]["id"], "other");
    // Newer wins a tie on words.
    let ages = AskLedger::default();
    ages.record(captured("old", "s", 0, "add a dark theme toggle"), None);
    ages.record(captured("new", "s", now, "add a dark theme toggle"), None);
    assert_eq!(related_ids(&ages, "add a dark theme toggle", None), ["new", "old"]);
}

#[test]
fn ask_ledger_matcher_returns_at_most_top_and_survives_a_restart_and_a_purge() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = AskLedger::open(Some(dir.path().into()));
    for n in 0..10 {
        ledger.record(captured(&format!("x{n}"), "s", n, "fix the flaky login test"), None);
    }
    assert_eq!(related_ids(&ledger, "fix the flaky login test", None).len(), matcher::TOP);
    ledger.flush();
    ledger.close(std::time::Duration::from_secs(5));
    let again = AskLedger::open(Some(dir.path().into()));
    assert_eq!(
        related_ids(&again, "flaky login test", None).len(),
        matcher::TOP,
        "index not refolded"
    );
    again.purge("s");
    assert!(related_ids(&again, "fix the flaky login test", None).is_empty());
}

#[test]
fn ask_ledger_matcher_stays_fast_over_seven_thousand_asks() {
    let ledger = AskLedger::default();
    let words = ["sidebar", "billing", "theme", "login", "merge", "daemon", "chat", "browser"];
    for n in 0..7_000u64 {
        let text = format!(
            "ask {n}: change the {} and the {} near {}",
            words[(n % 8) as usize],
            words[(n / 8 % 8) as usize],
            n * 7
        );
        ledger.record(captured(&format!("n{n}"), "s", n, &text), None);
    }
    let start = std::time::Instant::now();
    let ids = related_ids(&ledger, "change the daemon and the chat near 35", None);
    let took = start.elapsed();
    assert!(!ids.is_empty());
    // The RFD measured 10 ms per query over 6,647 records brute force; debug builds are slower.
    assert!(took < std::time::Duration::from_millis(500), "one query took {took:?}");
}
