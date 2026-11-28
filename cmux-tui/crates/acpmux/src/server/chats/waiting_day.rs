//! `_acpmux/waiting_day`: when each chat worked or waited on the person
//! (`hub/ledger/waiting_day.rs`), for the Home's "Waiting on me" lanes. How a person works is
//! their data, like `_acpmux/ledger`: the local unix socket and the app's own pane (LocalApp) get it; a Web or Peer
//! origin gets "Method not found". Never forwarded to a peer. A read walks the kept marks only.

use std::sync::Arc;

use serde_json::Value;

use super::super::Origin;
use crate::hub::Hub;
use crate::hub::ledger::waiting_day;
use crate::rpc::{RpcError, method};

pub(super) fn handle(hub: &Arc<Hub>, origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Err(RpcError::method_not_found(method::MUX_WAITING_DAY));
    }
    let (since, until) = waiting_day::range(params, crate::store::now_ms());
    serde_json::to_value(hub.ledger.waiting.query(since, until))
        .map_err(|e| RpcError::internal(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::store::MemoryStore;

    #[test]
    fn only_the_local_socket_and_the_app_read_the_waiting_day() {
        let hub = Hub::new(Config::default(), Box::new(MemoryStore::default()));
        for origin in [Origin::Web, Origin::Peer] {
            let err = handle(&hub, origin, &serde_json::json!({})).unwrap_err();
            assert!(format!("{err:?}").contains("_acpmux/waiting_day"), "{err:?}");
        }
        for origin in [Origin::Local, Origin::LocalApp] {
            let reply = handle(&hub, origin, &serde_json::json!({})).unwrap();
            assert_eq!(reply["blockedMs"], 0);
            assert!(reply["lanes"].as_array().unwrap().is_empty());
            assert!(reply["since"].as_u64().unwrap() < reply["until"].as_u64().unwrap());
        }
    }
}
