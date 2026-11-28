//! `_acpmux/asks` and `_acpmux/asks_link_pr`: the Ask ledger (`hub/asks`). What the person
//! asked is the person's data, like `_acpmux/ledger`: the local unix socket and the app's own
//! pane (LocalApp) get it; a Web or Peer origin gets "Method not found". Never forwarded to a
//! peer. A read walks the in-memory index only: no log is read.

use std::sync::Arc;

use serde_json::Value;

use super::super::Origin;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

pub(super) fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_ASKS && m != method::MUX_ASKS_LINK_PR {
        return None;
    }
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Some(Err(RpcError::method_not_found(m)));
    }
    let reply =
        if m == method::MUX_ASKS { hub.asks_read(params) } else { hub.asks_link_pr(params) };
    Some(reply.map_err(RpcError::invalid_params))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::store::MemoryStore;
    use serde_json::json;

    #[test]
    fn only_the_local_socket_and_the_app_read_or_link_asks() {
        let hub = Hub::new(Config::default(), Box::new(MemoryStore::default()));
        assert!(handle(&hub, Origin::Local, "_acpmux/ledger", &json!({})).is_none());
        for origin in [Origin::Web, Origin::Peer] {
            for m in [method::MUX_ASKS, method::MUX_ASKS_LINK_PR] {
                let err = handle(&hub, origin, m, &json!({})).unwrap().unwrap_err();
                assert!(format!("{err:?}").contains(m), "{err:?}");
            }
        }
        for origin in [Origin::Local, Origin::LocalApp] {
            let reply = handle(&hub, origin, method::MUX_ASKS, &json!({})).unwrap().unwrap();
            assert_eq!(reply["asks"], json!([]));
            let linked = handle(
                &hub,
                origin,
                method::MUX_ASKS_LINK_PR,
                &json!({"url": "https://github.com/a/b/pull/1", "body": "Leo-Ask-Trace: ask-0123456789"}),
            )
            .unwrap()
            .unwrap();
            assert_eq!(linked["enabled"], false);
            assert_eq!(linked["linked"], json!([]));
        }
        assert!(
            handle(&hub, Origin::Local, method::MUX_ASKS_LINK_PR, &json!({})).unwrap().is_err()
        );
    }
}
