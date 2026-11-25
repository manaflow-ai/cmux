//! `_acpmux/ledger`: what turns cost on this machine (`hub/ledger`). Spend is the person's data,
//! like `_acpmux/stats`: the local unix socket and the app's own pane (LocalApp) get it; a Web
//! or Peer origin gets "Method not found". Never forwarded to a peer. A read folds the
//! in-memory buckets of the days in range only: no log is read.

use std::sync::Arc;

use serde_json::Value;

use super::super::Origin;
use crate::hub::Hub;
use crate::hub::ledger::LedgerQuery;
use crate::rpc::{RpcError, method};

pub(super) fn handle(hub: &Arc<Hub>, origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Err(RpcError::method_not_found(method::MUX_LEDGER));
    }
    let query = LedgerQuery::from_params(params, crate::store::now_ms())
        .map_err(RpcError::invalid_params)?;
    serde_json::to_value(hub.ledger.query(&query)).map_err(|e| RpcError::internal(e.to_string()))
}

#[cfg(test)]
mod tests {
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
}
