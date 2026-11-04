//! Where an MCP connection's secret lives (plans/cmux-next/mcp-connect-DESIGN.md section 5): the
//! person's key, or the OAuth tokens and client id. Never in the connection record, a session's
//! MCP config, argv, an agent's env, a log, the transcript or the audit log.
//!
//! - macOS: the login keychain, a generic password with service `cmux.mcp` and account
//!   `<home id>/<connection id>`, written through Security.framework by this binary, so the
//!   item's access list is acpmux itself (threat model T6), not `/usr/bin/security`.
//! - Elsewhere: `<home>/mcp/secrets/<connection id>.json`, 0600 in a 0700 folder.
//! - A daemon whose store is in memory (tests) keeps them in memory.
//!
//! Errors are codes, never values.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex as StdMutex;
use zeroize::Zeroizing;

/// The keychain service of every MCP connection secret.
#[cfg(target_os = "macos")]
pub const SERVICE: &str = "cmux.mcp";

pub(crate) enum McpSecrets {
    /// The login keychain, items named by `home` (the daemon home's id) and the connection id.
    #[cfg(target_os = "macos")]
    Keychain { home: String },
    /// One 0600 file per connection in a 0700 folder.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    Files { dir: PathBuf },
    /// A daemon with a memory store.
    Memory(StdMutex<HashMap<String, Zeroizing<String>>>),
}

/// True when `id` is a connection id this module makes (`mcp_` and 16 hex digits).
pub(crate) fn plain_id(id: &str) -> bool {
    id.strip_prefix("mcp_").is_some_and(|hex| {
        hex.len() == 16 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

impl McpSecrets {
    /// The store for a daemon home: the keychain on macOS, files elsewhere.
    pub(crate) fn for_home(home: &std::path::Path) -> Self {
        #[cfg(target_os = "macos")]
        {
            Self::Keychain { home: crate::vault::store::home_id(home) }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self::Files { dir: home.join("mcp").join("secrets") }
        }
    }

    pub(crate) fn memory() -> Self {
        Self::Memory(StdMutex::new(HashMap::new()))
    }

    /// `keychain`, `file` or `memory`: shown in Settings, never a value.
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { .. } => "keychain",
            Self::Files { .. } => "file",
            Self::Memory(_) => "memory",
        }
    }

    pub(crate) fn put(&self, id: &str, value: &str) -> Result<(), &'static str> {
        if !plain_id(id) {
            return Err("mcp.secret_bad_id");
        }
        match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { home } => security_framework::passwords::set_generic_password(
                SERVICE,
                &format!("{home}/{id}"),
                value.as_bytes(),
            )
            .map_err(|_| "mcp.secret_store_write_failed"),
            Self::Files { dir } => write_file(dir, id, value),
            Self::Memory(map) => {
                map.lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id.to_owned(), Zeroizing::new(value.to_owned()));
                Ok(())
            }
        }
    }

    pub(crate) fn get(&self, id: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        if !plain_id(id) {
            return Err("mcp.secret_bad_id");
        }
        match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { home } => {
                match security_framework::passwords::get_generic_password(
                    SERVICE,
                    &format!("{home}/{id}"),
                ) {
                    Ok(bytes) => {
                        let bytes = Zeroizing::new(bytes);
                        std::str::from_utf8(&bytes)
                            .map(|t| Some(Zeroizing::new(t.to_owned())))
                            .map_err(|_| "mcp.secret_store_read_failed")
                    }
                    // errSecItemNotFound
                    Err(e) if e.code() == -25300 => Ok(None),
                    Err(_) => Err("mcp.secret_store_read_failed"),
                }
            }
            Self::Files { dir } => match std::fs::read_to_string(dir.join(format!("{id}.json"))) {
                Ok(text) => Ok(Some(Zeroizing::new(text))),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(_) => Err("mcp.secret_store_read_failed"),
            },
            Self::Memory(map) => Ok(map.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()),
        }
    }

    /// Ok when the item is gone (or was never there).
    pub(crate) fn delete(&self, id: &str) -> Result<(), &'static str> {
        if !plain_id(id) {
            return Err("mcp.secret_bad_id");
        }
        match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { home } => {
                match security_framework::passwords::delete_generic_password(
                    SERVICE,
                    &format!("{home}/{id}"),
                ) {
                    Ok(()) => Ok(()),
                    Err(e) if e.code() == -25300 => Ok(()),
                    Err(_) => Err("mcp.secret_store_delete_failed"),
                }
            }
            Self::Files { dir } => match std::fs::remove_file(dir.join(format!("{id}.json"))) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(_) => Err("mcp.secret_store_delete_failed"),
            },
            Self::Memory(map) => {
                map.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
                Ok(())
            }
        }
    }
}

