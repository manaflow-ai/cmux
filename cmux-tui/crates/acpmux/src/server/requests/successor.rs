//! The session a command-line `session/new` takes over from (`hub/lineage/successor.rs`), here or
//! through a peer's `--host`, never an app chat's: `--harness-from` copies its harness, a bare
//! default start where it ran a named profile is refused, and a start that runs unlike it is
//! warned about in the reply (`_meta.acpmux.successor`).

use super::*;
use crate::hub::lineage::successor::{HARNESS_FROM_FIELD, Successor};

/// The predecessor `params` names, or None for an app chat, an adopted chat or an ephemeral run.
/// `--harness-from` is refused wherever it would not be honoured: over any connection but the
/// local socket (a remote one's guard checked the harness the request names, not a copied one),
/// and on an adopt or an ephemeral run, which take no predecessor.
pub(super) async fn find(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
    lineage: Option<&crate::store::Lineage>,
    adopting: bool,
) -> Result<Option<Successor>, RpcError> {
    let meta = mux_meta(params);
    let ephemeral = crate::server::ephemeral::requested(params);
    let copies = meta.and_then(|m| m.get(HARNESS_FROM_FIELD)).is_some_and(|v| !v.is_null());
    if copies && (conn.origin != Origin::Local || adopting || ephemeral) {
        return Err(RpcError::invalid_params(
            "--harness-from is taken by `acpmux new` and `ensure` over the local socket only, \
             never with an adopt or an ephemeral run; name the harness with -m",
        )
        .with_data(json!({"reason": "successor.harness_from_refused"})));
    }
    let command_line = matches!(conn.origin, Origin::Local | Origin::Peer);
    if !command_line || adopting || ephemeral {
        return Ok(None);
    }
    hub.successor(params, meta, lineage).await
}

/// Puts the warning for `session`, started as `successor`, in its reply's `summary`.
pub(super) async fn warn(
    hub: &Arc<Hub>,
    successor: Option<&Successor>,
    session: &crate::hub::Session,
    summary: &mut Value,
) {
    if let Some(s) = successor
        && let Some(w) = hub.successor_warning(s, session).await
    {
        summary.set("successor", w);
    }
}
