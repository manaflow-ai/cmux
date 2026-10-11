//! `_acpmux/route/list|show|add|edit|remove|restore|test`,
//! `_acpmux/route/default.set` and `_acpmux/chat/route.set` (ROUTES R1-R3):
//! the app's Settings, palette, chat menu and MCP tools, and `cmux route …`,
//! manage routes through the daemon. The store is `crate::routes`.
//!
//! Who may call them: `add`, `edit`, `remove` and `restore` change where a
//! harness sends prompts and which secret it sends, so only the unix socket
//! may call them (the app's host calls them over it from a user action). The
//! local app may read (`list`, `show`), `test` and pick a route
//! (`default.set`, `chat/route.set`). Web and peer may call none of them.

use std::sync::Arc;

use serde_json::{Value, json};

use super::Origin;
use crate::hub::Hub;
use crate::hub::route_error;
use crate::routes::{self, RouteError};
use crate::rpc::{RpcError, method};

fn joined(e: tokio::task::JoinError) -> RpcError {
    RpcError::internal(e.to_string())
}

/// A route file as `add`/`edit` params: what `edit` starts from.
fn params_of(file: &routes::RouteFile) -> Value {
    let mut v = serde_json::to_value(file).unwrap_or_else(|_| json!({}));
    let Some(obj) = v.as_object_mut() else { return v };
    // The TOML keys are snake_case; the RPC's are camelCase.
    for (from, to) in [
        ("anthropic_base_url", "anthropicBaseUrl"),
        ("openai_base_url", "openaiBaseUrl"),
        ("health_url", "healthUrl"),
        ("auto_fallback", "autoFallback"),
    ] {
        if let Some(x) = obj.remove(from) {
            obj.insert(to.into(), x);
        }
    }
    v
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "routes are changed only from the local app or the unix socket, never from a remote WebSocket connection or a peer",
        ));
    }
    let writes = matches!(
        m,
        method::MUX_ROUTE_ADD
            | method::MUX_ROUTE_EDIT
            | method::MUX_ROUTE_REMOVE
            | method::MUX_ROUTE_RESTORE
    );
    if writes && origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "adding or changing a route changes where prompts and secrets go: only the unix socket may ask for it",
        ));
    }
    let (dir, state) = routes::places(&*hub.config.read().await);
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let need = |key: &str| {
        text(key)
            .map(str::to_owned)
            .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
    };
    match m {
        method::MUX_ROUTE_LIST => {
            let (list, problems) = routes::load(dir.as_deref());
            let bindings = routes::bindings(&state);
            let active = match text("sessionId") {
                Some(key) => {
                    let s = hub.resolve(key)?;
                    let meta = s.meta();
                    let family = hub.config.read().await.family(&meta.harness).unwrap_or_default();
                    let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
                    routes::bound_route(&bindings, &s.id, workspace, &family)
                        .map(|(id, scope)| json!({"routeId": id, "scope": scope}))
                }
                None => None,
            };
            Ok(json!({
                "routes": list.iter().map(routes::Route::view).collect::<Vec<_>>(),
                "problems": problems,
                "bindings": bindings,
                "active": active,
                "kinds": routes::RouteKind::ALL.iter().map(|k| k.as_str()).collect::<Vec<_>>(),
            }))
        }
        method::MUX_ROUTE_SHOW => {
            let id = need("id")?;
            routes::find(dir.as_deref(), &id).map(|r| r.view()).map_err(|e| route_error(&e))
        }
        method::MUX_ROUTE_ADD | method::MUX_ROUTE_EDIT => {
            let id = need("id")?;
            let editing = m == method::MUX_ROUTE_EDIT;
            let merged = if editing {
                let old = routes::find(dir.as_deref(), &id).map_err(|e| route_error(&e))?;
                let mut base = params_of(&old.file);
                if let (Some(b), Some(p)) = (base.as_object_mut(), params.as_object()) {
                    for (k, v) in p {
                        if k == "id" {
                            continue;
                        }
                        if v.is_null() {
                            b.remove(k);
                        } else {
                            b.insert(k.clone(), v.clone());
                        }
                    }
                }
                base
            } else {
                params.clone()
            };
            let file = routes::file_from_json(&merged).map_err(|e| route_error(&e))?;
            let replace =
                editing || params.get("replace").and_then(Value::as_bool).unwrap_or(false);
            let route = tokio::task::spawn_blocking(move || {
                routes::add(dir.as_deref(), &id, &file, replace)
            })
            .await
            .map_err(joined)?
            .map_err(|e| route_error(&e))?;
            Ok(route.view())
        }
        method::MUX_ROUTE_REMOVE => {
            let id = need("id")?;
            let backup =
                routes::remove(dir.as_deref(), &state, &id).map_err(|e| route_error(&e))?;
            Ok(json!({"id": id, "backup": backup}))
        }
        method::MUX_ROUTE_RESTORE => {
            let backup = need("backup")?;
            routes::restore(dir.as_deref(), &state, &backup)
                .map(|r| r.view())
                .map_err(|e| route_error(&e))
        }
        method::MUX_ROUTE_TEST => {
            let id = need("id")?;
            let route = routes::find(dir.as_deref(), &id).map_err(|e| route_error(&e))?;
            Ok(routes::probe(&route, &state).await)
        }
        method::MUX_ROUTE_DEFAULT_SET => {
            let scope = need("scope")?;
            if scope.starts_with("chat:") {
                return Err(RpcError::invalid_params(
                    "a chat's route is set with _acpmux/chat/route.set",
                ));
            }
            let route = text("routeId").map(str::to_owned);
            if let Some(id) = &route {
                routes::find(dir.as_deref(), id).map_err(|e| route_error(&e))?;
            }
            let bindings = routes::set_binding(&state, &scope, route.as_deref())
                .map_err(|e| route_error(&e))?;
            Ok(json!({"scope": scope, "routeId": route, "bindings": bindings}))
        }
        method::MUX_CHAT_ROUTE_SET => {
            let s = hub.resolve(&need("sessionId")?)?;
            let now = match text("when") {
                None | Some("after-turn") => false,
                Some("now") => true,
                Some(other) => {
                    return Err(route_error(&RouteError::BadParams(format!(
                        "when is after-turn or now, not {other:?}"
                    ))));
                }
            };
            hub.set_chat_route(&s, text("routeId").map(str::to_owned), now).await
        }
        _ => Err(RpcError::method_not_found(m)),
    }
}
