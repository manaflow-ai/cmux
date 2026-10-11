//! The composer's requests: a chat's unsent draft (`_acpmux/draft_get`, `_acpmux/draft_set`) and
//! a side question about it (`_acpmux/ask`, `hub/aside.rs`).

use super::*;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    if m == method::MUX_DRAFT_GET {
        return Ok(json!({"sessionId": s.id, "draft": s.meta().composer_draft}));
    }
    let text =
        str_param(params, "text").ok_or_else(|| RpcError::invalid_params("text is required"))?;
    if m == method::MUX_DRAFT_SET {
        let draft = hub.set_composer_draft(&s, text).map_err(RpcError::invalid_params)?;
        return Ok(json!({"sessionId": s.id, "draft": draft}));
    }
    // A side question runs a turn, under the rules of the connection that asks.
    let opts = crate::hub::PromptOptions {
        control: super::super::remote_guard::control_of(conn.origin, params),
        trust_gate: super::super::trust_gate::gated(conn.origin, params),
        ..Default::default()
    };
    hub.ask_aside(&s, text, &conn.label(), opts).await
}
