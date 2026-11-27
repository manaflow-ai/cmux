//! `Order`: one chat's notices on their own shard, a notice about the whole peer after the rest.

use super::*;
use serde_json::json;

fn changed(session: &str) -> PeerNotice {
    PeerNotice::SessionChanged {
        session: json!({"sessionId": session}),
        kind: "status".into(),
        seq: 1,
    }
}

#[test]
fn a_chats_notices_name_it_and_a_peers_state_names_none() {
    assert_eq!(notice_session(&changed("a")), Some("a"));
    let update = PeerNotice::Notification {
        method: "session/update".into(),
        params: json!({"sessionId": "b"}),
        link: 1,
    };
    assert_eq!(notice_session(&update), Some("b"));
    let lagged =
        PeerNotice::Notification { method: "_acpmux/lagged".into(), params: json!({}), link: 1 };
    assert_eq!(notice_session(&lagged), None);
    assert_eq!(notice_session(&PeerNotice::Connected), None);
    assert_eq!(notice_session(&PeerNotice::Sessions(Vec::new())), None);
}

#[test]
fn one_peers_chats_spread_over_the_shards() {
    let shards: HashSet<usize> = (0..200).map(|i| session_shard("h00", &format!("s{i}"))).collect();
    assert!(shards.len() > NOTICE_SHARDS / 2, "200 chats on {} shards", shards.len());
    // A chat's shard holds: its notices stay in order.
    assert_eq!(session_shard("h00", "s1"), session_shard("h00", "s1"));
}

#[tokio::test]
async fn a_whole_peer_notice_waits_for_the_chats_before_it_and_holds_the_ones_after() {
    let mut order = Order::default();
    let (_, a) = order.admit("p", Some("a")).await;
    let (_, b) = order.admit("p", Some("b")).await;
    // Another peer never waits on this one.
    let (_, other) = order.admit("q", None).await;
    drop(other);
    // The peer's list waits until both chats' notices are applied.
    let whole = {
        let wait = order.admit("p", None);
        tokio::pin!(wait);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), wait.as_mut())
                .await
                .is_err()
        );
        drop(a);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), wait.as_mut())
                .await
                .is_err()
        );
        drop(b);
        let (index, taken) = wait.await;
        assert_eq!(index, notice_shard("p"));
        taken
    };
    // The next chat notice waits for the list.
    {
        let wait = order.admit("p", Some("a"));
        tokio::pin!(wait);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), wait.as_mut())
                .await
                .is_err()
        );
        drop(whole);
        let (index, _) = wait.await;
        assert_eq!(index, session_shard("p", "a"));
    }
    // After a chat notice, the next chat notice goes at once.
    let (_, _c) = order.admit("p", Some("c")).await;
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(20), order.admit("p", Some("d")))
            .await
            .is_ok()
    );
}
