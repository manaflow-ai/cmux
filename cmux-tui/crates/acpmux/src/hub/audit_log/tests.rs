use super::*;

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acpmux-audit-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn entry(session: &str, at: u64) -> Value {
    json!({"at": at, "sessionId": session, "harness": "claude", "vendor": "anthropic",
               "kind": "approval", "permissionId": format!("p-{at}"), "ask": "Run: ls",
               "decision": {"optionId": "allow", "kind": "allow"},
               "answeredBy": {"person": true}})
}

#[test]
fn entries_chain_and_verify() {
    let log = AuditLog::open(None);
    for at in 1..=3 {
        log.record(entry("s1", at));
    }
    let all = log.all().unwrap();
    assert_eq!(all.len(), 3);
    assert_eq!(all[0]["prevHash"], GENESIS);
    assert_eq!(all[1]["prevHash"], all[0]["hash"]);
    assert_eq!(all[2]["seq"], 3);
    assert_eq!(all[2]["v"], VERSION);
    assert_eq!(verify(&all), json!({"ok": true, "entries": 3}));
}

#[test]
fn verify_names_the_first_broken_link() {
    let log = AuditLog::open(None);
    for at in 1..=4 {
        log.record(entry("s1", at));
    }
    let mut all = log.all().unwrap();
    all[1]["ask"] = json!("Run: rm -rf /");
    let v = verify(&all);
    assert_eq!(v["ok"], false, "{v}");
    assert_eq!(v["brokenAt"], 2, "{v}");
    assert_eq!(v["reason"], "hash", "{v}");
    let mut dropped = log.all().unwrap();
    dropped.remove(2);
    let v = verify(&dropped);
    assert_eq!((v["brokenAt"].clone(), v["reason"].clone()), (json!(4), json!("seq")), "{v}");
}

#[test]
fn the_hash_ignores_key_order() {
    let a = json!({"b": 1, "a": {"y": 2, "x": [3, {"q": 1, "p": 2}]}});
    let b = json!({"a": {"x": [3, {"p": 2, "q": 1}], "y": 2}, "b": 1});
    assert_eq!(entry_hash(GENESIS, &a), entry_hash(GENESIS, &b));
    assert_ne!(entry_hash(GENESIS, &a), entry_hash("1", &a));
}

