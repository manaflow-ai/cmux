//! `_acpmux/harness/add|remove|restore|doctor` and `_acpmux/registry`
//! (BRING-YOUR-OWN-HARNESS H2): the app's Settings, palette and MCP tools add
//! and check a user's own harness through the daemon. The work is
//! `crate::harness_admin`, shared with the CLI.
//!
//! Who may call them (coordinator decision 2026-10-08): `add` writes a
//! profile that runs a program and `doctor` starts a harness, so only the
//! unix socket may call them; LocalApp, Web and peer are refused, keeping
//! remote_guard's rule that LocalApp never makes this machine spawn a
//! process. The local app may `remove`, `restore` (recoverable) and read the
//! `registry`; Web and peer may call none of them. The daemon cannot see
//! gestures; the app's host calls add and doctor over the unix socket only
//! from a user's action.
//! After a change the catalog reloads and `_acpmux/watch` connections get
//! `_acpmux/harnesses_changed`.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::Origin;
use crate::cli::harness::{DoctorOptions, doctor};
use crate::config::profiles;
use crate::harness_admin::{self as admin, AddParams, AdminError};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

fn rpc_error(e: AdminError) -> RpcError {
    let base = match &e {
        AdminError::NotFound(m) => RpcError::not_found(m.clone()),
        AdminError::Failed(m) => RpcError::internal(m.clone()),
        other => RpcError::invalid_params(other.message().to_owned()),
    };
    match e.reason() {
        Some(reason) => base.with_data(json!({"reason": reason})),
        None => base,
    }
}

fn joined(e: tokio::task::JoinError) -> RpcError {
    RpcError::internal(e.to_string())
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let spawns = matches!(m, method::MUX_HARNESS_ADD | method::MUX_HARNESS_DOCTOR);
    if spawns && origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "adding or checking a harness runs a program: only the unix socket may ask for it",
        ));
    }
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "harness profiles are changed only from the local app or the unix socket, never from a remote WebSocket connection or a peer",
        ));
    }
    let sources = hub.config.read().await.profile_sources.clone();
    let home = crate::config::home();
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let reply = match m {
        method::MUX_HARNESS_ADD => {
            let p = AddParams::from_json(params).map_err(rpc_error)?;
            let registry = match &p.registry {
                Some(rid) => {
                    let reg = crate::cli::harness_registry::registry(false)
                        .await
                        .map_err(|e| RpcError::internal(format!("{e:#}")))?;
                    // An agent the saved copy lacks may be new: fetch once.
                    let reg = if reg.agent(rid).is_none() {
                        crate::cli::harness_registry::registry(true)
                            .await
                            .map_err(|e| RpcError::internal(format!("{e:#}")))?
                    } else {
                        reg
                    };
                    Some(reg)
                }
                None => None,
            };
            let added = tokio::task::spawn_blocking(move || {
                admin::add(&p, &sources, registry.as_ref(), &crate::config::which)
            })
            .await
            .map_err(joined)?
            .map_err(rpc_error)?;
            hub.reload_and_announce().await;
            json!({"id": added.id, "path": added.path, "diagnostics": added.diagnostics})
        }
        method::MUX_HARNESS_REMOVE => {
            let id =
                text("id").ok_or_else(|| RpcError::invalid_params("id is required"))?.to_owned();
            let cfg = hub.config.read().await.clone();
            let removed =
                tokio::task::spawn_blocking(move || admin::remove(&id, &cfg, &sources, &home))
                    .await
                    .map_err(joined)?
                    .map_err(rpc_error)?;
            hub.reload_and_announce().await;
            json!({"id": removed.id, "backup": removed.backup})
        }
        method::MUX_HARNESS_RESTORE => {
            let backup = text("backup")
                .ok_or_else(|| RpcError::invalid_params("backup is required"))?
                .to_owned();
            let restored =
                tokio::task::spawn_blocking(move || admin::restore(&backup, &sources, &home))
                    .await
                    .map_err(joined)?
                    .map_err(rpc_error)?;
            hub.reload_and_announce().await;
            json!({"id": restored.id, "path": restored.path})
        }
        method::MUX_HARNESS_DOCTOR => {
            let id =
                text("id").ok_or_else(|| RpcError::invalid_params("id is required"))?.to_owned();
            let cfg = hub.config.read().await.clone();
            let secs =
                params.get("timeoutSecs").and_then(Value::as_u64).unwrap_or(20).clamp(5, 120);
            let opts = DoctorOptions {
                // Catalog harnesses only: a folder profile is checked from its folder (CLI).
                folder: None,
                prompt: !params.get("noPrompt").and_then(Value::as_bool).unwrap_or(false),
                timeout: Duration::from_secs(secs),
                lookup_env: Box::new(|var| {
                    crate::login_env::var(var).or_else(|| std::env::var(var).ok())
                }),
                lookup_keychain: Box::new(profiles::keychain_lookup),
            };
            admin::doctor_value(&doctor(&cfg, &id, &opts).await)
        }
        method::MUX_REGISTRY => {
            let refresh = params.get("refresh").and_then(Value::as_bool).unwrap_or(false);
            let reg = crate::cli::harness_registry::registry(refresh)
                .await
                .map_err(|e| RpcError::internal(format!("{e:#}")))?;
            admin::registry_value(&reg, &crate::config::which)
        }
        other => return Err(RpcError::method_not_found(other)),
    };
    Ok(reply)
}
