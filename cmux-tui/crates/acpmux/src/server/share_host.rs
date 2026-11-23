//! `_acpmux/share_host_status`: the share host's status (`share_host/`), what
//! `acpmux share-host status` prints. Local socket only.

use serde_json::Value;

use super::{Conn, Origin};
use crate::rpc::{RpcError, method};

pub(super) fn dispatch(conn: &Conn, m: &str) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_SHARE_HOST_STATUS {
        return None;
    }
    if conn.origin != Origin::Local {
        return Some(Err(RpcError::method_not_found(&format!("{m} (local socket only)"))));
    }
    Some(Ok(crate::share_host::status_now()))
}
