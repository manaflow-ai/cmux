//! The session list (`_acpmux/sessions`, `_acpmux/watch`) in pages.
//!
//! A client that sends `limit` gets that many sessions and a `nextCursor`
//! naming the last one; the next page starts after it. A session that moves
//! to the top or is deleted between pages neither repeats nor skips another
//! session. A client that sends no `limit` still gets the whole list.

use super::*;

const SESSIONS: usize = 12;
const PAGE: usize = 5;

fn ids(list: &Value) -> Vec<String> {
    list["sessions"]
        .as_array()
        .expect("sessions array")
        .iter()
        .map(|s| s["sessionId"].as_str().expect("sessionId").to_owned())
        .collect()
}

async fn full_list(c: &mut TestClient) -> Vec<String> {
    let r = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(r.get("nextCursor").is_none(), "no limit, no nextCursor: {r}");
    ids(&r)
}

#[tokio::test]
async fn session_list_pages_neither_repeat_nor_skip_while_sessions_move() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut created = Vec::new();
    for _ in 0..SESSIONS {
        let s =
            c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
        created.push(s["sessionId"].as_str().unwrap().to_owned());
    }
    // Let start-up status changes settle, then stamp each session in a known
    // order: a draft write sets updatedAt, and the waits keep every stamp distinct.
    tokio::time::sleep(Duration::from_millis(300)).await;
    for (n, id) in created.iter().enumerate() {
        tokio::time::sleep(Duration::from_millis(5)).await;
        c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": format!("d{n}")}))
            .await
            .unwrap();
    }
    // Newest first: the last session stamped leads.
    let before: Vec<String> = created.iter().rev().cloned().collect();
    let r = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(r.get("nextCursor").is_none(), "no limit, no nextCursor: {r}");
    assert_eq!(ids(&r), before, "the full list, newest first: {r}");
    let stamps: Vec<u64> = r["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["updatedAt"].as_u64().unwrap())
        .collect();
    assert!(stamps.windows(2).all(|w| w[0] > w[1]), "distinct updatedAt stamps: {stamps:?}");

    let first = c.request(method::MUX_SESSIONS, json!({"limit": PAGE})).await.unwrap();
    assert_eq!(ids(&first), before[..PAGE].to_vec(), "page one: {first}");
    let mut cursor = first["nextCursor"].as_str().expect("nextCursor after page one").to_owned();
    assert!(cursor.len() <= 32, "cursor {cursor:?} is at most 32 characters");

    // Between pages: a session from a later page moves to the top, and the
    // session the cursor names is deleted.
    let moved = before[PAGE + 3].clone();
    tokio::time::sleep(Duration::from_millis(5)).await;
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": moved, "text": "moves it up"}))
        .await
        .unwrap();
    let deleted = before[PAGE - 1].clone();
    c.request(method::SESSION_DELETE, json!({"sessionId": deleted})).await.unwrap();
    let now = full_list(&mut c).await;
    assert_eq!(now.first(), Some(&moved), "the edited session is newest");
    assert!(!now.contains(&deleted), "the deleted session is gone");

    let mut rest = Vec::new();
    loop {
        let page = c
            .request(method::MUX_SESSIONS, json!({"limit": PAGE, "cursor": cursor}))
            .await
            .unwrap();
        let got = ids(&page);
        assert!(got.len() <= PAGE, "{page}");
        rest.extend(got);
        match page["nextCursor"].as_str() {
            Some(next) => cursor = next.to_owned(),
            None => {
                assert!(page["nextCursor"].is_null(), "nextCursor is null when done: {page}");
                break;
            }
        }
    }
    let expected: Vec<String> = before[PAGE..].iter().filter(|id| **id != moved).cloned().collect();
    assert_eq!(rest, expected, "later pages are exactly the sessions after page one");

    // `_acpmux/watch` pages the same way and keeps returning the full list without a limit.
    let w = c.request(method::MUX_WATCH, json!({"enabled": true, "limit": PAGE})).await.unwrap();
    assert_eq!(ids(&w), now[..PAGE].to_vec(), "{w}");
    assert!(w["nextCursor"].is_string(), "{w}");
    let w = c.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    assert_eq!(ids(&w), now);
    assert!(w.get("nextCursor").is_none(), "{w}");

    // A bad cursor is an error, not a silent first page.
    let bad = c.request(method::MUX_SESSIONS, json!({"limit": PAGE, "cursor": "nope"})).await;
    assert!(bad.is_err(), "{bad:?}");
}
