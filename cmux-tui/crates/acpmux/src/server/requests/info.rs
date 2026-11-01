//! The session info request (`_acpmux/info`): one chat's detail.

use super::*;

/// `transferBlocked` is the cached durable transfer decision (`hub/transfer_authority.rs`):
/// true while a move away is begun or committed, null until a restored log is read.
pub(super) async fn info(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve_told(session_key(params)?, conn.origin == Origin::Local)?;
    // Never waited for: the next read has it (`hub/usage_view.rs`).
    let later = hub.clone();
    tokio::spawn(async move { later.refresh_usage_stats().await });
    // After a restart the chat logs are read after the ready line; until
    // then the queue, the turn and the status are the session list's. Info
    // waits for this chat's (#22916; read now if the background pass has not
    // reached it, `hub/log_load.rs`), unless a caller that reads only what the
    // session list holds (its id, env, policy, rules, modes) asks with
    // `waitLogs: false`: it answers at once, with `logsLoading`.
    if params.get("waitLogs").and_then(Value::as_bool) != Some(false) {
        hub.session_log(&s).await;
    }
    let mut detail = hub.session_detail(&s);
    if let Some(obj) = detail.as_object_mut() {
        obj.insert("logsLoading".into(), json!(!hub.session_log_loaded(&s)));
        obj.insert("transferBlocked".into(), json!(s.transfer_blocked()));
    }
    // The session env reaches the unix socket only: no summary or
    // event carries it, so a key added to the allowlist later never
    // reaches another origin by default (session_env.rs).
    if conn.origin == Origin::Local
        && let Some(obj) = detail.as_object_mut()
    {
        obj.insert("sessionEnv".into(), json!(crate::session_env::shown(&s.meta().session_env)));
    }
    // One message carries it whole, its largest fields trimmed if need be: a detail refused
    // as too large is refused again on every read (`hub/reply_fit.rs`).
    crate::hub::reply_fit::fit_reply_object(&mut detail);
    Ok(detail)
}
