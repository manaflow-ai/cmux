//! The OS secret store that holds vault env values: the macOS Keychain
//! (`/usr/bin/security`) or the Secret Service (`secret-tool`) on Linux. Item
//! service `cmux-vault`, account `env/<NAME>`. There is no file fallback: a
//! machine without either refuses to store env values.
//!
//! A value never goes into argv, a log or an error: it is written to the
//! store command's stdin (`harness_secret::store_item`), base64-encoded so
//! any UTF-8 value (line breaks included) is one printable word, and read
//! back from the command's output into a zeroed buffer.

use base64::Engine as _;
use std::process::{Command, Stdio};
use std::time::Duration;
use wait_timeout::ChildExt;
use zeroize::Zeroizing;

/// The secret store service every vault item uses.
pub const SERVICE: &str = "cmux-vault";
/// The code of a machine with no OS secret store.
pub const UNAVAILABLE: &str = "vault.secret_store_unavailable";
const TIMEOUT: Duration = Duration::from_secs(10);

pub fn account(name: &str) -> String {
    format!("env/{name}")
}

/// Where values go. The OS store in the product; a map in tests.
pub trait SecretStore: Send + Sync {
    /// `keychain`, `secret-service` or `unavailable`.
    fn kind(&self) -> &'static str;
    fn available(&self) -> bool {
        self.kind() != "unavailable"
    }
    /// Errors are codes, never values.
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str>;
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str>;
    /// Ok when the item is gone (or was never there).
    fn delete(&self, name: &str) -> Result<(), &'static str>;
}

/// The OS store of this machine.
pub struct OsStore;

impl OsStore {
    fn os() -> &'static str {
        if cfg!(target_os = "macos") {
            "macos"
        } else if cfg!(target_os = "linux") {
            "linux"
        } else {
            "other"
        }
    }
}

/// `secret-tool` on PATH and a session bus to reach the Secret Service.
fn secret_tool_usable() -> bool {
    let bus = std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some()
        || std::env::var_os("XDG_RUNTIME_DIR")
            .is_some_and(|dir| std::path::Path::new(&dir).join("bus").exists());
    let on_path = std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| dir.join("secret-tool").is_file())
    });
    bus && on_path
}

impl SecretStore for OsStore {
    fn kind(&self) -> &'static str {
        match Self::os() {
            "macos" if std::path::Path::new("/usr/bin/security").exists() => "keychain",
            "linux" if secret_tool_usable() => "secret-service",
            _ => "unavailable",
        }
    }

    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        if !self.available() {
            return Err(UNAVAILABLE);
        }
        let encoded =
            Zeroizing::new(base64::engine::general_purpose::STANDARD.encode(value.as_bytes()));
        let cmd = crate::cli::harness_secret::store_item(
            Self::os(),
            SERVICE,
            &account(name),
            &format!("cmux vault {name}"),
            &encoded,
        )
        .map_err(|_| "vault.env_value_refused")?;
        crate::cli::harness_secret::run_store(&cmd).map_err(|_| "vault.secret_store_write_failed")
    }

    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        if !self.available() {
            return Err(UNAVAILABLE);
        }
        let account = account(name);
        let macos = Self::os() == "macos";
        let cmd = if macos {
            let mut c = Command::new("/usr/bin/security");
            // -g: the password on stderr (`0x` hex for non-ASCII), never in argv.
            c.args(["find-generic-password", "-s", SERVICE, "-a", &account, "-g"]);
            c.stdout(Stdio::null()).stderr(Stdio::piped());
            c
        } else {
            let mut c = Command::new("secret-tool");
            c.args(["lookup", "service", SERVICE, "account", &account]);
            c.stdout(Stdio::piped()).stderr(Stdio::null());
            c
        };
        let (status, raw) = capture(cmd, macos)?;
        if !status.success() {
            // `security` exits 44 for a missing item (any other exit, a locked
            // keychain say, is an error to retry); `secret-tool` exits 1 with no output.
            return if macos && status.code() != Some(44) {
                Err("vault.secret_store_read_failed")
            } else {
                Ok(None)
            };
        }
        let text = Zeroizing::new(String::from_utf8_lossy(&raw).into_owned());
        let encoded = if macos {
            Zeroizing::new(
                crate::config::profiles::parse_security_password(&text)
                    .ok_or("vault.secret_store_read_failed")?,
            )
        } else {
            Zeroizing::new(text.trim_end_matches(['\n', '\r']).to_owned())
        };
        decode(&encoded).map(Some).ok_or("vault.secret_store_read_failed")
    }

    fn delete(&self, name: &str) -> Result<(), &'static str> {
        if !self.available() {
            // Not proof that the item is gone (a Linux shell without the
            // desktop session's bus): the caller keeps its cleanup record.
            return Err(UNAVAILABLE);
        }
        let account = account(name);
        let mut cmd = if Self::os() == "macos" {
            let mut c = Command::new("/usr/bin/security");
            c.args(["delete-generic-password", "-s", SERVICE, "-a", &account]);
            c
        } else {
            let mut c = Command::new("secret-tool");
            c.args(["clear", "service", SERVICE, "account", &account]);
            c
        };
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        let mut child = cmd.spawn().map_err(|_| UNAVAILABLE)?;
        match child.wait_timeout(TIMEOUT) {
            Ok(Some(status)) if status.success() => Ok(()),
            // `security` exits 44 when no such item exists: already gone.
            Ok(Some(status)) if status.code() == Some(44) => Ok(()),
            Ok(Some(_)) => Err("vault.secret_store_delete_failed"),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                Err("vault.secret_store_timeout")
            }
        }
    }
}

