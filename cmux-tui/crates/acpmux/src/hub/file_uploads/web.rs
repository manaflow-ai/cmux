//! Dashboard uploads are capability scoped. Only a Web-origin begin creates this
//! marker; knowing a local upload id or its owner token never grants Web access.
//! The read proof survives queued prompt resolution without exposing the distinct
//! write/delete token to the agent or transcript. Once a resolver claims a file,
//! stale client cleanup cannot delete it. A prompt refused after resolution leaves
//! the file to the existing upload age sweep rather than racing an accepted retry;
//! pre-resolution failures can still cancel immediately.

use super::*;
use crate::rpc::method;

const WEB_PROOF: &str = ".web-proof";
const CONSUMED: &str = ".web-consumed";

pub(crate) fn refused() -> RpcError {
    RpcError::invalid_params("filePut.remote: this Web request does not own a prompt upload")
        .with_data(json!({"reason": "filePut.remote"}))
}

/// A shape check only. The owning daemon subsequently checks the private marker
/// and capability before touching bytes; a forwarding daemon never reads a local
/// upload merely because the remote upload happens to have the same id.
pub(crate) fn request_shape(method: &str, params: &Value) -> bool {
    match method {
        method::MUX_FILE_PUT_BEGIN => params.get("forPrompt") == Some(&Value::Bool(true)),
        method::MUX_FILE_PUT_CHUNK
        | method::MUX_FILE_PUT_FINISH
        | method::MUX_FILE_PUT_CANCEL
        | method::MUX_FILE_PUT_STATUS => {
            params.get("ownerToken").and_then(Value::as_str).is_some_and(|t| !t.is_empty())
        }
        _ => false,
    }
}

fn proof(session: &str, upload: &str) -> Option<String> {
    let dir = upload_dir(session, upload)?;
    let file = crate::config::private_state_file(&dir.join(WEB_PROOF)).ok()?;
    use std::io::Read;
    let mut saved = String::new();
    file.take(65).read_to_string(&mut saved).ok()?;
    (saved.len() == 64).then_some(saved)
}

/// A write/delete token is valid only for an upload begun from Web control.
pub(crate) fn owns(session: &str, upload: &str, owner: &str) -> bool {
    let Some(dir) = upload_dir(session, upload) else { return false };
    let Ok(file) = crate::config::private_state_file(&dir.join(OWNER)) else { return false };
    use std::io::Read;
    let mut saved = String::new();
    file.take(33).read_to_string(&mut saved).is_ok()
        && saved.len() == 32
        && cmux_local_auth::tokens_match(owner, &saved)
        && proof(session, upload).is_some()
}

/// Called under IN_USE after the original is opened for resolution. This marker
/// is separate from `.used`, which resumable status updates before completion.
pub(crate) fn mark_resolved(session: &str, upload: &str) -> Result<(), RpcError> {
    if proof(session, upload).is_none() {
        return Ok(());
    }
    let dir = upload_dir(session, upload).ok_or_else(refused)?;
    crate::agent_tools::write_private(&dir.join(CONSUMED), &[])
        .map_err(|e| RpcError::internal(format!("cannot claim Web upload: {e}")))
}

/// Read-only provenance attached by resolution, scoped to this one finished file.
pub(crate) fn resolved_proof(session: &str, upload: &str, name: &str) -> Option<Value> {
    Some(json!({"uploadId": upload, "fileName": name, "proof": proof(session, upload)?}))
}

pub(crate) fn verifies_resolved(session: &str, block: &Value) -> bool {
    let Some(reference) = block.pointer("/_meta/acpmux/webUpload") else { return false };
    let Some(upload) = reference.get("uploadId").and_then(Value::as_str) else { return false };
    let Some(name) = reference.get("fileName").and_then(Value::as_str) else { return false };
    let Some(expected) = proof(session, upload) else { return false };
    let Some(path) = finished_path(session, upload, name) else { return false };
    let uri = reqwest::Url::from_file_path(&path).ok().map(String::from);
    reference
        .get("proof")
        .and_then(Value::as_str)
        .is_some_and(|provided| cmux_local_auth::tokens_match(provided, &expected))
        && block.get("type").and_then(Value::as_str) == Some("resource_link")
        && block.pointer("/_meta/acpmux/uploadPath").and_then(Value::as_str) == path.to_str()
        && block.get("uri").and_then(Value::as_str) == uri.as_deref()
}

fn start(session: &str, params: &Value) -> Result<Value, RpcError> {
    if params.get("forPrompt") != Some(&Value::Bool(true)) {
        return Err(refused());
    }
    let answer = begin(session, params)?;
    let upload = answer.get("uploadId").and_then(Value::as_str).ok_or_else(refused)?;
    let dir = upload_dir(session, upload).ok_or_else(refused)?;
    let result = (|| {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes)
            .map_err(|e| RpcError::internal(format!("the OS random generator: {e}")))?;
        let proof: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        crate::agent_tools::write_private(&dir.join(WEB_PROOF), proof.as_bytes())
            .map_err(|e| RpcError::internal(format!("cannot record Web upload: {e}")))
    })();
    if let Err(error) = result {
        remove_uploads(&[dir]);
        return Err(error);
    }
    Ok(answer)
}

/// Called only after routing, with Web control derived from the authenticated
/// connection (including a peer's preserved `via: web`), never from a client flag.
pub(crate) async fn handle(
    hub: &super::super::Hub,
    method: &str,
    mut params: Value,
) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    let method = method.to_owned();
    params.set("sessionId", json!(id));
    let answer = tokio::task::spawn_blocking(move || {
        if method == method::MUX_FILE_PUT_BEGIN {
            return start(&id, &params);
        }
        let upload = params.get("uploadId").and_then(Value::as_str).ok_or_else(refused)?;
        let token = params.get("ownerToken").and_then(Value::as_str).ok_or_else(refused)?;
        if !owns(&id, upload, token) {
            return Err(refused());
        }
        let dir = upload_dir(&id, upload).ok_or_else(refused)?;
        if matches!(method.as_str(), method::MUX_FILE_PUT_CHUNK | method::MUX_FILE_PUT_FINISH)
            && dir.join(CONSUMED).exists()
        {
            return Err(refused());
        }
        match method.as_str() {
            method::MUX_FILE_PUT_CHUNK => chunk(&params),
            method::MUX_FILE_PUT_FINISH => finish(&id, &params),
            method::MUX_FILE_PUT_STATUS => status(&id, &params),
            method::MUX_FILE_PUT_CANCEL => {
                // `resolve` marks consumed under this lock before giving the file to
                // a prompt. A delayed cleanup after a lost acceptance receipt
                // cannot delete it. The age sweep retains its existing policy.
                let _used = IN_USE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let dir = upload_dir(&id, upload).ok_or_else(refused)?;
                if !dir.join(CONSUMED).exists() {
                    let _held = hold(upload);
                    let _ = std::fs::remove_dir_all(dir);
                }
                Ok(json!({}))
            }
            _ => Err(refused()),
        }
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    reject_purged(&session).await?;
    answer
}
