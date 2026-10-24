//! The composer's requests: a chat's unsent draft (`_acpmux/draft_get`, `_acpmux/draft_set`), each
//! typing surface's own draft and the labelled queue (`_acpmux/composer_set`, `_acpmux/composers`,
//! `hub/composers.rs`) and
//! a side question about it (`_acpmux/ask`, `hub/aside.rs`), a side session about it
//! (`_acpmux/btw`, `hub/btw.rs`), and its prompt bookmarks (`_acpmux/bookmark_get`,
//! `_acpmux/bookmark_set`, `hub/bookmarks.rs`).

use super::*;

/// Whether `m` is one of the composer's requests.
pub(super) fn handles(m: &str) -> bool {
    matches!(
        m,
        method::MUX_DRAFT_GET
            | method::MUX_DRAFT_SET
            | method::MUX_COMPOSER_SET
            | method::MUX_COMPOSERS
            | method::MUX_BOOKMARK_GET
            | method::MUX_BOOKMARK_SET
            | method::MUX_ASK
            | method::MUX_BTW
    )
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if m == method::MUX_BOOKMARK_GET || m == method::MUX_BOOKMARK_SET {
        return bookmarks(hub, m, params).await;
    }
    let s = hub.resolve(session_key(params)?)?;
    // A side question and a side session run a turn, under the rules of the connection
    // that asks. The remote guard refuses a side session to a Web connection or a peer.
    let opts = || crate::hub::PromptOptions {
        control: super::super::remote_guard::control_of(conn.origin, conn.auth, params),
        trust_gate: super::super::trust_gate::gated(conn.origin, params),
        ..Default::default()
    };
    if m == method::MUX_BTW {
        let question = str_param(params, "question")
            .ok_or_else(|| RpcError::invalid_params("question is required"))?;
        let model = match params.get("model") {
            None | Some(Value::Null) => None,
            Some(Value::String(m)) => Some(m.as_str()),
            Some(_) => return Err(RpcError::invalid_params("model must be a string")),
        };
        let inline = match params.get("inline") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(inline)) => *inline,
            Some(_) => return Err(RpcError::invalid_params("inline must be a boolean")),
        };
        return hub.btw(&s, question, model, &conn.label(), inline, opts()).await;
    }
    if m == method::MUX_COMPOSERS {
        return Ok(hub.composers_view(&s));
    }
    if m == method::MUX_COMPOSER_SET {
        let surface = crate::hub::composers::surface(params.get("surface"))?
            .ok_or_else(|| RpcError::invalid_params("surface is required"))?;
        let text = str_param(params, "text")
            .ok_or_else(|| RpcError::invalid_params("text is required"))?;
        return hub.composer_set(&s, surface, text, &conn.label());
    }
    if m == method::MUX_DRAFT_GET {
        return Ok(json!({"sessionId": s.id, "draft": s.meta().composer_draft}));
    }
    let text =
        str_param(params, "text").ok_or_else(|| RpcError::invalid_params("text is required"))?;
    if m == method::MUX_DRAFT_SET {
        let draft = hub.set_composer_draft(&s, text).map_err(RpcError::invalid_params)?;
        return Ok(json!({"sessionId": s.id, "draft": draft}));
    }
    // The aside is a fork: a new session, so it needs room (`hub/admission.rs`).
    let who = super::who(conn);
    let admitted = hub.admit_new(super::ask(conn, params, &who)).await?;
    admitted.run(hub.ask_aside(&s, text, &conn.label(), opts())).await
}

/// What `session/prompt` does once the hub took the prompt: tell the connection
/// (`promptAccepted`), and when the prompt names its surface (`_meta.acpmux.surface`), label it
/// with that surface (`hub/composers.rs`). A malformed surface refuses the prompt unrecorded.
pub(super) fn on_accepted(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    s: &Arc<crate::hub::Session>,
    params: &Value,
) -> Result<Box<dyn FnOnce(Value) + Send>, RpcError> {
    let surface = crate::hub::composers::surface(mux_meta(params).and_then(|m| m.get("surface")))?;
    let (notify, hub, s, client) = (conn.clone(), hub.clone(), s.clone(), conn.label());
    Ok(Box::new(move |v| {
        if let Some(surface) = surface {
            hub.composer_accepted(&s, surface, &client, &v);
        }
        notify.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v))
    }))
}

/// `_acpmux/bookmark_get` and `_acpmux/bookmark_set`: the chat's prompt bookmarks
/// (`hub/bookmarks.rs`). A peer's chat never gets here: `peer_forward.rs` sends it to its owner.
async fn bookmarks(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    if m == method::MUX_BOOKMARK_GET {
        let marks: Vec<u64> = s.meta().bookmarks.iter().copied().collect();
        return Ok(json!({"sessionId": s.id, "bookmarks": marks}));
    }
    let seq = params
        .get("seq")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("seq is required"))?;
    let bookmarked = params
        .get("bookmarked")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("bookmarked is required"))?;
    let marks = hub.set_bookmark(&s, seq, bookmarked).await?;
    Ok(json!({"sessionId": s.id, "bookmarks": marks}))
}