/// Writes `value` to `<dir>/<id>.json`, 0600, through a temporary file renamed into place.
fn write_file(dir: &std::path::Path, id: &str, value: &str) -> Result<(), &'static str> {
    use std::io::Write as _;
    #[cfg(unix)]
    use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    builder.mode(0o700);
    builder.create(dir).map_err(|_| "mcp.secret_store_write_failed")?;
    #[cfg(unix)]
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|_| "mcp.secret_store_write_failed")?;
    let tmp = dir.join(format!("{id}.json.tmp"));
    let _ = std::fs::remove_file(&tmp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let written = (|| -> std::io::Result<()> {
        let mut file = options.open(&tmp)?;
        file.write_all(value.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, dir.join(format!("{id}.json")))
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
        return Err("mcp.secret_store_write_failed");
    }
    Ok(())
}

/// A connection's stored secret, read for one call: a sign-in's access token, refresh token and
/// expiry, or a key. Its strings are wiped when it drops; unknown fields are ignored.
#[derive(Default, serde::Deserialize)]
// Field-level defaults: a container `default` moves fields out of `Self::default()`, which a
// `Drop` type refuses (E0509).
#[serde(rename_all = "camelCase")]
pub(crate) struct StoredSecret {
    #[serde(default)]
    pub(crate) access_token: Option<String>,
    #[serde(default)]
    pub(crate) refresh_token: Option<String>,
    #[serde(default)]
    pub(crate) key: Option<String>,
    #[serde(default)]
    pub(crate) expires_at: Option<u64>,
}

impl StoredSecret {
    /// The stored JSON's fields; empty when it does not parse.
    pub(crate) fn parse(secret: &str) -> Self {
        serde_json::from_str(secret).unwrap_or_default()
    }
}

impl Drop for StoredSecret {
    fn drop(&mut self) {
        use zeroize::Zeroize as _;
        self.access_token.zeroize();
        self.refresh_token.zeroize();
        self.key.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mcp_connect_secret_files_are_owner_only_and_ids_are_plain() {
        let dir = std::env::temp_dir().join(format!("acpmux-mcp-secrets-{}", std::process::id()));
        let store = McpSecrets::Files { dir: dir.clone() };
        let id = "mcp_0123456789abcdef";
        store.put(id, r#"{"key":"k-1"}"#).unwrap();
        assert_eq!(store.get(id).unwrap().as_deref().map(String::as_str), Some(r#"{"key":"k-1"}"#));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode =
                |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&dir), 0o700);
            assert_eq!(mode(&dir.join(format!("{id}.json"))), 0o600);
        }
        store.put(id, r#"{"key":"k-2"}"#).unwrap();
        assert_eq!(store.get(id).unwrap().as_deref().map(String::as_str), Some(r#"{"key":"k-2"}"#));
        store.delete(id).unwrap();
        assert!(store.get(id).unwrap().is_none());
        store.delete(id).unwrap();
        for bad in ["../x", "mcp_../../etc", "mcp_0123", "MCP_0123456789ABCDEF"] {
            assert_eq!(store.put(bad, "v"), Err("mcp.secret_bad_id"), "{bad}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
