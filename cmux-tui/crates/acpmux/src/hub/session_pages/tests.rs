use super::*;

fn json_bytes(value: &Value) -> usize {
    value.to_string().len()
}

fn name(row: &Value) -> String {
    format!("{}{}", session_id(row), peer(row).map_or(String::new(), |p| format!("@{p}")))
}

/// Every page `budget` cuts, read from the first, with `between` run
/// on the rows (and the names read so far) after each page.
fn read_pages(
    rows: &mut Vec<Value>,
    budget: usize,
    mut between: impl FnMut(&mut Vec<Value>, &[String]),
) -> Vec<String> {
    let (mut read, mut cursor) = (Vec::new(), None::<String>);
    loop {
        let (page, next) = byte_page(
            rows,
            cursor.as_deref(),
            budget,
            |at| json!({"name": name(&rows[at])}),
            json_bytes,
        )
        .unwrap();
        assert!(!page.is_empty());
        read.extend(page.iter().map(|row| row["name"].as_str().unwrap().to_owned()));
        assert!(read.len() <= rows.len() + 2, "{read:?}");
        match next {
            Some(next) => cursor = Some(next),
            None => return read,
        }
        between(rows, &read);
    }
}

fn sorted(mut names: Vec<String>) -> Vec<String> {
    names.sort();
    names
}

/// A chat here, its copies on two peers and a row listed twice: at every budget each
/// comes once.
#[test]
fn byte_pages_read_each_row_once() {
    let rows = vec![
        json!({"sessionId": "z", "updatedAt": 1}),
        json!({"sessionId": "dup", "updatedAt": 5, "peer": "p2"}),
        json!({"sessionId": "a", "updatedAt": 9}),
        json!({"sessionId": "dup", "updatedAt": 5}),
        json!({"sessionId": "dup", "updatedAt": 5, "peer": "p1"}),
        json!({"sessionId": "a", "updatedAt": 9}),
    ];
    for budget in [1, 40, 80, 120, 10_000] {
        let read = read_pages(&mut rows.clone(), budget, |_, _| {});
        assert_eq!(sorted(read), ["a", "dup", "dup@p1", "dup@p2", "z"], "budget {budget}");
    }
    let bad = |cursor| byte_page(&rows, Some(cursor), 1, |_| json!({}), json_bytes).is_err();
    assert!(bad("k5.0011") && bad("h") && bad("h12") && bad(&format!("h{}", "g".repeat(32))));
}

/// Between pages an unread session becomes the newest, and a read one and an unread one
/// leave: no row is skipped or repeated.
#[test]
fn byte_pages_hold_their_place_while_sessions_update_and_leave() {
    let mut rows: Vec<Value> = ["a", "b", "c", "d", "e", "f"]
        .iter()
        .enumerate()
        .map(|(i, id)| json!({"sessionId": id, "updatedAt": 10 - i}))
        .collect();
    let mut gone = None;
    let read = read_pages(&mut rows, 1, |rows, read| {
        let unread: Vec<String> = rows.iter().map(name).filter(|n| !read.contains(n)).collect();
        match read.len() {
            1 => rows.iter_mut().filter(|r| name(r) == unread[0]).for_each(|r| {
                r["updatedAt"] = json!(100);
            }),
            2 => {
                gone = Some(unread[0].clone());
                rows.retain(|r| name(r) != unread[0] && name(r) != read[0]);
            }
            _ => {}
        }
        sort_session_summaries(rows);
    });
    let mut all: Vec<String> =
        ["a", "b", "c", "d", "e", "f"].map(String::from).into_iter().collect();
    all.retain(|n| Some(n) != gone.as_ref());
    assert_eq!(sorted(read), all);
}

/// The cursor is 33 bytes however long the ids are.
#[test]
fn a_byte_page_cursor_stays_small_for_a_huge_id() {
    let rows = vec![
        json!({"sessionId": "x".repeat(1 << 20), "peer": "p".repeat(1 << 20)}),
        json!({"sessionId": "y".repeat(1 << 20)}),
    ];
    let (page, next) = byte_page(&rows, None, 1, |at| json!({"at": at}), json_bytes).unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(next.unwrap().len(), 33);
}

