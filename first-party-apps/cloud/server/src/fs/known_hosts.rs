//! [`KnownHosts`]: the host keys this app pinned, in
//! `<data>/ssh/known_hosts` (crate::app_env::AppEnv::ssh_files), one line
//! per machine: `cmux-scp-<machine> ssh-ed25519 <base64>`.
//!
//! The server reads the file once at start and keeps the pins in memory;
//! the loop thread is the only writer. A pin changes only when the Cloud
//! API (the authority for a machine's host key) answers a new key for that
//! machine. Each write replaces the whole file atomically: a temporary file
//! in the same folder (owner read and write only), then a rename, so a
//! crash leaves the old file or the new one, never a mix. The folder is
//! owner-only. No other known_hosts file (the user's `~/.ssh` included) is
//! ever read.
//!
//! A line that is not a valid pin is skipped with a warning (logged to
//! stderr and returned by [`KnownHosts::load`]); the other pins stay. The
//! next write drops the skipped line.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

/// The rename step of the atomic write. A test seam: a failing rename
/// stands for a crash between the temporary write and the rename.
pub type Rename = fn(&Path, &Path) -> io::Result<()>;

/// The pinned host keys and the file they live in.
pub struct KnownHosts {
    path: PathBuf,
    pins: BTreeMap<String, String>,
    rename: Rename,
}

impl std::fmt::Debug for KnownHosts {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KnownHosts").field("path", &self.path).field("pins", &self.pins).finish()
    }
}

impl KnownHosts {
    /// Reads the pins in `path`. A missing file is no pins. Each line that
    /// is not a valid pin (and an unreadable file) gives one warning, also
    /// written to stderr; it never fails the server.
    pub fn load(path: PathBuf) -> (Self, Vec<String>) {
        let mut pins = BTreeMap::new();
        let mut warnings = Vec::new();
        match read_regular(&path) {
            Ok(bytes) => {
                for (index, line) in bytes.split(|b| *b == b'\n').enumerate() {
                    if line.iter().all(u8::is_ascii_whitespace) {
                        continue;
                    }
                    match std::str::from_utf8(line).ok().and_then(parse) {
                        Some((machine, key)) => {
                            pins.insert(machine, key);
                        }
                        None if warnings.len() < MAX_WARNINGS => warnings.push(format!(
                            "{}: line {} is not a pinned host key; it was skipped",
                            path.display(),
                            index + 1
                        )),
                        None => {}
                    }
                }
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => warnings.push(format!("{}: not read ({e}); no pins", path.display())),
        }
        for warning in &warnings {
            eprintln!("cmux-cloud: {warning}");
        }
        (Self { path, pins, rename: |from, to| std::fs::rename(from, to) }, warnings)
    }

    /// The same pins with another rename step (test seam).
    pub fn with_rename(mut self, rename: Rename) -> Self {
        self.rename = rename;
        self
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The pinned key of `machine`.
    pub fn get(&self, machine: &str) -> Option<&str> {
        self.pins.get(machine).map(String::as_str)
    }

    /// Pins `host_key` for `machine` (the Cloud API's answer) and rewrites
    /// the file when the pin is new or changed, or the file is missing.
    /// Memory changes only after the file did, so a failed write is
    /// retried by the next transfer instead of trusting a stale file.
    pub fn pin(&mut self, machine: &str, host_key: &str) -> io::Result<()> {
        if self.get(machine) == Some(host_key) && self.path.is_file() {
            return Ok(());
        }
        let mut pins = self.pins.clone();
        pins.insert(machine.to_owned(), host_key.to_owned());
        let text: String = pins
            .iter()
            .map(|(m, key)| format!("{} {key}\n", super::transfer::host_alias(m)))
            .collect();
        if let Some(dir) = self.path.parent() {
            crate::app_env::private_dir(dir)?;
        }
        crate::app_env::write_private_with(&self.path, text.as_bytes(), self.rename)?;
        self.pins = pins;
        Ok(())
    }
}

/// The largest known_hosts file read; the rest is ignored. One pin is
/// about 110 bytes, so this holds thousands of machines.
const MAX_BYTES: u64 = 1024 * 1024;
/// Warnings kept (and logged) per load.
const MAX_WARNINGS: usize = 16;

/// The bytes of `path` when it is a regular file (not a symlink, FIFO or
/// device, which could point elsewhere or block the start), at most
/// [`MAX_BYTES`]. A missing file is `NotFound`.
fn read_regular(path: &Path) -> io::Result<Vec<u8>> {
    use std::io::Read as _;
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_file() {
        return Err(io::Error::other("not a regular file"));
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)?.take(MAX_BYTES).read_to_end(&mut bytes)?;
    if meta.len() > MAX_BYTES {
        eprintln!("cmux-cloud: {} is over 1 MiB; only the first MiB was read", path.display());
    }
    Ok(bytes)
}

/// `cmux-scp-<machine> ssh-ed25519 <base64>` with a valid machine id and
/// one Ed25519 key.
fn parse(line: &str) -> Option<(String, String)> {
    let mut fields = line.split_ascii_whitespace();
    let alias = fields.next()?;
    let algorithm = fields.next()?;
    let blob = fields.next()?;
    if fields.next().is_some() {
        return None;
    }
    let machine = alias.strip_prefix("cmux-scp-")?;
    let valid_id = machine.len() <= 128
        && machine.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && machine.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    let key = format!("{algorithm} {blob}");
    (valid_id && super::transfer::valid_host_key(&key)).then(|| (machine.to_owned(), key))
}
