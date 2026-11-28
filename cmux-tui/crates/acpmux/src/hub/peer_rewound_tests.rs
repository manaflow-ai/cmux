//! A peer whose journal of a chat went backwards (`_acpmux/rewound` from `peer.rs`
//! `replay_chat`: a Cloud machine back from a hard stop on a log shorter than what this daemon
//! relayed) is relayed to the clients reading that chat here as one record they never store,
//! with the journal's new end, so they drop what they hold past it (`server/mod.rs` `deliver`).

use super::*;
use crate::peer::{Peer, PeerNotice};
use serde_json::json;
use std::path::Path;

#[test]
fn a_peer_journal_that_went_backwards_reaches_the_chat_readers() {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub =
        Hub::new(cfg.clone(), crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap());
    let peer = Peer::new("cloud", "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
    hub.peers.lock().unwrap().insert("cloud".into(), peer.clone());
    let mut events = hub.subscribe();
    let rewound = |params| PeerNotice::Notification {
        method: crate::rpc::method::MUX_REWOUND.into(),
        params,
        link: 0,
    };
    // One without a session or an end says nothing.
    hub.apply_peer_notice("cloud", peer.generation, rewound(json!({"lastSeq": 3})));
    hub.apply_peer_notice("cloud", peer.generation, rewound(json!({"sessionId": "s"})));
    hub.apply_peer_notice(
        "cloud",
        peer.generation,
        rewound(json!({"sessionId": "s", "lastSeq": 3})),
    );
    let ev = events.try_recv().expect("the rewind is relayed");
    assert_eq!(ev.session_id, "s");
    assert_eq!(ev.record.kind, PEER_REWOUND);
    assert_eq!(ev.record.dir, "peer");
    assert_eq!(ev.record.seq, 0, "never a record of the chat's own");
    assert_eq!(ev.record.msg, json!({"sessionId": "s", "lastSeq": 3}));
    assert_eq!(ev.remote.as_ref().map(|r| r.peer.as_str()), Some("cloud"));
    assert!(events.try_recv().is_err(), "once");
}
