//! `_acpmux/harness/add|remove|restore|doctor|secret/set|icon` and `_acpmux/registry`
//! (BRING-YOUR-OWN-HARNESS H2): the app's Settings, palette and MCP tools add
//! and check a user's own harness through the daemon. The work is
//! `crate::harness_admin`, shared with the CLI. Also Update Everything's
//! `_acpmux/harness/update` and `_acpmux/sessions/restart_harness`
//! (cx-1mbnu), which the machine's cmux-tui daemon calls: like `add` and
//! `doctor` they run programs, so only the unix socket may.
//!
//! Who may call them (coordinator decision 2026-10-08): `add` writes a
//! profile that runs a program and `doctor` starts a harness, so only the
//! unix socket may call them (`secret/set` too: it runs the secret store's
//! program and changes what a harness signs in with, u2586); LocalApp, Web
//! and peer are refused, keeping remote_guard's rule that LocalApp never
//! makes this machine spawn a process it chooses. The local app may
//! `remove`, `restore` (recoverable), read the `registry` and ask for
//! `health`, which runs only the configured
//! harnesses' `--version` and `auth.check`, as the daemon does every few
//! hours; a Web page may read `health` as last checked (nothing runs); peer
//! may call none of them. The daemon cannot see
//! gestures; the app's host calls add and doctor over the unix socket only
//! from a user's action.
//! After a change the catalog reloads and `_acpmux/watch` connections get
//! `_acpmux/harnesses_changed`.
//!
//! A machine-inventory consumer first requires `harnessInventory` in the
//! initialize reply's `_meta.acpmux.features`, then asks for health with
//! exactly `{view: "inventory"}`. Older daemons ignore unknown health params,
//! so the feature check is required to avoid accidentally starting a check.
//! This view reports only cached versions, install channels and auth enums;
//! an empty cache is unknown inventory, not evidence that no CLI is installed.
//! The separately negotiated local-socket inventory refresh asks only the
//! registries for cached installations. It never enters harness_health's
//! probe/auto-update path, and preserves failed-source timestamps.

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

