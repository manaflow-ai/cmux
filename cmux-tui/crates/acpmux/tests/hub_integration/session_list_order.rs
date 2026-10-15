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
