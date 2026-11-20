//! Persistence contracts beyond the bounded displayed history.
use super::*;
use crate::forum::{Author, Post as RulePost, RULES_TOPIC};
use std::sync::atomic::Ordering;

fn input(key: &str) -> Input {
    Input {
        channel: "work".into(),
        thread: "one".into(),
        kind: Kind::Status,
        key: key.into(),
        body: format!("observation {key}"),
        source: "host-a".into(),
    }
}

#[test]
fn forum_work_retry_survives_history_eviction_and_compacted_restart() {
    let root = tempfile::tempdir().unwrap();
    let forum = Forum::open(root.path()).unwrap();
    let first = forum.work_post("coord", input("first"), Value::Null, 1).unwrap();
    for n in 0..KEEP_POSTS + 2 {
        forum.work_post("coord", input(&format!("later-{n}")), Value::Null, 2).unwrap();
    }
    assert_eq!(
        forum.work_threads("coord", Some("work"), Some("one"))["threads"][0]["posts"]
            .as_array()
            .unwrap()
            .len(),
        KEEP_POSTS
    );
    forum.compact_after.store(0, Ordering::Relaxed);
    forum.compact_work(&forum.lock());
    drop(forum);
    let forum = Forum::open(root.path()).unwrap();
    let retry = forum.work_post("coord", input("first"), Value::Null, 3).unwrap();
    assert_eq!(retry["postId"], first["postId"]);
    assert_eq!(retry["duplicate"], true);
    let mut changed = input("first");
    changed.body = "a different observation".into();
    assert!(
        forum
            .work_post("coord", changed, Value::Null, 4)
            .unwrap_err()
            .to_string()
            .contains("forum.key_conflict")
    );
    // A new source is not silently acknowledged once the post's retained history ended.
    let mut new_source = input("first");
    new_source.source = "host-b".into();
    assert!(
        forum
            .work_post("coord", new_source, Value::Null, 4)
            .unwrap_err()
            .to_string()
            .contains("forum.history_expired")
    );
    let expired = forum.work_post("coord", input("first"), Value::Null, RETRY_MS + 2).unwrap();
    assert_ne!(expired["postId"], first["postId"]);
}

#[test]
fn forum_work_snapshot_preserves_rules_marks_sources_leases_and_pending_digest() {
    let root = tempfile::tempdir().unwrap();
    let forum = Forum::open(root.path()).unwrap();
    for (id, supersedes) in [("rule-a", None), ("rule-b", Some("rule-a"))] {
        forum
            .post_with(
                RulePost {
                    id: id.into(),
                    topic: RULES_TOPIC.into(),
                    author: Author::Person { account: "leo".into() },
                    kind: crate::forum::Kind::Announce,
                    key: Some("builds".into()),
                    body: id.into(),
                    supersedes: supersedes.map(str::to_owned),
                    proposes: None,
                    urgent: false,
                    retired: false,
                    created: 1,
                },
                |_, p| p,
            )
            .unwrap();
    }
    forum.mark_delivered(&["rule-a".into(), "rule-b".into()], "coord", 2).unwrap();
    forum.ack("rule-b", "coord", 3).unwrap().unwrap();
    forum.work_post("coord", input("first"), json!({"original":true}), 1).unwrap();
    let mut other = input("first");
    other.source = "host-b".into();
    forum.work_post("coord", other, json!({"other":true}), 2).unwrap();
    let lease = forum.work_claim("coord", "work", "one", "owner", None, 300, 3).unwrap();
    let digest = forum.work_digest("coord", 4);
    forum.work_delivered("coord", digest.into_iter().map(|p| p.id).collect(), 5).unwrap();
    let later = forum.work_post("coord", input("later"), Value::Null, 6).unwrap();
    let before = forum.work_threads("coord", Some("work"), Some("one"));
    forum.compact_after.store(0, Ordering::Relaxed);
    forum.compact_work(&forum.lock());
    drop(forum);
    let forum = Forum::open(root.path()).unwrap();
    assert_eq!(forum.get("rule-a").unwrap().delivered.len(), 1);
    assert_eq!(forum.get("rule-b").unwrap().acks.len(), 1);
    assert_eq!(forum.rules()[0].post.supersedes.as_deref(), Some("rule-a"));
    assert_eq!(forum.work_threads("coord", Some("work"), Some("one")), before);
    assert_eq!(before["threads"][0]["lease"]["epoch"], lease.epoch);
    assert!(forum.work_digest("coord", DIGEST_MS).is_empty());
    assert_eq!(forum.work_digest("coord", DIGEST_MS + 5)[0].id, later["postId"].as_str().unwrap());
}

