//! The session list (`_acpmux/sessions`) while other clients change sessions.
//!
//! The list is sorted newest first by `updatedAt`. Every logged event and
//! every draft write moves a session's `updatedAt`, so a sort that reads
//! that value again on each comparison sees it change half way through.
//! Rust's sort then panics ("comparison function does not correctly
//! implement a total order"), as the Chief's daemon did on 2026-10-14
//! (cmux-tui/crates/acpmux/src/hub/mod.rs `Hub::sessions`), and the request
//! task that listed the sessions never answers.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

/// Over 20 sessions: a shorter slice is insertion-sorted, which never
/// checks the order; a longer one goes through the merge that panicked
/// (`slice/sort/shared/smallsort.rs`).
const SESSIONS: usize = 40;
const WRITERS: usize = 8;
const READERS: usize = 8;
const RUN_FOR: Duration = Duration::from_secs(5);
/// A healthy list answers in milliseconds.
const LIST_ANSWER: Duration = Duration::from_secs(5);

/// One more authenticated client on `hub`, as another pane or the TUI.
async fn client(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.become_person().await;
    c
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn the_session_list_answers_while_other_clients_keep_changing_sessions() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut ids = Vec::new();
    for _ in 0..SESSIONS {
        let s =
            c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
        ids.push(s["sessionId"].as_str().unwrap().to_owned());
    }
    let stop = Arc::new(AtomicBool::new(false));
    let mut writers = Vec::new();
    for w in 0..WRITERS {
        let mut wc = client(&hub).await;
        let (ids, stop) = (ids.clone(), stop.clone());
        writers.push(tokio::spawn(async move {
            let mut n = w;
            while !stop.load(Ordering::SeqCst) {
                // Each write moves one session to the top of the list.
                let id = &ids[n % ids.len()];
                wc.request(
                    method::MUX_DRAFT_SET,
                    json!({"sessionId": id, "text": format!("d{n}")}),
                )
                .await
                .unwrap();
                n += WRITERS;
            }
        }));
    }
    let mut readers = Vec::new();
    for _ in 0..READERS {
        let mut rc = client(&hub).await;
        let stop = stop.clone();
        readers.push(tokio::spawn(async move {
            let mut lists = 0u64;
            let deadline = Instant::now() + RUN_FOR;
            while Instant::now() < deadline && !stop.load(Ordering::SeqCst) {
                rc.next += 1;
                let id = rc.next;
                rc.tx
                    .send(Message::request(id, method::MUX_SESSIONS, json!({})).to_line())
                    .await
                    .unwrap();
                let answered = tokio::time::timeout(LIST_ANSWER, async {
                    loop {
                        let line = rc.rx.recv().await.expect("connection closed");
                        if let Message::Response { id: rid, error, .. } =
                            Message::parse(&line).unwrap()
                            && rid == id
                        {
                            return error.map(|e| e.message);
                        }
                    }
                })
                .await;
                match answered {
                    Ok(None) => lists += 1,
                    Ok(Some(e)) => panic!("the session list failed: {e}"),
                    Err(_) => {
                        stop.store(true, Ordering::SeqCst);
                        panic!(
                            "the session list never answered after {lists} lists: \
                             its request task ended (a panic in the daemon's session sort)"
                        );
                    }
                }
            }
            lists
        }));
    }
    let mut total = 0;
    let mut failure = None;
    for r in readers {
        match r.await {
            Ok(n) => total += n,
            Err(e) => failure = Some(e),
        }
    }
    stop.store(true, Ordering::SeqCst);
    for w in writers {
        w.await.unwrap();
    }
    if let Some(e) = failure {
        std::panic::resume_unwind(e.into_panic());
    }
    eprintln!("{total} session lists answered while {WRITERS} clients wrote drafts");
    assert!(total > 0);
}

// A session an agent starts from inside its own chat (Leo 2026-10-13: lanes' child sessions,
// titled "Coordinator: ...", listed at the top of the New Tab Chats list) is tagged with its
// parent by the acpmux client, and the session names it, so the lists fold it under that chat.
// A tag naming no session here names no parent.
#[tokio::test]
async fn a_session_started_from_another_names_it_as_its_parent() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut ids = Vec::new();
    for _ in 0..3 {
        let s =
            c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
        ids.push(s["sessionId"].as_str().unwrap().to_owned());
    }
    let (parent, child, stray) = (&ids[0], &ids[1], &ids[2]);
    let tagged = c
        .request(method::MUX_TAG, json!({"sessionId": child, "set": {"spawnedBy": parent}}))
        .await
        .unwrap();
    assert_eq!(tagged["spawnedBy"], parent.as_str());
    let tagged = c
        .request(
            method::MUX_TAG,
            json!({"sessionId": stray, "set": {"spawnedBy": "no-such-session"}}),
        )
        .await
        .unwrap();
    assert!(tagged["spawnedBy"].is_null());

    // One level only: a parent that is itself a child names none, so two sessions tagged with
    // each other both list on their own instead of hiding each other.
    let looped = c
        .request(method::MUX_TAG, json!({"sessionId": parent, "set": {"spawnedBy": child}}))
        .await
        .unwrap();
    assert!(looped["spawnedBy"].is_null(), "{looped}");
    let summary = |sessions: &Value, id: &str| {
        sessions["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id).cloned()
    };
    let sessions = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(summary(&sessions, child).unwrap()["spawnedBy"].is_null());
    c.request(method::MUX_TAG, json!({"sessionId": parent, "remove": ["spawnedBy"]}))
        .await
        .unwrap();

    // An archived parent lists nowhere, so its children list on their own.
    c.request(method::MUX_TAG, json!({"sessionId": parent, "set": {"archived": "1"}}))
        .await
        .unwrap();
    let sessions = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(summary(&sessions, child).unwrap()["spawnedBy"].is_null());
}

// The session list (`_acpmux/sessions`, `_acpmux/watch`) in pages.
//
// A client that sends `limit` gets that many sessions and a `nextCursor`
// naming the last one; the next page starts after it. A session that moves
// to the top or is deleted between pages neither repeats nor skips another
// session. A client that sends no `limit` still gets the whole list.

const PAGED_SESSIONS: usize = 12;
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
    for _ in 0..PAGED_SESSIONS {
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
    // So is a zero limit, rather than a page of one.
    let zero = c.request(method::MUX_SESSIONS, json!({"limit": 0})).await;
    assert!(zero.is_err(), "{zero:?}");
}
