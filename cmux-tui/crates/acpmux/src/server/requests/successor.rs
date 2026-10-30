//! The session a command-line `session/new` takes over from (`hub/lineage/successor.rs`), here or
//! through a peer's `--host`, never an app chat's: `--harness-from` copies its harness, a bare
//! default start where it ran a named profile is refused, and a start that runs unlike it is
//! warned about in the reply (`_meta.acpmux.successor`).

use super::*;
use crate::hub::lineage::successor::Successor;

/// The predecessor `params` names, or None for an app chat, an adopted chat or an ephemeral run.
pub(super) async fn find(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
    lineage: Option<&crate::store::Lineage>,
    adopting: bool,
) -> Result<Option<Successor>, RpcError> {
    let command_line = matches!(conn.origin, Origin::Local | Origin::Peer);
    if !command_line || adopting || crate::server::ephemeral::requested(params) {
        return Ok(None);
    }
    hub.successor(params, mux_meta(params), lineage, conn.origin == Origin::Peer).await
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
