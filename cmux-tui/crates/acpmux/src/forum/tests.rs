use super::*;

fn post(id: &str, key: &str, body: &str, author: Author) -> Post {
    Post {
        id: id.into(),
        topic: RULES_TOPIC.into(),
        author,
        kind: Kind::Announce,
        key: Some(key.into()),
        body: body.into(),
        supersedes: None,
        proposes: None,
        urgent: false,
        retired: false,
        created: 1,
    }
}

fn leo() -> Author {
    Author::Person { account: "leo".into() }
}

#[test]
fn the_log_replays_rules_deliveries_and_acks() {
    let root = std::env::temp_dir().join(format!("acpmux-forum-{}", uuid::Uuid::now_v7()));
    let forum = Forum::open(&root).unwrap();
    let keep = |cur: Option<&Post>, mut p: Post| {
        p.supersedes = cur.map(|c| c.id.clone());
        p
    };
    forum.post_with(post("a", "builds", "one", leo()), keep).unwrap();
    let b = forum.post_with(post("b", "builds", "two", leo()), keep).unwrap();
    assert_eq!(b.supersedes.as_deref(), Some("a"));
    forum.mark_delivered(&["b".into()], "s1", 2).unwrap();
    forum.mark_delivered(&["b".into()], "s1", 3).unwrap();
    assert_eq!(forum.get("b").unwrap().delivered.len(), 1);
    assert!(forum.ack("b", "s1", 4).unwrap().unwrap());
    assert!(forum.ack("zz", "s1", 4).is_none());
    // A torn last line is skipped.
    let path = root.join("posts.jsonl");
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    f.write_all(b"{\"type\":\"post\",\"body\":\"\xc3").unwrap();

    let again = Forum::open(&root).unwrap();
    let rules = again.rules();
    assert_eq!(rules.len(), 1);
    assert_eq!(rules[0].post.id, "b");
    assert_eq!(rules[0].acks[0].session_id, "s1");
    assert!(!again.is_current("a"));
    assert!(again.undelivered("s1", false).is_empty());
    assert_eq!(again.undelivered("s1", true).len(), 1);
    assert_eq!(again.undelivered("s2", false).len(), 1);
    // A retired key is told only to the sessions that had one of its rules.
    let mut r = post("c", "builds", "", leo());
    r.retired = true;
    again.post_with(r, keep).unwrap();
    assert!(again.rules().is_empty());
    assert_eq!(again.undelivered("s1", false).len(), 1);
    assert!(again.undelivered("s2", false).is_empty());
    // The log stays writable after the torn line.
    let reopened = Forum::open(&root).unwrap();
    assert!(reopened.get("c").unwrap().post.retired);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0);
    }
    let _ = std::fs::remove_dir_all(root);
}
