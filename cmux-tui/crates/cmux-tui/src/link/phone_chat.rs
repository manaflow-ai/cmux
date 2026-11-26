//! The `phone_chat` service: the owner's phone chats with this Cloud machine
//! directly, the Mac off (RFD 0135 gate 4).
//!
//! Leo: "Ok well we can't be letting important rfds like that take breaks
//! unless I put in fleet wide pauses, esp when this is stuff that materially
//! improves the app".
//!
//! Until now a phone reached a Cloud chat only through hostd on the person's
//! Mac (`cmux-mobile-host` `cloud-acpmux`), so the chat was gone when the Mac
//! slept. This serves the same thing on the machine's own link, with the same
//! code (`cmux_cloud_phone_acp`):
//!
//! - Only the server's owner (`OwnerSession::authorize`, as `owner_session`);
//!   every other paired peer is refused before a byte reaches the daemon.
//! - The link connects to the daemon's local socket (same uid as this link),
//!   and the mobile handshake marks the connection `cloud-mobile-chat-v1`, so
//!   the daemon holds it to the phone floor (`cmux-tui-core`
//!   `server/phone_carrier.rs`, Unix clients only): the phone reaches the
//!   chat commands and nothing else, whatever the adapter sends.
//! - Before that handshake the link stamps the stream with the phone it just
//!   admitted (`cmux_link::owner_phone`); the daemon's Cloud mobile prompts
//!   carry it to acpmux, which treats it as the owner's own phone under D13
//!   (it may send to a Claude chat this machine started), never with Full
//!   access (`acpmux` `server/remote_guard.rs`).
//! - The phone speaks ACP as newline JSON on the stream; the adapter turns it
//!   into those commands and the daemon's replies back into ACP.

use std::path::Path;
use std::time::Duration;

use cmux_cloud_phone_acp::{Adapter, Effects, Fault, handshake, read_line};
use cmux_link::owner_session::{OwnerRefused, OwnerSession};
use cmux_link::stamp::LinkPeer;
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

use super::inbound::{InboundRefused, connect_same_uid};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

/// Serve one phone chat stream from `peer` until either side ends.
pub(super) async fn serve<S>(
    stream: S,
    peer: &LinkPeer,
    owner: Option<&OwnerSession>,
    session_socket: Option<&Path>,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let owner = owner.ok_or(InboundRefused::Owner(OwnerRefused::NotConfigured))?;
    owner.authorize(peer).map_err(InboundRefused::Owner)?;
    let socket = session_socket.ok_or(InboundRefused::EntryUnavailable)?;
    let daemon = connect_same_uid(socket, cmux_tui_core::platform::effective_uid()).await?;
    let (native_read, mut native_write) = daemon.into_split();
    let mut native_read = BufReader::new(native_read);
    let handshakes = async {
        stamp_owner_phone(&mut native_read, &mut native_write, &peer.install).await?;
        handshake(&mut native_read, &mut native_write).await
    };
    tokio::time::timeout(HANDSHAKE_TIMEOUT, handshakes)
        .await
        .map_err(|_| {
            InboundRefused::PhoneCarrier(Fault {
                code: "timeout",
                message: "Cloud carrier handshake timed out".into(),
            })
        })?
        .map_err(InboundRefused::PhoneCarrier)?;

    let (phone_read, mut phone_write) = tokio::io::split(stream);
    let mut phone_read = BufReader::new(phone_read);
    let (mut phone_line, mut native_line) = (Vec::new(), Vec::new());
    let mut adapter = Adapter::new(owner.owner_user.clone(), owner.owner_team.clone());
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let served = async {
        loop {
            let effects = tokio::select! {
                // The phone closing its side ends the chat.
                line = read_line(&mut phone_read, &mut phone_line) => {
                    let Ok(line) = line else { break };
                    let request: Value = serde_json::from_slice(&line)
                        .map_err(|_| refused("bad_request", "phone ACP frame is not JSON"))?;
                    adapter.phone(request).map_err(|_| refused("bad_request", "phone ACP request refused"))?
                }
                line = read_line(&mut native_read, &mut native_line) => {
                    let response: Value = serde_json::from_slice(&line.map_err(InboundRefused::PhoneCarrier)?)
                        .map_err(|_| refused("unavailable", "Cloud carrier returned invalid JSON"))?;
                    adapter.native(response).map_err(|_| refused("unavailable", "Cloud native reply refused"))?
                }
                _ = tick.tick() => adapter.expire(),
            };
            if apply(&mut native_write, &mut phone_write, effects).await.is_err() {
                break;
            }
        }
        Ok::<(), InboundRefused>(())
    }
    .await;
    // However the stream ended, a start still in flight closes its empty tab
    // on the machine (best effort).
    let _ = apply(&mut native_write, &mut phone_write, adapter.abandon()).await;
    let _ = phone_write.shutdown().await;
    served
}

/// Stamp the daemon stream with the phone the owner check admitted; any answer but its `ok`
/// refuses the chat (a daemon without the stamp would hold the phone at D13 anyway).
async fn stamp_owner_phone<R, W>(read: &mut R, write: &mut W, device: &str) -> Result<(), Fault>
where
    R: tokio::io::AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let closed = |_| Fault { code: "unavailable", message: "Cloud carrier closed".into() };
    let mut line = cmux_link::owner_phone::line(device).into_bytes();
    line.push(b'\n');
    write.write_all(&line).await.map_err(closed)?;
    write.flush().await.map_err(closed)?;
    let bytes = read_line(read, &mut Vec::new()).await?;
    let reply: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    if reply["id"] != cmux_link::owner_phone::REQUEST_ID || reply["ok"] != Value::Bool(true) {
        return Err(Fault {
            code: "forbidden",
            message: "Cloud carrier refused the phone's stamp".into(),
        });
    }
    Ok(())
}

fn refused(code: &'static str, message: &str) -> InboundRefused {
    InboundRefused::PhoneCarrier(Fault { code, message: message.to_owned() })
}

async fn apply<N, P>(native: &mut N, phone: &mut P, effects: Effects) -> std::io::Result<()>
where
    N: AsyncWrite + Unpin,
    P: AsyncWrite + Unpin,
{
    send(native, effects.to_native).await?;
    send(phone, effects.to_phone).await
}

/// `values` as newline JSON, in one write.
async fn send<W: AsyncWrite + Unpin>(out: &mut W, values: Vec<Value>) -> std::io::Result<()> {
    if values.is_empty() {
        return Ok(());
    }
    let mut bytes = Vec::new();
    for value in values {
        serde_json::to_writer(&mut bytes, &value)?;
        bytes.push(b'\n');
    }
    out.write_all(&bytes).await?;
    out.flush().await
}
