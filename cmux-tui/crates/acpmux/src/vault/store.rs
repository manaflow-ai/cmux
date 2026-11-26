//! The OS secret store that holds vault env values: the macOS Keychain
//! (`/usr/bin/security`) or the Secret Service (`secret-tool`) on Linux. Item
//! service `cmux-vault`, account `env/<home-id>/<NAME>`: `<home-id>` names
//! this `ACPMUX_HOME` ([`home_id`]), so two daemons of one user (a second
//! home, a test home) never share or delete each other's items. There is no
//! file fallback.
//!
//! A machine whose OS store cannot take a write (a headless Mac reached over
//! ssh has no usable login keychain; its default is the System keychain) or
//! that has neither keeps the values in the daemon's memory only
//! ([`ProcessMemory`]): the daemon pulls them at every start, and `machine
//! vault pull` asks the running daemon to pull ([`os_usable`]).
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
    account_in(&crate::config::home(), name)
}

/// The account of `name` for the daemon home `home`.
pub fn account_in(home: &std::path::Path, name: &str) -> String {
    format!("env/{}/{name}", home_id(home))
}

/// A stable id of a daemon home: the first 16 hex digits of the sha256 of
/// its path (canonical when it exists).
pub fn home_id(home: &std::path::Path) -> String {
    use sha2::{Digest, Sha256};
    let path = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    let digest = Sha256::digest(path.as_os_str().as_encoded_bytes());
    digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
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
    /// [`SecretStore::get`], given up at `deadline` (`vault.secret_store_timeout`).
    fn get_by(
        &self,
        name: &str,
        deadline: std::time::Instant,
    ) -> Result<Option<Zeroizing<String>>, &'static str> {
        if std::time::Instant::now() >= deadline {
            return Err("vault.secret_store_timeout");
        }
        self.get(name)
    }
    /// Ok when the item is gone (or was never there).
    fn delete(&self, name: &str) -> Result<(), &'static str>;
    /// The OS store whose leftover items (`State::os_pending`) this store's
    /// pulls delete: the daemon's memory store has one; the OS store is
    /// itself the one, so it has none.
    fn os_leftovers(&self) -> Option<&dyn SecretStore> {
        None
    }
}

/// The values of a machine with no usable OS store, in this process's memory
/// only (the daemon's): never written anywhere, gone when it exits.
pub struct ProcessMemory;

static PROCESS_MEMORY: std::sync::Mutex<std::collections::BTreeMap<String, Zeroizing<String>>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

impl SecretStore for ProcessMemory {
    fn kind(&self) -> &'static str {
        "memory"
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        let mut items = PROCESS_MEMORY.lock().unwrap_or_else(|e| e.into_inner());
        items.insert(name.to_owned(), Zeroizing::new(value.to_owned()));
        Ok(())
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        let items = PROCESS_MEMORY.lock().unwrap_or_else(|e| e.into_inner());
        Ok(items.get(name).cloned())
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        PROCESS_MEMORY.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
        Ok(())
    }
    fn os_leftovers(&self) -> Option<&dyn SecretStore> {
        Some(&OsStore)
    }
}

/// The prefix of the item [`probe`] writes and removes again: no env name the
/// vault can carry has a dot.
pub const PROBE_PREFIX: &str = ".probe-";

/// A probe item name of its own per call (the process id and a counter), so
/// two processes probing at once (the CLI and the daemon) never read or
/// delete each other's item.
pub fn probe_name() -> String {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{PROBE_PREFIX}{}-{n}", std::process::id())
}

/// Whether this process can write, read back and remove an item in the OS
/// store, checked once per process: `false` without one, and on a Mac whose
/// session has no writable login keychain (ssh to a headless Mac).
pub fn os_usable() -> bool {
    *USABLE.get_or_init(|| probe(&OsStore))
}

static USABLE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

/// [`os_usable`] once it is known, without running the check: `None` while
/// it runs or before anything asked (a machine that is not joined never asks).
pub fn os_usable_known() -> Option<bool> {
    USABLE.get().copied()
}

/// Write, read back and remove a [`probe_name`] item (a fixed, non-secret value).
pub fn probe(store: &dyn SecretStore) -> bool {
    probe_as(store, &probe_name())
}

/// [`probe`] with the item `name`.
pub fn probe_as(store: &dyn SecretStore, name: &str) -> bool {
    const MARK: &str = "cmux vault probe";
    if !store.available() || store.put(name, MARK).is_err() {
        return false;
    }
    let read = matches!(store.get(name), Ok(Some(v)) if v.as_str() == MARK);
    let removed = store.delete(name).is_ok();
    removed && read
}

/// The store the daemon keeps values in: the OS store when [`os_usable`],
/// else [`ProcessMemory`].
pub fn for_daemon() -> std::sync::Arc<dyn SecretStore> {
    pick(os_usable())
}

/// [`for_daemon`] once the check is done, never running it: what a launch
/// uses, so a launch never waits on the store check.
pub fn for_daemon_known() -> Option<std::sync::Arc<dyn SecretStore>> {
    os_usable_known().map(pick)
}

