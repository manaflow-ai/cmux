//! Read-only binding of a local sidecar to its supervisor-owned mux socket.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::net::UnixStream;

use super::{AdminError, AdminRequest, call_admin_over_stream, verify_unix_peer_owner};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MuxBinding {
    pub mux_socket: PathBuf,
    pub link_socket: PathBuf,
}

impl MuxBinding {
    pub fn new(mux_socket: &Path, link_socket: &Path) -> std::io::Result<Self> {
        Ok(Self {
            mux_socket: std::fs::canonicalize(mux_socket)
                .or_else(|_| std::path::absolute(mux_socket))?,
            link_socket: std::path::absolute(link_socket)?,
        })
    }
}

/// Verify the live configuration through the same process as the already-open
/// link. The caller keeps that link for its relay; it must not reconnect by path
/// after this check. Older sidecars without this read are refused only when the
/// caller explicitly selected a mux destination.
pub async fn verify_mux_binding(
    link: &UnixStream,
    admin_path: &Path,
    expected_link: &Path,
    expected_mux: &Path,
) -> Result<(), AdminError> {
    verify_unix_peer_owner(link)?;
    // This probe belongs inside the caller's binding deadline too: a stale
    // pathname or a full accept queue must not hang explicit attachment.
    let owner = UnixStream::connect(expected_mux).await?;
    verify_unix_peer_owner(&owner)?;
    let admin = UnixStream::connect(admin_path).await?;
    verify_unix_peer_owner(&admin)?;
    let peer_pid = link.peer_cred()?.pid();
    if peer_pid.is_none() || peer_pid != admin.peer_cred()?.pid() {
        return Err(AdminError::Protocol("mux binding responder is not the link process".into()));
    }
    let response = call_admin_over_stream(admin, &AdminRequest::MuxBinding).await?;
    if !response.ok {
        return Err(AdminError::Protocol("running sidecar cannot prove its mux binding".into()));
    }
    let binding: MuxBinding =
        serde_json::from_value(response.result.ok_or_else(|| {
            AdminError::Protocol("running sidecar omitted its mux binding".into())
        })?)?;
    if std::fs::canonicalize(&binding.mux_socket)? != std::fs::canonicalize(expected_mux)?
        || std::fs::canonicalize(&binding.link_socket)? != std::fs::canonicalize(expected_link)?
    {
        return Err(AdminError::Protocol(
            "running sidecar serves a different mux destination".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
