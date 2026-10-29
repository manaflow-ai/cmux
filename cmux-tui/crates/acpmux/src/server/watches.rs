//! Durable watches use the local outbox authority, never a Web/peer origin.
use super::*;
use crate::hub::watches::{Watch, resolve};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Add {
    to: Option<String>,
    sessions: Vec<String>,
    #[serde(default)]
    until: Vec<String>,
    #[serde(rename = "match")]
    match_text: Option<String>,
    once: Option<bool>,
}
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(crate::hub::outbox::local_only());
    }
    match m {
        method::MUX_WATCH_LS => Ok(hub.watches.list(hub)),
        method::MUX_WATCH_RM => {
            let id = params["id"]
                .as_str()
                .ok_or_else(|| RpcError::invalid_params("watch id is required"))?;
            if hub.watches.remove(id)? {
                Ok(json!({"removed": id}))
            } else {
                Err(RpcError::not_found(format!("no watch {id:?}; call _acpmux/watch_ls")))
            }
        }
        _ => {
            hub.wait_logs().await;
            let mut a: Add = serde_json::from_value(params.clone())
                .map_err(|e| RpcError::invalid_params(e.to_string()))?;
            if a.once == Some(false) {
                return Err(RpcError::invalid_params("recurring watches are not supported yet"));
            }
            if a.sessions.is_empty() {
                return Err(RpcError::invalid_params(
                    "watch needs at least one session; run acpmux ls",
                ));
            }
            if a.until.is_empty() {
                a.until = vec!["ready".into(), "permission".into()];
            }
            if a.until
                .iter()
                .any(|u| !matches!(u.as_str(), "ready" | "permission" | "done" | "closed"))
            {
                return Err(RpcError::invalid_params(
                    "until accepts ready, permission, done or closed",
                ));
            }
            let key = match a.to.as_deref() {
                None | Some("@" | "current") => conn.caller().ok_or_else(|| {
                    RpcError::invalid_params(
                        "to is required without an authenticated caller session",
                    )
                })?,
                Some(to) => to,
            };
            let to = resolve(hub, key)?;
            let mut sessions =
                a.sessions.iter().map(|k| resolve(hub, k)).collect::<Result<Vec<_>, _>>()?;
            sessions.sort();
            sessions.dedup();
            if sessions.contains(&to) {
                return Err(RpcError::invalid_params(
                    "a session cannot watch itself (that would wake it forever)",
                ));
            }
            let cursors = sessions
                .iter()
                .map(|k| (k.clone(), crate::hub::watches::seed(hub, k, a.match_text.as_deref())))
                .collect();
            hub.watches.add(Watch {
                id: uuid::Uuid::now_v7().to_string(),
                to,
                sessions,
                until: a.until,
                match_text: a.match_text,
                once: a.once.unwrap_or(true),
                caller: conn.caller().filter(|_| !conn.is_person()).map(str::to_owned),
                active: true,
                cursors,
                offline: Default::default(),
            })
        }
    }
}
