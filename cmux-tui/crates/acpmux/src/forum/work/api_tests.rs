use super::*;

fn input(key: &str, source: &str, body: String) -> Input {
    Input {
        channel: "ops/runner-capacity".into(),
        thread: "label".into(),
        kind: Kind::Warn,
        key: key.into(),
        source: source.into(),
        body,
    }
}

#[test]
fn forum_api_list_projects_only_authenticated_author_metadata() {
    let author = json!({
        "kind": "agent",
        "sessionId": "session-uuid",
        "handle": "Mango",
        "name": "runner-check"
    });
    let projected = super::source_author(&json!({
        "transport": {"author": author},
        "body": "private source body",
        "secret": "must not appear"
    }))
    .unwrap();
    assert_eq!(projected["kind"], "agent");
    assert_eq!(projected["sessionId"], "session-uuid");
    assert_eq!(projected["handle"], "Mango");
    assert_eq!(projected["name"], "runner-check");
    assert!(projected.get("body").is_none());
    assert!(projected.get("secret").is_none());
    let oversized = json!({"transport": {"author": {
        "kind": "agent", "sessionId": "session-uuid", "handle": "Mango", "name": "z".repeat(8192)
    }}});
    let projected = super::source_author(&oversized).unwrap();
    assert_eq!(projected["handle"], "Mango");
    assert!(projected.get("name").is_none());
}

#[test]
fn forum_api_detail_pages_reconstruct_all_hosts_and_older_posts() {
    let forum = Forum::memory();
    let mut expected = BTreeMap::new();
    let mut ids = Vec::new();
    for n in 0..3 {
        for host in 0..24 {
            let source = format!("host-{host:03}");
            let body = format!("{n}/{host}:{}", "b".repeat(8000));
            let provenance = json!({"evidence":"p".repeat(12000), "host":host});
            let receipt = forum
                .work_post(
                    "coord",
                    input(&format!("queued/{n}"), &source, body.clone()),
                    provenance.clone(),
                    n,
                )
                .unwrap();
            let id = receipt["postId"].as_str().unwrap().to_owned();
            if host == 0 {
                ids.push(id.clone());
            }
            expected.insert((id, source), json!({"body":body, "transport":provenance}));
        }
    }
    let mut cursor = None;
    let mut actual = BTreeMap::new();
    let mut order = Vec::new();
    let mut pages = 0;
    loop {
        let page = forum
            .work_threads_page(
                "coord",
                Some("ops/runner-capacity"),
                Some("label"),
                cursor.as_deref(),
            )
            .unwrap();
        assert!(serde_json::to_vec(&page).unwrap().len() <= MAX_WORK_PAGE_BYTES);
        for row in page["threads"].as_array().unwrap() {
            for post in row["posts"].as_array().unwrap() {
                let id = post["id"].as_str().unwrap().to_owned();
                if order.last() != Some(&id) {
                    order.push(id.clone());
                }
                assert_eq!(post["fragment"], true);
                assert_eq!(post["sourceCount"], 24);
                for (source, provenance) in post["sources"].as_object().unwrap() {
                    assert!(
                        actual.insert((id.clone(), source.clone()), provenance.clone()).is_none()
                    );
                }
            }
        }
        pages += 1;
        cursor = page["nextCursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            break;
        }
        assert!(pages < 100);
    }
    assert!(pages > 1);
    assert_eq!(actual, expected);
    ids.reverse();
    assert_eq!(order, ids);
}

#[test]
fn forum_api_list_is_bounded_and_does_not_expose_source_bodies() {
    let forum = Forum::memory();
    for n in 0..600 {
        let mut p = input("queued/one", "host", "é".repeat(1000));
        p.thread = format!("label-{n:04}");
        forum.work_post("coord", p, json!({"secret":"not-a-summary"}), n).unwrap();
    }
    let mut cursor = None;
    let mut count = 0;
    let mut pages = 0;
    loop {
        let page = forum.work_threads_page("coord", None, None, cursor.as_deref()).unwrap();
        let encoded = serde_json::to_vec(&page).unwrap();
        assert!(encoded.len() <= MAX_WORK_PAGE_BYTES);
        assert!(!String::from_utf8(encoded).unwrap().contains("not-a-summary"));
        for row in page["threads"].as_array().unwrap() {
            assert!(row["latest"]["body"].as_str().unwrap().len() <= 512);
            assert_eq!(row["latest"]["sourceCount"], 1);
            assert!(row["latest"]["sources"]["host"].is_null());
            count += 1;
        }
        pages += 1;
        cursor = page["nextCursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            break;
        }
        assert!(pages < 100);
    }
    assert!(pages > 1);
    assert_eq!(count, 600);
}

#[test]
fn forum_api_refuses_bad_stale_and_mismatched_cursors_and_large_provenance() {
    let forum = Forum::memory();
    assert!(
        forum
            .work_threads_page("coord", None, None, Some("oops"))
            .unwrap_err()
            .to_string()
            .contains("forum.bad_cursor")
    );
    assert!(forum.work_threads_page("coord", None, None, Some(&"x".repeat(2049))).is_err());
    let cursor = serde_json::to_string(&PageCursor {
        recipient: "coord".into(),
        channel: None,
        thread: None,
        next_channel: "missing".into(),
        next_thread: "missing".into(),
        post_id: None,
        source: None,
    })
    .unwrap();
    assert!(
        forum
            .work_threads_page("coord", None, None, Some(&cursor))
            .unwrap_err()
            .to_string()
            .contains("forum.stale_cursor")
    );
    assert!(
        forum
            .work_threads_page("other", None, None, Some(&cursor))
            .unwrap_err()
            .to_string()
            .contains("forum.bad_cursor")
    );
    let err = forum
        .work_post(
            "coord",
            input("queued/one", "host", "body".into()),
            json!("x".repeat(MAX_PROVENANCE_BYTES)),
            0,
        )
        .unwrap_err();
    assert!(err.to_string().contains("forum.provenance_too_large"));
    assert!(
        forum.work_threads_page("coord", None, None, None).unwrap()["threads"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}
