//! The router alone (`interest.rs`): who an event reaches, in what order, and how an inbox lags.

use super::*;
use crate::store::EventRecord;
use serde_json::json;
use std::sync::Arc;

fn event(session: &str, dir: &str, kind: &str) -> HubEvent {
    HubEvent {
        session_id: session.to_owned(),
        record: Arc::new(EventRecord {
            seq: 0,
            at: 0,
            dir: dir.into(),
            kind: kind.into(),
            msg: json!({}),
            host_seq: None,
        }),
        remote: None,
        update_line: Default::default(),
        row: Default::default(),
        list_seq: 0,
        peer_batch: false,
    }
}

fn send(router: &Router, ev: HubEvent) {
    router.send(ev, |_| ());
}

fn drain(inbox: &Inbox) -> Vec<String> {
    let mut seen = Vec::new();
    loop {
        match inbox.try_recv() {
            Ok(ev) => seen.push(format!("{}:{}", ev.session_id, ev.record.kind)),
            Err(TryRecvError::Lagged(n)) => seen.push(format!("lagged:{n}")),
            Err(_) => return seen,
        }
    }
}

#[test]
fn an_event_reaches_only_the_inboxes_that_want_it() {
    let router = Router::new(64);
    let (idle, pane, watcher, chats) =
        (router.inbox(), router.inbox(), router.inbox(), router.inbox());
    router.attach(&pane, "a");
    router.set_watching(&watcher, true);
    router.hear_activity(&chats);
    send(&router, event("a", "in", "agent_message_chunk"));
    send(&router, event("b", "in", "agent_message_chunk"));
    send(&router, event("b", "mux", "titled"));
    send(&router, event("b", "mux", "status"));
    assert!(drain(&idle).is_empty(), "a connection that asked for nothing is never woken");
    assert_eq!(drain(&pane), ["a:agent_message_chunk"]);
    assert_eq!(drain(&watcher), ["b:titled", "b:status"]);
    assert_eq!(drain(&chats), ["b:status"]);
    assert_eq!(idle.routed(), 0);
}

#[test]
fn a_connection_named_twice_gets_an_event_once_in_order() {
    let router = Router::new(64);
    let both = router.inbox();
    router.attach(&both, "a");
    router.set_watching(&both, true);
    router.hear_activity(&both);
    for kind in ["status", "agent_message_chunk", "titled", "turn_end"] {
        send(&router, event("a", if kind == "agent_message_chunk" { "in" } else { "mux" }, kind));
    }
    assert_eq!(drain(&both), ["a:status", "a:agent_message_chunk", "a:titled", "a:turn_end"]);
}

#[test]
fn a_full_inbox_drops_its_oldest_and_says_how_many_once() {
    let router = Router::new(3);
    let pane = router.inbox();
    router.attach(&pane, "a");
    for n in 0..5 {
        send(&router, event("a", "mux", &format!("k{n}")));
    }
    assert_eq!(drain(&pane), ["lagged:2", "a:k2", "a:k3", "a:k4"]);
    // Events it does not want never fill it.
    for _ in 0..10 {
        send(&router, event("b", "mux", "titled"));
    }
    assert!(drain(&pane).is_empty());
}

#[test]
fn detach_pause_and_close_stop_the_routing() {
    let router = Router::new(64);
    let pane = router.inbox();
    router.attach(&pane, "a");
    router.set_watching(&pane, true);
    router.detach(&pane, "a");
    router.set_watching(&pane, false);
    send(&router, event("a", "mux", "titled"));
    assert!(drain(&pane).is_empty());
    router.attach(&pane, "a");
    router.forget(&pane);
    send(&router, event("a", "mux", "titled"));
    assert_eq!(pane.try_recv().err(), Some(TryRecvError::Closed));
    assert_eq!(router.inboxes(), 0);
}

#[tokio::test]
async fn recv_waits_for_the_next_routed_event() {
    let router = Arc::new(Router::new(64));
    let pane = router.inbox();
    router.attach(&pane, "a");
    let reader = {
        let pane = pane.clone();
        tokio::spawn(async move { pane.recv().await.map(|ev| ev.record.kind.clone()) })
    };
    tokio::task::yield_now().await;
    send(&router, event("b", "mux", "titled"));
    send(&router, event("a", "mux", "renamed"));
    assert_eq!(reader.await.unwrap().ok().as_deref(), Some("renamed"));
}
