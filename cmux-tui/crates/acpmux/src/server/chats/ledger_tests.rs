use super::*;
use crate::config::Config;
use crate::store::MemoryStore;

#[test]
fn only_the_local_socket_and_the_app_read_the_ledger() {
    let hub = Hub::new(Config::default(), Box::new(MemoryStore::default()));
    for origin in [Origin::Web, Origin::Peer] {
        let err = handle(&hub, origin, &serde_json::json!({})).unwrap_err();
        assert!(format!("{err:?}").contains("_acpmux/ledger"), "{err:?}");
    }
    for origin in [Origin::Local, Origin::LocalApp] {
        let reply = handle(&hub, origin, &serde_json::json!({"groupBy": ["day"]})).unwrap();
        assert_eq!(reply["totals"]["turns"], 0);
        assert!(reply["rollups"]["day"].is_array());
        assert!(reply["priceTable"]["version"].is_string());
    }
    assert!(handle(&hub, Origin::Local, &serde_json::json!({"groupBy": ["nope"]})).is_err());
}