/// Run `cmd` with stdin closed and read its stderr (`from_stderr`) or stdout
/// while waiting, bounded by the store timeout: a large item fills the pipe
/// before the command exits, so reading only after the exit would stall it.
pub fn capture(
    mut cmd: Command,
    from_stderr: bool,
) -> Result<(std::process::ExitStatus, Zeroizing<Vec<u8>>), &'static str> {
    cmd.stdin(Stdio::null());
    let mut child = cmd.spawn().map_err(|_| UNAVAILABLE)?;
    let pipe: Option<Box<dyn std::io::Read + Send>> = if from_stderr {
        child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>)
    } else {
        child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>)
    };
    let reader = std::thread::spawn(move || drain(pipe));
    let status = match child.wait_timeout(TIMEOUT) {
        Ok(Some(status)) => status,
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err("vault.secret_store_timeout");
        }
    };
    let raw = reader.join().map_err(|_| "vault.secret_store_read_failed")?;
    Ok((status, raw))
}

/// All of a child's pipe, into a zeroed buffer (at most 1 MiB).
pub fn drain(pipe: Option<impl std::io::Read>) -> Zeroizing<Vec<u8>> {
    use std::io::Read as _;
    let mut out = Zeroizing::new(Vec::new());
    if let Some(pipe) = pipe {
        let _ = pipe.take(1 << 20).read_to_end(&mut out);
    }
    out
}

fn decode(encoded: &str) -> Option<Zeroizing<String>> {
    let bytes = Zeroizing::new(base64::engine::general_purpose::STANDARD.decode(encoded).ok()?);
    let text = std::str::from_utf8(&bytes).ok()?;
    Some(Zeroizing::new(text.to_owned()))
}

/// A store in memory, for tests.
#[cfg(test)]
#[derive(Default)]
pub struct MemoryStore {
    pub items: std::sync::Mutex<std::collections::BTreeMap<String, Zeroizing<String>>>,
    pub unavailable: bool,
    /// Deletes fail (a locked keychain).
    pub fail_delete: std::sync::atomic::AtomicBool,
    /// Reads fail.
    pub fail_get: std::sync::atomic::AtomicBool,
    /// Writes of this name fail.
    pub fail_put: Option<String>,
}

#[cfg(test)]
impl SecretStore for MemoryStore {
    fn kind(&self) -> &'static str {
        if self.unavailable { "unavailable" } else { "memory" }
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        if self.unavailable {
            return Err(UNAVAILABLE);
        }
        if self.fail_put.as_deref() == Some(name) {
            return Err("vault.secret_store_write_failed");
        }
        self.items.lock().unwrap().insert(name.to_owned(), Zeroizing::new(value.to_owned()));
        Ok(())
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        if self.fail_get.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("vault.secret_store_read_failed");
        }
        Ok(self.items.lock().unwrap().get(name).cloned())
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        if self.unavailable {
            return Err(UNAVAILABLE);
        }
        if self.fail_delete.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("vault.secret_store_delete_failed");
        }
        self.items.lock().unwrap().remove(name);
        Ok(())
    }
}
