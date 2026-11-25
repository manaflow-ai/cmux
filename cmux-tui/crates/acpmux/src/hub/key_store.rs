//! "Keep as key NAME" on a chat's `request_secret` card (`secrets.rs`, docs/design/safe-keys.md):
//! where the person's value goes when they keep it. The key store is cmux's (`cmux keys`, the
//! cmux-tui crate's `cli/key_broker/local.rs`): the OS secret store's item `key.NAME` and the audit
//! in `~/.config/cmux/keys.json`, never a value there. This daemon reaches it as Settings > Keys
//! does, through the CLI with the value on stdin, so the store keeps one writer of its audit.

use super::secrets::MASK;
use serde_json::Value;
use std::time::Duration;
use zeroize::Zeroizing;

/// A card's value the person chose to keep as key `name`.
pub struct KeepAsk {
    pub name: String,
    pub value: Zeroizing<String>,
    /// The card's reason, the key's purpose.
    pub purpose: String,
    /// The chat that asked (`--asked-by`).
    pub asked_by: String,
}

/// The key store "keep as key" saves into: the person's keys (`cmux keys`, docs/design/safe-keys.md).
/// A trait so tests keep values in memory.
pub trait KeyStore: Send + Sync {
    /// Stores `ask.value` as key `ask.name`, replacing an older value of that name. The error is
    /// what the person reads; it never holds the value.
    fn keep(&self, ask: &KeepAsk) -> Result<(), String>;
}

/// The key store's CLI: the app's bundled `cmux` (`CMUX_BUNDLED_CLI_PATH`), else `cmux` on the
/// login PATH, run as `cmux keys put NAME --purpose TEXT --replace --from-person --asked-by CHAT
/// --json` with the value on stdin, as Settings > Keys stores a pasted key.
pub struct CliKeyStore;

/// The longest purpose `cmux keys put` takes.
const MAX_PURPOSE_CHARS: usize = 300;
/// How long `cmux keys put` may take (the OS store can prompt), as Settings > Keys waits.
const KEEP_TIMEOUT: Duration = Duration::from_secs(60);

impl KeyStore for CliKeyStore {
    fn keep(&self, ask: &KeepAsk) -> Result<(), String> {
        use std::io::{Read as _, Write as _};
        let cli = std::env::var_os(crate::login_env::BUNDLED_CLI_ENV)
            .map(std::path::PathBuf::from)
            .filter(|path| path.is_absolute() && path.is_file())
            .unwrap_or_else(|| std::path::PathBuf::from("cmux"));
        let purpose: String = ask.purpose.chars().take(MAX_PURPOSE_CHARS).collect();
        let mut command = cmux_process::Command::new(&cli);
        command.args(["keys", "put", &ask.name]);
        if !purpose.trim().is_empty() {
            command.args(["--purpose", &purpose]);
        }
        command
            .args(["--replace", "--from-person", "--asked-by", &ask.asked_by, "--json"])
            .stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::piped());
        if let Some(path) = crate::login_env::path() {
            command.env("PATH", path);
        }
        let mut child = command
            .spawn()
            .map_err(|e| format!("could not run {} (the cmux keys store): {e}", cli.display()))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(ask.value.as_bytes())
                .map_err(|e| format!("could not hand the key to cmux keys: {e}"))?;
        }
        let status = match child.wait_timeout(KEEP_TIMEOUT) {
            Ok(Some(status)) => status,
            Ok(None) => {
                let _ = child.kill();
                return Err(format!(
                    "cmux keys put {} gave no answer in {}s",
                    ask.name,
                    KEEP_TIMEOUT.as_secs()
                ));
            }
            Err(e) => return Err(format!("cmux keys put: {e}")),
        };
        if status.success() {
            return Ok(());
        }
        let mut stderr = Vec::new();
        if let Some(pipe) = child.stderr.take() {
            let _ = pipe.take(16 * 1024).read_to_end(&mut stderr);
        }
        let out = std::process::Output { status, stdout: Vec::new(), stderr };
        let said = String::from_utf8_lossy(&out.stderr);
        let message = serde_json::from_str::<Value>(said.trim())
            .ok()
            .and_then(|v| v.pointer("/error/message").or_else(|| v.get("message")).cloned())
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_else(|| said.trim().to_owned());
        // Never the value, whatever the CLI printed.
        let message = message.replace(ask.value.as_str(), MASK);
        Err(format!("cmux keys put {} failed ({}): {message}", ask.name, out.status))
    }
}