fn pick(usable: bool) -> std::sync::Arc<dyn SecretStore> {
    if usable { std::sync::Arc::new(OsStore) } else { std::sync::Arc::new(ProcessMemory) }
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
        let cmd = put_command(Self::os(), name, value)?;
        crate::cli::harness_secret::run_store(&cmd).map_err(|_| "vault.secret_store_write_failed")
    }

    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        self.get_by(name, after(TIMEOUT))
    }

    fn get_by(
        &self,
        name: &str,
        deadline: std::time::Instant,
    ) -> Result<Option<Zeroizing<String>>, &'static str> {
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
        let (status, raw) = capture_until(cmd, macos, deadline)?;
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
    cmd: Command,
    from_stderr: bool,
) -> Result<(std::process::ExitStatus, Zeroizing<Vec<u8>>), &'static str> {
    capture_until(cmd, from_stderr, after(TIMEOUT))
}

/// `now + wait`, or now if that would not fit an `Instant`.
pub fn after(wait: std::time::Duration) -> std::time::Instant {
    let now = std::time::Instant::now();
    now.checked_add(wait).unwrap_or(now)
}

/// [`capture`], killing the command at `deadline` (at most the store timeout).
/// The output is read by the deadline too: a process the command started may
/// hold the pipe open after the command itself exits (`sh -c 'sleep 20 &
/// exit 0'`), and then the read ends at the deadline as a timeout.
pub fn capture_until(
    mut cmd: Command,
    from_stderr: bool,
    deadline: std::time::Instant,
) -> Result<(std::process::ExitStatus, Zeroizing<Vec<u8>>), &'static str> {
    let wait = deadline.saturating_duration_since(std::time::Instant::now()).min(TIMEOUT);
    let end = after(wait);
    cmd.stdin(Stdio::null());
    let mut child = cmd.spawn().map_err(|_| UNAVAILABLE)?;
    let pipe: Option<Box<dyn std::io::Read + Send>> = if from_stderr {
        child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>)
    } else {
        child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>)
    };
    // The reader is never joined: a process the command started may still
    // hold the pipe open; the reader ends when it closes, and the caller has
    // returned at the deadline by then.
    let (sent, read) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = sent.send(drain(pipe));
    });
    let status = match child.wait_timeout(wait) {
        Ok(Some(status)) => status,
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            return Err("vault.secret_store_timeout");
        }
    };
    match read.recv_timeout(end.saturating_duration_since(std::time::Instant::now())) {
        Ok(raw) => Ok((status, raw)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err("vault.secret_store_timeout"),
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            Err("vault.secret_store_read_failed")
        }
    }
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

/// Marks an item's encoding. The item is never empty (the store commands
/// refuse an empty secret), so an empty value is stored as just the marker.
const ITEM_PREFIX: &str = "v1:";

/// The item text of `value`: the marker, then base64, one printable word.
pub fn encode(value: &str) -> Zeroizing<String> {
    let mut out = Zeroizing::new(String::with_capacity(
        value.len().div_ceil(3).saturating_mul(4).saturating_add(ITEM_PREFIX.len()),
    ));
    out.push_str(ITEM_PREFIX);
    base64::engine::general_purpose::STANDARD.encode_string(value.as_bytes(), &mut out);
    out
}

/// The store command for one value on `os` (`macos` or another unix): the
/// value goes to its stdin, encoded, never to argv.
pub fn put_command(
    os: &str,
    name: &str,
    value: &str,
) -> Result<crate::cli::harness_secret::StoreCommand, &'static str> {
    crate::cli::harness_secret::store_item(
        os,
        SERVICE,
        &account(name),
        &format!("cmux vault {name}"),
        &encode(value),
    )
    .map_err(|_| "vault.env_value_refused")
}

/// The value of an item text [`encode`] made.
pub fn decode(item: &str) -> Option<Zeroizing<String>> {
    let encoded = item.strip_prefix(ITEM_PREFIX)?;
    let bytes = Zeroizing::new(base64::engine::general_purpose::STANDARD.decode(encoded).ok()?);
    let text = std::str::from_utf8(&bytes).ok()?;
    Some(Zeroizing::new(text.to_owned()))
}

#[cfg(test)]
pub use memory::MemoryStore;

/// A store in memory, for tests: a test module, so its lock unwraps are test code.
#[cfg(test)]
pub mod memory {
    use super::{SecretStore, UNAVAILABLE};
    use zeroize::Zeroizing;

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
        /// Kind `memory`: stands for the daemon's memory store.
        pub memory_mode: bool,
        /// The OS store a memory-mode store cleans up (`os_leftovers`).
        pub leftovers: Option<Box<MemoryStore>>,
    }

    impl SecretStore for MemoryStore {
        fn kind(&self) -> &'static str {
            if self.unavailable {
                "unavailable"
            } else if self.memory_mode {
                "memory"
            } else {
                "test"
            }
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
        fn os_leftovers(&self) -> Option<&dyn SecretStore> {
            self.leftovers.as_deref().map(|s| s as &dyn SecretStore)
        }
    }
}