/// The methods `handle` answers.
pub(super) const METHODS: &[&str] = &[
    method::MUX_HARNESS_ADD,
    method::MUX_HARNESS_REMOVE,
    method::MUX_HARNESS_RESTORE,
    method::MUX_HARNESS_DOCTOR,
    method::MUX_HARNESS_SECRET_SET,
    method::MUX_HARNESS_ICON,
    method::MUX_REGISTRY,
    method::MUX_HARNESS_HEALTH,
    method::MUX_HARNESS_INVENTORY_REFRESH,
    method::MUX_HARNESS_UPDATE_PLAN,
    method::MUX_HARNESS_UPDATE_PREPARE,
    method::MUX_HARNESS_UPDATE,
    method::MUX_SESSIONS_RESTART_HARNESS,
];

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if matches!(m, method::MUX_HARNESS_UPDATE_PLAN | method::MUX_HARNESS_UPDATE_PREPARE) {
        if origin != Origin::Local {
            return Err(RpcError::invalid_params("harness_update_plan.not_trusted"));
        }
        if !params.is_object() {
            return Err(RpcError::invalid_params("harness_update_plan.bad_request"));
        }
        let params = serde_json::from_value::<crate::protocol::inventory::HarnessUpdatePlanParams>(
            params.clone(),
        )
        .map_err(|_| RpcError::invalid_params("harness_update_plan.bad_request"))?;
        return if m == method::MUX_HARNESS_UPDATE_PREPARE {
            let hub = hub.clone();
            tokio::task::spawn_blocking(move || hub.health.prepare_update(&params.cli))
                .await
                .map_err(joined)?
        } else {
            hub.health.cached_update_plan(&params.cli)
        };
    }
    if m == method::MUX_HARNESS_INVENTORY_REFRESH {
        if origin != Origin::Local {
            return Err(RpcError::invalid_params("harness_inventory.not_trusted"));
        }
        if !params.is_object() {
            return Err(RpcError::invalid_params("harness_inventory.bad_request"));
        }
        serde_json::from_value::<crate::protocol::inventory::InventoryRefreshParams>(
            params.clone(),
        )
        .map_err(|_| RpcError::invalid_params("harness_inventory.bad_request"))?;
        return hub.health.refresh_inventory_latest().await;
    }
    let spawns = matches!(
        m,
        method::MUX_HARNESS_ADD
            | method::MUX_HARNESS_DOCTOR
            | method::MUX_HARNESS_SECRET_SET
            | method::MUX_HARNESS_UPDATE
            | method::MUX_SESSIONS_RESTART_HARNESS
    );
    if spawns && origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "adding, checking or updating a harness runs a program: only the unix socket may ask for it",
        ));
    }
    // Inventory consumers read the cache without entering the health
    // control path (which may run a first check or start auto-updates).
    // Keep the existing health origins: a peer still cannot read this host.
    if m == method::MUX_HARNESS_HEALTH && params.get("view").is_some() {
        if origin == Origin::Peer {
            return Err(RpcError::invalid_params(
                "a peer cannot read this host's harness inventory",
            ));
        }
        return crate::harness_health::inventory::view(&hub.health.rows(), params);
    }
    // A plain browser page on the listener (Web, never a peer) may read the
    // last health rows: no refresh, no latest-version check, no auto-update
    // choice, and no first check (each of those runs the harnesses' CLIs).
    // Decided by the chief 2026-10-13 for the agent pane's dev host (cx-jlzsf).
    if origin == Origin::Web && m == method::MUX_HARNESS_HEALTH {
        let asks =
            |key: &str| params.get(key).is_some_and(|v| !v.is_null() && *v != Value::Bool(false));
        if ["refresh", "rescan", "checkLatest", "autoUpdate"].iter().any(|key| asks(key)) {
            return Err(RpcError::invalid_params(
                "a remote WebSocket connection reads harness health only as last checked (no refresh, rescan, checkLatest or autoUpdate)",
            ));
        }
        // Binding a login command reads current configuration only; it starts no probes.
        let rows = hub.health.rows_for_subjects(&hub.health_subjects().await);
        return Ok(json!({"harnesses": rows}));
    }
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "harness profiles are changed only from the local app or the unix socket, never from a remote WebSocket connection or a peer",
        ));
    }
    // A capture fixture's daemon (`harness_fixture.rs`) neither reads the ACP
    // Registry nor adds a harness: both read this host's PATH and the network.
    if matches!(m, method::MUX_HARNESS_ADD | method::MUX_REGISTRY)
        && crate::harness_fixture::active().is_some()
    {
        return Err(RpcError::invalid_params(
            "this daemon serves a capture fixture's harnesses (ACPMUX_HARNESS_FIXTURE)",
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
                // `prompt: true` (the contract's name) or the older `noPrompt`.
                prompt: params.get("prompt").and_then(Value::as_bool).unwrap_or_else(|| {
                    !params.get("noPrompt").and_then(Value::as_bool).unwrap_or(false)
                }),
                timeout: Duration::from_secs(secs),
                lookup_env: Box::new(crate::login_env::reference_var),
                lookup_keychain: Box::new(profiles::keychain_lookup),
            };
            admin::doctor_value(&doctor(&cfg, &id, &opts).await)
        }
        method::MUX_HARNESS_SECRET_SET => {
            let id =
                text("id").ok_or_else(|| RpcError::invalid_params("id is required"))?.to_owned();
            let key =
                text("key").ok_or_else(|| RpcError::invalid_params("key is required"))?.to_owned();
            // The value lives only here and on the store command's stdin.
            let value = params
                .get("value")
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .map(|v| zeroize::Zeroizing::new(v.to_owned()))
                .ok_or_else(|| RpcError::invalid_params("value is required"))?;
            let cfg = hub.config.read().await.clone();
            let stored = tokio::task::spawn_blocking(move || {
                admin::secret_set(&id, &key, value.as_str(), &cfg, &|cmd| {
                    crate::cli::harness_secret::run_store(cmd)
                })
            })
            .await
            .map_err(joined)?
            .map_err(rpc_error)?;
            hub.reload_and_announce().await;
            serde_json::to_value(&stored).map_err(|e| RpcError::internal(e.to_string()))?
        }
        method::MUX_HARNESS_ICON => {
            use crate::harness_icon_set::{IconChange, set_icon};
            let id =
                text("id").ok_or_else(|| RpcError::invalid_params("id is required"))?.to_owned();
            let change = if params.get("clear").and_then(Value::as_bool) == Some(true) {
                IconChange::Clear
            } else if let Some(data) = text("data") {
                use base64::Engine as _;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(data)
                    .map_err(|_| RpcError::invalid_params("data must be base64"))?;
                let ext = text("ext").unwrap_or("png").to_ascii_lowercase();
                IconChange::Image { bytes, ext }
            } else if let Some(icon) = text("icon") {
                // A page never names a file on this Mac: it sends the bytes.
                if matches!(
                    crate::config::harness_icon::IconValue::parse(icon),
                    Ok(crate::config::harness_icon::IconValue::File(_))
                ) {
                    return Err(RpcError::invalid_params(
                        "send an image as {data, ext}, not a file path",
                    ));
                }
                IconChange::Value(icon.to_owned())
            } else {
                return Err(RpcError::invalid_params("give icon, data or clear"));
            };
            let set = tokio::task::spawn_blocking(move || set_icon(&id, change, &sources))
                .await
                .map_err(joined)?
                .map_err(rpc_error)?;
            hub.reload_and_announce().await;
            json!({"id": set.id, "path": set.path, "icon": set.icon})
        }
        method::MUX_REGISTRY => {
            let refresh = params.get("refresh").and_then(Value::as_bool).unwrap_or(false);
            let reg = crate::cli::harness_registry::registry(refresh)
                .await
                .map_err(|e| RpcError::internal(format!("{e:#}")))?;
            admin::registry_value(&reg, &crate::config::which)
        }
        method::MUX_HARNESS_HEALTH => return hub.harness_health(params).await,
        method::MUX_HARNESS_UPDATE => return hub.update_harnesses(params).await,
        method::MUX_SESSIONS_RESTART_HARNESS => {
            let harnesses = id_set(params, "harnesses", "harnesses must be harness ids")?;
            let sessions = id_set(params, "sessions", "sessions must be session ids")?;
            let done = hub.restart_harnesses(harnesses.as_ref(), sessions.as_ref()).await;
            let errors: Vec<Value> = done
                .failed
                .iter()
                .map(|(session, error)| json!({"session": session, "error": error}))
                .collect();
            json!({"restarted": done.now, "after_turn": done.after_turn,
                   "failed": errors.len(), "errors": errors})
        }
        other => return Err(RpcError::method_not_found(other)),
    };
    Ok(reply)
}