#[test]
fn forum_work_compaction_failure_does_not_reject_an_already_durable_post() {
    let root = tempfile::tempdir().unwrap();
    let forum = Forum::open(root.path()).unwrap();
    // The atomic replacement cannot create its temporary file; the append still succeeds.
    let temp =
        root.path().join("posts.jsonl").with_extension(format!("tmp-{}", std::process::id()));
    std::fs::create_dir(&temp).unwrap();
    forum.compact_after.store(0, Ordering::Relaxed);
    let stored = forum.work_post("coord", input("first"), Value::Null, 1).unwrap();
    assert_eq!(stored["stored"], true);
    assert!(
        forum.compact_after.load(Ordering::Relaxed) > forum.journal_bytes.load(Ordering::Relaxed)
    );
    drop(forum);
    let reopened = Forum::open(root.path()).unwrap();
    assert_eq!(
        reopened.work_post("coord", input("first"), Value::Null, 2).unwrap()["postId"],
        stored["postId"]
    );
}

#[test]
fn forum_work_retry_limit_refuses_without_evicting_live_receipts() {
    let forum = Forum::memory();
    for n in 0..MAX_RETRY_KEYS {
        forum.work_post("coord", input(&n.to_string()), Value::Null, 0).unwrap();
    }
    assert!(
        forum
            .work_post("coord", input("overflow"), Value::Null, 1)
            .unwrap_err()
            .to_string()
            .contains("forum.retry_limit")
    );
    assert_eq!(forum.work_post("coord", input("0"), Value::Null, 1).unwrap()["duplicate"], true);
    assert!(forum.work_post("coord", input("overflow"), Value::Null, RETRY_MS).is_ok());
}

#[test]
fn forum_work_automatic_compaction_bounds_repeated_updates() {
    let root = tempfile::tempdir().unwrap();
    let forum = Forum::open(root.path()).unwrap();
    let mut appended = 0;
    for n in 0..240 {
        let mut post = input(&n.to_string());
        post.body = "x".repeat(4096);
        forum.work_post("coord", post, Value::Null, n).unwrap();
        appended += 8192; // body plus the retained source body, excluding metadata
    }
    let bytes = std::fs::metadata(root.path().join("posts.jsonl")).unwrap().len();
    assert!(bytes < appended, "journal should have compacted: {bytes} >= {appended}");
    assert!(bytes < forum.compact_after.load(Ordering::Relaxed));
    let snapshot = std::fs::read_to_string(root.path().join("posts.jsonl")).unwrap();
    assert!(snapshot.contains("\"event\":\"snapshot\""));
    drop(forum);
    let forum = Forum::open(root.path()).unwrap();
    assert_eq!(
        forum
            .work_post(
                "coord",
                {
                    let mut p = input("0");
                    p.body = "x".repeat(4096);
                    p
                },
                Value::Null,
                241
            )
            .unwrap()["duplicate"],
        true
    );
}

#[test]
fn forum_work_failed_maintenance_eventually_refuses_new_writes_by_name() {
    let root = tempfile::tempdir().unwrap();
    let forum = Forum::open(root.path()).unwrap();
    let temp =
        root.path().join("posts.jsonl").with_extension(format!("tmp-{}", std::process::id()));
    std::fs::create_dir(&temp).unwrap();
    // Model a journal already at its bound without writing a 256 MiB test fixture.
    forum.journal_bytes.store(crate::forum::WORK_JOURNAL_LIMIT_BYTES, Ordering::Relaxed);
    let error = forum.work_post("coord", input("not-accepted"), Value::Null, 1).unwrap_err();
    assert!(error.to_string().contains("forum.journal_limit"));
    assert!(forum.work_threads("coord", None, None)["threads"].as_array().unwrap().is_empty());
}