#[test]
fn stable_scan_keeps_an_unread_chief_when_it_updates_and_cursor_row_leaves() {
    let mut rows = vec![
        json!({"sessionId": "a", "updatedAt": 3, "status": "idle"}),
        json!({"sessionId": "b", "updatedAt": 2, "status": "running", "name": "optchat-home"}),
        json!({"sessionId": "c", "updatedAt": 1, "status": "idle"}),
    ];
    let mut params = json!({"localOnly": true, "excludeStatus": ["closed"],
            "orderBy": "sessionId", "limit": 1});
    let first = session_list_reply(rows.clone(), &params).unwrap();
    assert_eq!(ids(&first), ["a"]);
    params["cursor"] = first["nextCursor"].clone();
    rows.remove(0);
    rows[0]["updatedAt"] = json!(100);
    sort_session_summaries(&mut rows);
    let second = session_list_reply(rows.clone(), &params).unwrap();
    assert_eq!(ids(&second), ["b"]);
    params["cursor"] = second["nextCursor"].clone();
    let last = session_list_reply(rows, &params).unwrap();
    assert_eq!(ids(&last), ["c"]);
    assert!(last["nextCursor"].is_null());
    assert!(refuse_watch_filters(&json!({"orderBy": "sessionId"})).is_err());
    assert!(session_list_reply(list(), &json!({"orderBy": "sessionId"})).is_err());
}

fn list() -> Vec<Value> {
    let mut list = vec![
        json!({"sessionId": "a", "updatedAt": 5, "peer": "huge-blue", "status": "closed"}),
        json!({"sessionId": "b", "updatedAt": 4, "peer": "huge-blue", "status": "idle"}),
        json!({"sessionId": "c", "updatedAt": 3, "peer": "huge-blue", "status": "closed"}),
        json!({"sessionId": "d", "updatedAt": 2, "peer": "cmux16", "status": "closed"}),
        json!({"sessionId": "e", "updatedAt": 1, "status": "closed"}),
    ];
    sort_session_summaries(&mut list);
    list
}

fn ids(reply: &Value) -> Vec<&str> {
    reply["sessions"].as_array().unwrap().iter().map(session_id).collect()
}

#[test]
fn peer_and_status_narrow_the_list_before_it_is_paged() {
    let reply =
        session_list_reply(list(), &json!({"peer": "huge-blue", "status": "closed", "limit": 1}))
            .unwrap();
    assert_eq!(ids(&reply), ["a"]);
    let next = reply["nextCursor"].as_str().unwrap().to_owned();
    let reply = session_list_reply(
        list(),
        &json!({"peer": "huge-blue", "status": "closed", "limit": 1, "cursor": next}),
    )
    .unwrap();
    assert_eq!(ids(&reply), ["c"]);
    assert_eq!(reply["nextCursor"], Value::Null);
}

#[test]
fn each_filter_alone_and_none_keeps_the_old_reply() {
    assert_eq!(ids(&session_list_reply(list(), &json!({"peer": "cmux16"})).unwrap()), ["d"]);
    assert_eq!(
        ids(&session_list_reply(list(), &json!({"status": "closed"})).unwrap()),
        ["a", "c", "d", "e"]
    );
    assert_eq!(
        ids(&session_list_reply(list(), &json!({"peer": null})).unwrap()),
        ["a", "b", "c", "d", "e"]
    );
    assert_eq!(
        ids(&session_list_reply(
            vec![
                json!({"sessionId": "local", "updatedAt": 9, "status": "idle"}),
                json!({"sessionId": "remote", "updatedAt": 8, "peer": "b", "status": "idle"}),
                json!({"sessionId": "old", "updatedAt": 7, "status": "closed"}),
            ],
            &json!({"localOnly": true, "excludeStatus": ["closed"]}),
        )
        .unwrap()),
        ["local"]
    );
}

#[test]
fn an_empty_filter_is_none_and_a_non_string_one_is_refused() {
    assert_eq!(ids(&session_list_reply(list(), &json!({"peer": ""})).unwrap()).len(), 5);
    assert!(session_list_reply(list(), &json!({"status": 3})).is_err());
    assert!(session_list_reply(list(), &json!({"localOnly": "yes"})).is_err());
    assert!(session_list_reply(list(), &json!({"excludeStatus": [3]})).is_err());
}

#[test]
fn a_watch_refuses_filters_its_events_would_not_keep() {
    assert!(refuse_watch_filters(&json!({"peer": "huge-blue"})).is_err());
    assert!(refuse_watch_filters(&json!({"status": "closed", "limit": 5})).is_err());
    assert!(refuse_watch_filters(&json!({"limit": 5, "peer": null, "status": ""})).is_ok());
    assert!(refuse_watch_filters(&json!({"localOnly": true})).is_err());
    assert!(refuse_watch_filters(&json!({"excludeStatus": ["closed"]})).is_err());
}
