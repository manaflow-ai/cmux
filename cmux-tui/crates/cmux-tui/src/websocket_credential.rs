//! The credential file of a daemon's loopback WebSocket listener
//! (cx-hnmbt.2, spec/transports.md "App listener and page files").
//!
//! A headless daemon whose loopback listener has no configured token mints
//! one and writes `<socket>.websocket.json` (mode 0600, in the socket's
//! user-only directory): `{"version":1,"url":"ws://127.0.0.1:<port>/",
//! "pages":"http://127.0.0.1:<port>/pages/","token":"…","pid":<pid>}`. A
//! same-user host (the cmux app) reads it; the token never goes on argv, in
//! the environment or in a log. The file goes away with its daemon.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

/// Pairs a bound listener with its credential file: written only for a
/// `minted` token (a configured one is the person's own), removed with the
/// returned value. A write failure is logged; the listener still serves.
pub(crate) fn attach(
    server: cmux_tui_core::server::WebSocketServer,
    socket: &Path,
    minted: bool,
    token: &Option<String>,
) -> (cmux_tui_core::server::WebSocketServer, Option<CredentialFile>) {
    let file = token.as_deref().filter(|_| minted).and_then(|token| {
        write(socket, server.local_addr(), token)
            .map_err(|error| {
                crate::client_log::stderr_log!("startup", "{BIN}: {error}");
            })
            .ok()
    });
    (server, file)
}

/// A fresh 256-bit credential, hex encoded.
pub(crate) fn mint_token() -> anyhow::Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("cannot mint a WebSocket credential: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// `<socket>.websocket.json`, next to the socket.
pub(crate) fn path_for(socket: &Path) -> PathBuf {
    let mut name = socket.file_name().unwrap_or_default().to_os_string();
    name.push(".websocket.json");
    socket.with_file_name(name)
}

/// The written file; dropping it removes the file while it is still this
/// process's (a successor daemon may have replaced it).
pub(crate) struct CredentialFile {
    path: PathBuf,
}

/// Writes the file atomically (a private temporary file, then a rename), so
/// a reader never sees a partial file or a wider mode.
pub(crate) fn write(
    socket: &Path,
    addr: SocketAddr,
    token: &str,
) -> anyhow::Result<CredentialFile> {
    let path = path_for(socket);
    let value = serde_json::json!({
        "version": 1,
        "url": format!("ws://{addr}/"),
        "pages": format!("http://{addr}/pages/"),
        "token": token,
        "pid": std::process::id(),
    });
    let mut temporary = path.clone().into_os_string();
    temporary.push(format!(".{}.tmp", std::process::id()));
    let temporary = PathBuf::from(temporary);
    let _ = cmux_blocking::fs::remove_file(&temporary);
    let result = (|| -> std::io::Result<()> {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = crate::blocking::fs::open_with(&options, &temporary)?;
        file.write_all(value.to_string().as_bytes())?;
        crate::blocking::fs::sync_all(&file)?;
        cmux_blocking::fs::rename(&temporary, &path)
    })();
    if let Err(error) = result {
        let _ = cmux_blocking::fs::remove_file(&temporary);
        anyhow::bail!("cannot write the WebSocket credential file {}: {error}", path.display());
    }
    Ok(CredentialFile { path })
}

impl Drop for CredentialFile {
    fn drop(&mut self) {
        let ours = cmux_blocking::fs::read(&self.path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .is_some_and(|value| value["pid"].as_u64() == Some(u64::from(std::process::id())));
        if ours {
            let _ = cmux_blocking::fs::remove_file(&self.path);
        }
    }
}