#[test]
fn a_restart_continues_the_chain_and_appends_only() {
    let d = dir("restart");
    {
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s1", 1));
        log.record(json!({"at": 2, "sessionId": "s1", "kind": "review",
                              "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                              "decision": {"kind": "accept"}, "answeredBy": {"person": true}}));
        log.flush();
    }
    let before = std::fs::read_to_string(d.join(FILE)).unwrap();
    let log = AuditLog::open(Some(d.clone()));
    log.record(entry("s2", 3));
    let all = log.all().unwrap();
    assert_eq!(all.len(), 3);
    assert_eq!(all[2]["seq"], 3);
    assert_eq!(all[2]["prevHash"], all[1]["hash"]);
    assert_eq!(verify(&all)["ok"], true);
    // The verdict a log read back still keeps its pull request out of the queue.
    assert!(log.reviewed("s1", "https://github.com/o/r/pull/1"));
    // Keyed by session: the same URL another session printed still waits for its verdict.
    assert!(!log.reviewed("s2", "https://github.com/o/r/pull/1"));
    let after = std::fs::read_to_string(d.join(FILE)).unwrap();
    assert!(after.starts_with(&before), "the file was rewritten");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(d.join(FILE)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_page_filters_and_continues_from_its_cursor() {
    let log = AuditLog::open(None);
    for at in 1..=5 {
        log.record(entry(if at % 2 == 0 { "even" } else { "odd" }, at * 10));
    }
    let q = Query { limit: 2, ..Default::default() };
    let first = log.page(&q).unwrap();
    assert_eq!(first["entries"].as_array().unwrap().len(), 2);
    assert_eq!(first["next"], 2);
    let second = log.page(&Query { cursor: Some(2), ..q.clone() }).unwrap();
    assert_eq!(second["entries"][0]["seq"], 3);
    let odd = log
        .page(&Query {
            session_id: Some("odd".into()),
            since: Some(20),
            limit: 10,
            verify: true,
            ..Default::default()
        })
        .unwrap();
    let seqs: Vec<_> =
        odd["entries"].as_array().unwrap().iter().map(|e| e["seq"].clone()).collect();
    assert_eq!(seqs, vec![json!(3), json!(5)]);
    assert_eq!(odd.get("next"), None);
    assert_eq!(odd["verify"]["ok"], true);
    assert!(Query::from_params(&json!({"since": "x"})).is_err());
    assert_eq!(odd["writeErrors"], 0);
}

#[test]
fn an_entry_that_cannot_be_written_fails_its_verdict_and_is_counted() {
    // The audit folder's path is a file: no line can be written under it.
    let d = dir("unwritable");
    std::fs::write(&d, b"not a folder").unwrap();
    let log = AuditLog::open(Some(d.clone()));
    let verdict = json!({"at": 1, "sessionId": "s1", "kind": "review",
                             "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                             "decision": {"kind": "accept"}, "answeredBy": {"person": true}});
    assert!(log.record_durable(verdict).is_err());
    assert!(!log.reviewed("s1", "https://github.com/o/r/pull/1"));
    log.record(entry("s1", 2));
    log.flush();
    assert_eq!(log.write_errors(), 2);
    let _ = std::fs::remove_file(&d);
}

#[tokio::test]
async fn a_purge_leaves_nothing_of_the_session_and_a_chain_that_verifies() {
    let d = dir("purge");
    let url = "https://github.com/o/r/pull/4";
    {
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("keep", 1));
        let mut secret = entry("gone-incognito", 2);
        secret["ask"] = json!("Run: cat private-plans.txt");
        log.record(secret);
        log.record_durable(json!({"at": 3, "sessionId": "gone-incognito", "kind": "review",
                                      "prUrl": url, "ask": "Review", "decision": {"kind": "accept"},
                                      "answeredBy": {"person": true}}))
            .unwrap();
        log.record(entry("keep", 4));
        assert_eq!(log.purge("gone-incognito").unwrap().await.unwrap(), Ok(2));
        assert!(!log.reviewed("gone-incognito", url));
        // The chain goes on from the rewritten head.
        log.record(entry("keep", 5));
        log.flush();
    }
    let text = std::fs::read_to_string(d.join(FILE)).unwrap();
    for needle in ["gone-incognito", "private-plans", url] {
        assert!(!text.contains(needle), "{needle} survived the purge");
    }
    // After a restart: nothing of it, and the chain verifies.
    let log = AuditLog::open(Some(d.clone()));
    let all = log.all().unwrap();
    assert_eq!(all.len(), 3);
    assert_eq!(all[2]["seq"], 3);
    assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
    let page = log
        .page(&Query { session_id: Some("gone-incognito".into()), limit: 10, ..Default::default() })
        .unwrap();
    assert_eq!(page["entries"], json!([]));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(d.join(FILE)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn an_entry_sent_after_the_purge_is_refused_by_the_writer() {
    let d = dir("fence");
    let log = AuditLog::open(Some(d.clone()));
    log.record(entry("gone", 1));
    // A verdict that passed the hub's check before the purge, sent after it.
    let purge = log.purge("gone").unwrap();
    let late = log.record_durable(json!({"at": 2, "sessionId": "gone", "kind": "review",
                                             "prUrl": "https://github.com/o/r/pull/5",
                                             "ask": "Review", "decision": {"kind": "accept"},
                                             "answeredBy": {"person": true}}));
    assert_eq!(purge.await.unwrap(), Ok(1));
    assert!(late.is_err());
    log.record(entry("gone", 3));
    log.record(entry("kept", 4));
    let all = log.all().unwrap();
    let sessions: Vec<_> = all.iter().map(|e| e["sessionId"].clone()).collect();
    assert_eq!(sessions, vec![json!("kept")]);
    assert_eq!(log.write_errors(), 0, "a refused entry of a purged chat is no write error");
    let _ = std::fs::remove_dir_all(&d);
}

/// The fence lasts until a chat takes the purged id again, not until a restart: a chat
/// recreated under it (a trigger's fixed id) has its answers logged. What the purged chat
/// sent before the new one was created is still refused.
#[tokio::test]
async fn a_chat_recreated_under_a_purged_id_is_logged_again() {
    let d = dir("reopen");
    let log = AuditLog::open(Some(d.clone()));
    log.record(entry("same", 1));
    assert_eq!(log.purge("same").unwrap().await.unwrap(), Ok(1));
    log.record(entry("same", 2));
    // The purged chat's verdict, built before the purge and sent after the new chat took
    // the id: its own flag says it is the old chat's, so the lifted fence does not admit it.
    let old_chat = Arc::new(AtomicBool::new(true));
    log.reopen("same");
    let late = log.record_durable_of(
        json!({"at": 2, "sessionId": "same", "kind": "review",
                   "prUrl": "https://github.com/o/r/pull/5", "ask": "Review",
                   "decision": {"kind": "accept"}, "answeredBy": {"person": true}}),
        Some(old_chat),
    );
    assert!(late.is_err(), "{late:?}");
    assert!(!log.reviewed("same", "https://github.com/o/r/pull/5"));
    log.record_of(entry("same", 3), Some(Arc::new(AtomicBool::new(false))));
    let written = log.record_durable(json!({"at": 4, "sessionId": "same", "kind": "review",
                                                "prUrl": "https://github.com/o/r/pull/6",
                                                "ask": "Review", "decision": {"kind": "accept"},
                                                "answeredBy": {"person": true}}));
    assert!(written.is_ok(), "{written:?}");
    let all = log.all().unwrap();
    let ats: Vec<_> = all.iter().map(|e| e["at"].clone()).collect();
    assert_eq!(ats, vec![json!(3), json!(4)]);
    assert!(log.reviewed("same", "https://github.com/o/r/pull/6"));
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_torn_tail_is_cut_at_open_and_the_chain_goes_on() {
    let d = dir("torn");
    {
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s1", 1));
        log.record(entry("s1", 2));
        log.flush();
    }
    let path = d.join(FILE);
    let whole = std::fs::read(&path).unwrap();
    let mut torn = whole.clone();
    torn.extend_from_slice(br#"{"at":3,"sessionId":"s1","ask":"half"#);
    std::fs::write(&path, &torn).unwrap();
    let log = AuditLog::open(Some(d.clone()));
    assert_eq!(std::fs::read(&path).unwrap(), whole, "the torn tail was cut");
    log.record(entry("s1", 4));
    let all = log.all().unwrap();
    assert_eq!(all.len(), 3);
    assert_eq!(all[2]["seq"], 3, "no sequence number repeats");
    assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_purge_drops_lines_that_are_not_entries() {
    let d = dir("purge-malformed");
    {
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("gone", 1));
        log.record(entry("kept", 2));
        log.flush();
    }
    let path = d.join(FILE);
    let mut text = std::fs::read_to_string(&path).unwrap();
    text.push_str("not json: gone private-plans\n");
    std::fs::write(&path, text).unwrap();
    let log = AuditLog::open(Some(d.clone()));
    assert_eq!(log.purge("gone").unwrap().await.unwrap(), Ok(1));
    let after = std::fs::read_to_string(&path).unwrap();
    assert!(!after.contains("private-plans"));
    assert_eq!(verify(&log.all().unwrap())["ok"], true);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn close_writes_what_was_sent_before_it_returns() {
    let d = dir("close");
    let log = AuditLog::open(Some(d.clone()));
    for at in 1..=50 {
        log.record(entry("s1", at));
    }
    assert!(log.close(Duration::from_secs(10)));
    let lines = std::fs::read_to_string(d.join(FILE)).unwrap().lines().count();
    assert_eq!(lines, 50);
    assert_eq!(log.write_errors(), 0);
    log.record(entry("s1", 51));
    assert_eq!(log.write_errors(), 1, "a record after close is counted, not lost silently");
    assert!(log.close(Duration::from_secs(1)));
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn open_knows_the_written_verdicts_before_it_returns() {
    let d = dir("ready");
    let url = "https://github.com/o/r/pull/3";
    AuditLog::open(Some(d.clone()))
        .record_durable(json!({"at": 1, "sessionId": "s1", "kind": "review", "prUrl": url,
                                   "ask": "Review", "decision": {"kind": "accept"},
                                   "answeredBy": {"person": true}}))
        .unwrap();
    // No flush or wait: the first read after open already knows the verdict.
    assert!(AuditLog::open(Some(d.clone())).reviewed("s1", url));
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(unix)]
#[test]
fn a_planted_link_is_refused_and_what_it_names_is_untouched() {
    let d = dir("link");
    std::fs::create_dir_all(&d).unwrap();
    let target = d.join("elsewhere");
    std::fs::write(&target, b"{\"secret\":1}\n").unwrap();
    std::os::unix::fs::symlink(&target, d.join(FILE)).unwrap();
    let log = AuditLog::open(Some(d.clone()));
    assert!(log.all().is_err(), "a linked log is not read");
    let verdict = json!({"at": 1, "sessionId": "s1", "kind": "review",
                             "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                             "decision": {"kind": "accept"}, "answeredBy": {"person": true}});
    assert!(log.record_durable(verdict).is_err(), "nothing is written through the link");
    assert_eq!(std::fs::read(&target).unwrap(), b"{\"secret\":1}\n");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(unix)]
#[tokio::test]
async fn a_purge_replaces_a_planted_tmp_link_without_writing_through_it() {
    let d = dir("tmplink");
    let log = AuditLog::open(Some(d.clone()));
    log.record(entry("s1", 1));
    log.record(entry("s2", 2));
    log.flush();
    let target = d.join("elsewhere");
    std::fs::write(&target, b"keep").unwrap();
    std::os::unix::fs::symlink(&target, d.join(FILE).with_extension("jsonl.tmp")).unwrap();
    assert_eq!(log.purge("s1").unwrap().await.unwrap(), Ok(1));
    assert_eq!(std::fs::read(&target).unwrap(), b"keep");
    let meta = std::fs::symlink_metadata(d.join(FILE)).unwrap();
    assert!(meta.file_type().is_file());
    assert_eq!(log.all().unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(unix)]
#[test]
fn a_linked_audit_folder_is_refused_and_its_target_left_alone() {
    let d = dir("dirlink");
    let target = d.join("elsewhere");
    std::fs::create_dir_all(&target).unwrap();
    // A torn tail in the folder the link names: a repair through the link would cut it.
    std::fs::write(target.join(FILE), b"{\"seq\":1}\ntorn").unwrap();
    let linked = d.join("audit");
    std::os::unix::fs::symlink(&target, &linked).unwrap();
    let log = AuditLog::open(Some(linked.clone()));
    assert!(log.all().is_err(), "a linked folder is not read");
    log.record(entry("s1", 1));
    log.flush();
    assert_eq!(log.write_errors(), 1, "nothing is written through the link");
    assert_eq!(std::fs::read(target.join(FILE)).unwrap(), b"{\"seq\":1}\ntorn");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_failed_purge_unfences_the_session_and_keeps_its_entries() {
    let d = dir("failpurge");
    let log = AuditLog::open(Some(d.clone()));
    log.record(entry("s1", 1));
    log.flush();
    log.fail_purges(true);
    assert!(log.purge_within("s1", Duration::from_secs(5)).await.is_err());
    log.record(entry("s1", 2));
    let all = log.all().unwrap();
    assert_eq!(all.len(), 2, "the chat's entries stay and it still records: {all:?}");
    assert_eq!(verify(&all)["ok"], true);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_durable_record_given_up_on_is_never_written() {
    let d = dir("cancel");
    let log = AuditLog::open(Some(d.clone()));
    let (done, rx) = mpsc::channel();
    let state = Arc::new(AtomicU8::new(CANCELLED));
    log.send(Msg::Entry(entry("s1", 1), Some(Durable { done, state }), None)).unwrap();
    log.record(entry("s1", 2));
    log.flush();
    assert!(rx.try_recv().is_err(), "a withdrawn entry gets no answer");
    let all = log.all().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0]["at"], 2);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_durable_record_answers_with_the_entry_as_written() {
    let d = dir("durable");
    let log = AuditLog::open(Some(d.clone()));
    let written = log
        .record_durable(json!({"at": 1, "sessionId": "s1", "kind": "review",
                                   "prUrl": "https://github.com/o/r/pull/2", "ask": "Review",
                                   "decision": {"kind": "changes"},
                                   "answeredBy": {"person": true}}))
        .unwrap();
    assert_eq!(written["seq"], 1);
    assert_eq!(written["prevHash"], GENESIS);
    assert!(log.reviewed("s1", "https://github.com/o/r/pull/2"));
    let on_disk = std::fs::read_to_string(d.join(FILE)).unwrap();
    assert!(on_disk.contains(written["hash"].as_str().unwrap()));
    assert_eq!(log.write_errors(), 0);
    let _ = std::fs::remove_dir_all(&d);
}