/// One payload of the watchers' harness feed to watching connection `conn`:
/// `_acpmux/harnesses_changed`, `_acpmux/peer_state_changed` when marked a peer
/// state note (`peer.rs` `report_states`), or `_acpmux/start_mode_changed {}` when
/// marked a start-mode notice (`hub/start_mode.rs`), which only local
/// connections get (a remote-origin connection's chats get no start mode).
pub(super) fn watch_note(conn: &super::Conn, note: Value) {
    if let Some(state) = note.get(crate::peer_states::STATE_NOTE) {
        conn.send(&crate::rpc::Message::notification(
            method::MUX_PEER_STATE_CHANGED,
            state.clone(),
        ));
    } else if note.get(crate::hub::start_mode::START_MODE_NOTE).is_none() {
        conn.send(&crate::rpc::Message::notification(method::MUX_HARNESSES_CHANGED, note));
    } else if !conn.origin.web_class() {
        conn.send(&crate::rpc::Message::notification(method::MUX_START_MODE_CHANGED, json!({})));
    }
}

/// An optional list of ids in `params[key]` (`restart_harness`'s filters): None when absent.
fn id_set(
    params: &Value,
    key: &str,
    error: &str,
) -> Result<Option<std::collections::BTreeSet<String>>, RpcError> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(list)) => list
            .iter()
            .map(|v| v.as_str().map(str::to_owned))
            .collect::<Option<std::collections::BTreeSet<String>>>()
            .map(Some)
            .ok_or_else(|| RpcError::invalid_params(error)),
        Some(_) => Err(RpcError::invalid_params(error)),
    }
}
