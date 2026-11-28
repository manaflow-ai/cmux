//! A test's daemon with many saved peers, started lazily (`peer_demand.rs`): the hub's and the
//! server's lazy-start tests share it.

use super::*;

impl Hub {
    /// A test's daemon as one starts after a crash: `peers` saved peers `m0`.. each with one
    /// saved chat `mN-chat` (done), started lazily (`start_saved_peers`), none dialed.
    pub(crate) async fn started_lazily_for_test(dir: &std::path::Path, peers: usize) -> Arc<Hub> {
        use crate::config::{Config, StoreMode};
        let peers_dir = dir.join("peers");
        std::fs::create_dir_all(&peers_dir).unwrap();
        let mut config = Config::default();
        config.store.mode = StoreMode::Local;
        for i in 0..peers {
            let (name, id) = (format!("m{i}"), format!("m{i}-chat"));
            let row = json!({
                "sessionId": id, "name": id, "status": "running", "indicator": "done",
                "updatedAt": 5,
                "sessionReceipt": {"hostId": name, "muxSessionId": id, "agentSessionId": null,
                    "generation": 1},
            });
            let saved = json!({"lastSeen": 7, "sessions": [row]});
            std::fs::write(peers_dir.join(format!("{name}.json")), saved.to_string()).unwrap();
            let url = json!({"url": format!("ws://127.0.0.1:9/{name}")});
            config.peers.insert(name, serde_json::from_value(url).unwrap());
        }
        let store = crate::store::open(&config.store, dir).unwrap();
        let hub =
            Hub::build(config, store, crate::mailbox::Mailbox::memory(), false, false, None, false);
        hub.start_saved_peers().await;
        hub
    }
}
