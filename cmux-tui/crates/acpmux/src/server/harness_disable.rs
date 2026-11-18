//! `_acpmux/harness_disable` (BRING-YOUR-OWN-HARNESS H4): withdraws the
//! recorded confirmation of a folder harness profile, the mirror of
//! `_acpmux/harness_enable`. `cmux harness disable ID --folder DIR` and the
//! command palette's Disable Folder Harness row send it.
//!
//! It writes only the enable record (`folder_profiles::disable`): the next
//! session in the folder asks to enable the profile again. Withdrawing needs
//! no trust answer and no prompt. Only the unix socket and the local app may
//! call it, as for enable: a Web or peer connection is refused (it would
//! learn which folders hold enabled profiles).

use std::path::PathBuf;

use serde_json::{Value, json};

use super::Origin;
use crate::config::folder_profiles;
use crate::hub::Hub;
use crate::rpc::RpcError;

pub(super) async fn handle(hub: &Hub, origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "disabling a folder harness is accepted only from the local app or the unix socket, never from a remote WebSocket connection or a peer",
        ));
    }
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let folder = text("folder")
        .map(PathBuf::from)
        .filter(|f| f.is_absolute())
        .ok_or_else(|| RpcError::invalid_params("folder must be an absolute path"))?;
    let id = text("id").ok_or_else(|| RpcError::invalid_params("id is required"))?.to_owned();
    let cfg = hub.config.read().await.clone();
    tokio::task::spawn_blocking(move || {
        let gate = cfg.folder_gate.as_ref().ok_or_else(|| {
            RpcError::invalid_params("this daemon has no home: folder profiles are off")
        })?;
        let disabled =
            folder_profiles::disable(gate, &folder, &id).map_err(RpcError::invalid_params)?;
        Ok(json!({"disabled": disabled, "folder": folder, "id": id}))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
}
