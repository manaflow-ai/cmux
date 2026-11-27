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

/// A chat's agent gets its newest asks' short trace ids in its env at the start, and a file that
/// stays current as the chat gets more; a purge removes the file. Other chats' asks never show.
#[test]
fn trace_ids_reach_the_env_and_a_file_kept_current() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(DIR);
    let ledger = AskLedger::open(Some(path.clone()));
    let id = |n: u64| identity("claude", "s", &n.to_string());
    let mut env = std::collections::BTreeMap::new();
    env.insert(TRACE_IDS_ENV.to_owned(), "ask-0000000000".to_owned());
    ledger.apply_env("s", &mut env);
    assert!(env.get(TRACE_IDS_ENV).is_none(), "a chat with no asks kept a stale list");
    let file = std::path::PathBuf::from(&env[TRACE_FILE_ENV]);
    assert_eq!(file, path.join("trace").join("s"));
    assert!(!path.exists(), "naming the file made the folder");

    for n in 0..TRACE_IDS as u64 + 2 {
        ledger.record(captured(&id(n), "s", n, "t"), None);
    }
    ledger.record(captured(&identity("claude", "other", "x"), "other", 99, "t"), None);
    ledger.flush();
    let newest: Vec<String> =
        (2..TRACE_IDS as u64 + 2).rev().map(|n| short_id(&id(n)).to_owned()).collect();
    let want = newest.join(",");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), format!("{want}\n"));
    ledger.apply_env("s", &mut env);
    assert_eq!(env[TRACE_IDS_ENV], want);
    let short = regex::Regex::new(r"^ask-[0-9a-f]{10}$").unwrap();
    assert!(env[TRACE_IDS_ENV].split(',').all(|id| short.is_match(id)), "{env:?}");

    assert!(ledger.close(std::time::Duration::from_secs(5)));
    let again = AskLedger::open(Some(path.clone()));
    let mut env = std::collections::BTreeMap::new();
    again.apply_env("s", &mut env);
    assert_eq!(env[TRACE_IDS_ENV], want, "the list did not survive a restart");
    again.purge("s");
    again.flush();
    assert!(!file.exists(), "a purged chat's trace file stayed");
    again.apply_env("s", &mut env);
    assert!(env.get(TRACE_IDS_ENV).is_none());
    assert!(store::trace_path(&path, "../x").is_none());
}
