//! The app's device channel, `share-host/device.sock`: this Mac's one hub device, lent to the
//! app in the JSON lines the cmux Remote Screen Sharing worker speaks (the app's
//! `CmuxRemoteDevices` and `RemoteDeviceChannel`), so the app signs, opens relay secrets and
//! hears pushes as the daemon's device. Only this user's processes connect (the kernel's peer
//! uid). Requests are `{"id":N,"method":M,"params":{..}}`; answers `{"id":N,"ok":true,
//! "result":{..}}` or `{"id":N,"ok":false,"error":{"message":..}}`; a subscribed channel also
//! gets `{"event":"push","text":"<push json>"}`.

use super::state::Shared;
use cmux_hub_host::b64;
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{Arc, PoisonError};
use tokio_util::codec::{Framed, LinesCodec};

/// The longest request line (a relay blob to open is far smaller).
const MAX_LINE: usize = 1 << 20;

/// What one request does to its channel besides the answer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum After {
    Nothing,
    /// `hub.subscribe`: the channel gets every push from now on.
    Subscribe,
}

/// The answer to one request line.
pub(crate) fn answer(shared: &Shared, line: &str) -> (Value, After) {
    let Ok(request) = serde_json::from_str::<Value>(line) else {
        return (json!({"ok": false, "error": {"message": "not a JSON request"}}), After::Nothing);
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request.get("method").and_then(Value::as_str).unwrap_or_default();
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    match method_result(shared, method, &params) {
        Ok((result, after)) => (json!({"id": id, "ok": true, "result": result}), after),
        Err(message) => {
            (json!({"id": id, "ok": false, "error": {"message": message}}), After::Nothing)
        }
    }
}

fn method_result(shared: &Shared, method: &str, params: &Value) -> Result<(Value, After), String> {
    let text = |key: &str| params.get(key).and_then(Value::as_str);
    let bytes =
        |key: &str| text(key).and_then(b64::decode).ok_or_else(|| format!("{key} is not base64"));
    let hub = shared.hub();
    let done = |result: Value| Ok((result, After::Nothing));
    match method {
        // This device is the daemon's: its registration (and a new identity when the hub
        // refused the old one) is the daemon's too, so a renewal answers the identity it holds.
        "device.identity" | "device.renew" => {
            let signing = hub.device.signer().map_err(|e| e.to_string())?.public_key();
            let agreement = hub.device.agreement_key().map_err(|e| e.to_string())?;
            let mut result = json!({"id": hub.device.id, "signing_key": signing,
                                    "agreement_key": agreement});
            // The account the daemon signed in as: the app uses this device only for its own.
            if let (Some(user), Some(fields)) = (hub.user_id(), result.as_object_mut()) {
                fields.insert("user_id".into(), Value::String(user));
            }
            done(result)
        }
        "device.sign" => {
            let signature = hub.sign(&bytes("message")?).map_err(|e| e.to_string())?;
            done(json!({"signature": b64::encode(&signature)}))
        }
        "device.open" => {
            let plaintext = hub
                .device
                .open_sealed(&bytes("ciphertext")?, &bytes("encapsulated_key")?, &bytes("info")?)
                .map_err(|e| e.to_string())?;
            done(json!({"plaintext": b64::encode(&plaintext)}))
        }
        "hub.subscribe" => Ok((json!({}), After::Subscribe)),
        // The app's settings for the worker: accepted, and shown by `share-host status`.
        "host.mode" | "consent" | "hub.anchored" | "hub.signed_out" => {
            let mut app = shared.app.lock().unwrap_or_else(PoisonError::into_inner);
            match method {
                "host.mode" => app.host_mode = params.get("mode").cloned(),
                "consent" => app.consent = Some(params.clone()),
                "hub.anchored" => {
                    app.anchored = Some(params.clone());
                    app.signed_out = false;
                }
                _ => app.signed_out = true,
            }
            done(json!({}))
        }
        _ => Err(format!("unknown method {}", cmux_hub_host::printable(method))),
    }
}

/// Serves the channel at `path` until the daemon stops.
pub(crate) async fn serve(shared: Arc<Shared>, path: PathBuf) {
    if let Err(e) = serve_at(shared, &path).await {
        tracing::warn!("{}: the device channel stopped: {e}", super::LOG);
    }
}

async fn serve_at(shared: Arc<Shared>, path: &std::path::Path) -> anyhow::Result<()> {
    use std::os::unix::fs::FileTypeExt;
    if let Some(parent) = path.parent() {
        cmux_hub_host::identity::private_dir(parent).map_err(|e| anyhow::anyhow!("{e}"))?;
    }
    // A socket left by an earlier daemon; anything else at the path is not ours to remove. Read,
    // removed and narrowed in the held home (`home_fs`), never a replacement at the same path.
    if crate::home_fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_socket()) {
        crate::home_fs::remove_file(path)?;
    }
    let listener = tokio::net::UnixListener::bind(path)?;
    crate::home_fs::set_mode(path, 0o600)?;
    // SAFETY: geteuid has no preconditions.
    let me = unsafe { libc::geteuid() };
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                if stream.peer_cred().map(|c| c.uid()).ok() != Some(me) {
                    continue;
                }
                connections.spawn(connection(shared.clone(), stream));
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
}

/// One app connection: answers its requests in order and, once subscribed, sends it pushes.
async fn connection(shared: Arc<Shared>, stream: tokio::net::UnixStream) {
    let mut framed = Framed::new(stream, LinesCodec::new_with_max_length(MAX_LINE));
    let (sender, mut pushes) = tokio::sync::mpsc::unbounded_channel::<String>();
    let mut sender = Some(sender);
    loop {
        tokio::select! {
            line = framed.next() => {
                let Some(Ok(line)) = line else { return };
                let (reply, after) = answer(&shared, &line);
                if framed.send(reply.to_string()).await.is_err() {
                    return;
                }
                if after == After::Subscribe
                    && let Some(sender) = sender.take()
                {
                    shared.subscribe(sender);
                }
            }
            Some(push) = pushes.recv() => {
                if framed.send(push).await.is_err() {
                    return;
                }
            }
        }
    }
}
