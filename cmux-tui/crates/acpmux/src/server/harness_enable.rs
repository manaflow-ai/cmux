//! `_acpmux/harness_enable` (BRING-YOUR-OWN-HARNESS H4): the app's "Enable
//! harness" sheet for a folder harness profile.
//!
//! Without `sha256` it returns the prompt the CLI shows (`prompt`: argv, the
//! program it resolves to, each env key with its source kind, checked files,
//! warnings, the hash and the CLI text) and writes nothing. With `sha256` it
//! records the user's confirmation for exactly those bytes; a file changed
//! since the prompt is refused. Both need the folder's `trusted` answer.
//!
//! Only the unix socket and the local app may call it. A Web or peer
//! connection is refused even for the prompt (it would learn a folder's
//! command lines). The daemon cannot see gestures: the app's native relay
//! sends a confirmation only after a fresh user gesture on the sheet
//! (AGENT-PANE-GESTURE-CREDITS), as for `acp.trust.set`.

use std::path::PathBuf;

use serde_json::{Value, json};

use super::Origin;
use crate::config::folder_profiles::{self, EnableRefusal, FolderState};
use crate::hub::Hub;
use crate::rpc::RpcError;

pub(super) async fn handle(hub: &Hub, origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "enabling a folder harness is accepted only from the local app or the unix socket, never from a remote WebSocket connection or a peer",
        ));
    }
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let folder = text("folder")
        .map(PathBuf::from)
        .filter(|f| f.is_absolute())
        .ok_or_else(|| RpcError::invalid_params("folder must be an absolute path"))?;
    let id = text("id").ok_or_else(|| RpcError::invalid_params("id is required"))?.to_owned();
    let confirm = text("sha256").map(str::to_owned);
    let cfg = hub.config.read().await.clone();
    tokio::task::spawn_blocking(move || {
        let gate = cfg.folder_gate.as_ref().ok_or_else(|| {
            RpcError::invalid_params("this daemon has no home: folder profiles are off")
        })?;
        let shown =
            folder_profiles::prepare_enable(&cfg, gate, &folder, &id).map_err(|e| match e {
                EnableRefusal::NotFound(m) => RpcError::not_found(m),
                EnableRefusal::Refused(m) => RpcError::invalid_params(m),
            })?;
        let Some(sha) = confirm else {
            return Ok(json!({"prompt": shown.prompt}));
        };
        let fp = shown.profile;
        if fp.state == FolderState::Enabled && fp.sha256.as_deref() == Some(sha.as_str()) {
            return Ok(json!({"enabled": fp}));
        }
        let enabled = folder_profiles::enable(&cfg, gate, &folder, &id, &sha)
            .map_err(RpcError::invalid_params)?;
        Ok(json!({"enabled": enabled}))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
}
