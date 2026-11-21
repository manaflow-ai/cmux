use super::*;
use base64::Engine;

/// A peer link that ends (the peer closes every handle it held for it) gives this
/// connection's places back at once, not after IDLE.
#[tokio::test]
async fn a_handle_of_an_ended_peer_link_holds_no_place() {
    let (notices, _rx) = tokio::sync::mpsc::channel(8);
    let peer = Peer::new("b", "ws://127.0.0.1:9", None, None, notices);
    let media = RemoteMedia::default();
    let epoch = peer.link_epoch();
    media.with(|table| {
        for n in 0..MAX_HANDLES {
            let remote = Remote {
                peer: peer.clone(),
                session: "s".into(),
                handle: format!("theirs-{n}"),
                used: Instant::now(),
                epoch,
            };
            table.held.insert(format!("mine-{n}"), remote);
        }
    });
    assert_eq!(media.reserve(), Some(false), "a full table has no room");
    peer.link_ended();
    assert_eq!(media.reserve(), Some(true), "the ended link's handles kept their places");
    assert_eq!(media.with(|table| table.held.len()), Some(0));
}

#[test]
fn the_decoded_length_matches_the_bytes() {
    for n in 0..10 {
        let data = base64::engine::general_purpose::STANDARD.encode(vec![7u8; n]);
        assert_eq!(decoded_len(&data), n as u64, "{data}");
    }
}
