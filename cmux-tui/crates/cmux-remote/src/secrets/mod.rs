//! `secrets-v1`: secrets and harness logins sealed end to end to a machine.
//!
//! A device seals each value to this daemon's static X25519 key ([`seal`]).
//! The daemon opens it here, for its own machine id only, and writes it,
//! mode 0600: secrets to `~/.config/cmux/machine-secrets.env`, harness logins
//! where the harness reads them. A name outside the allowlist, a path outside
//! [`files::allowed_paths`], an item that doesn't open and a replayed nonce
//! are each refused. No value reaches a log line or an error.

pub mod files;
pub mod harness;
pub mod request;
pub mod seal;
#[cfg(all(test, unix))]
mod tests;

use std::collections::{HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use cmux_remote_protocol::{RpcError, SealedSecret};
use zeroize::Zeroizing;

use crate::crypto::StaticIdentity;
use harness::HarnessLogin;
pub use seal::Purpose;

/// How many opened nonces the daemon remembers (oldest dropped first).
const SEEN_NONCES: usize = 4_096;
/// The most items one replace may carry.
const MAX_ITEMS: usize = 256;

/// Where `secrets-v1` log lines go: names and counts only, never a value.
pub type LogSink = Arc<dyn Fn(&str) + Send + Sync>;

pub struct MachineSecrets {
    private_key: Zeroizing<[u8; 32]>,
    machine_id: String,
    home: PathBuf,
    etc: PathBuf,
    seen: Mutex<SeenNonces>,
    log: LogSink,
}

#[derive(Default)]
struct SeenNonces {
    set: HashSet<String>,
    order: VecDeque<String>,
}

impl SeenNonces {
    fn contains(&self, nonce: &str) -> bool {
        self.set.contains(nonce)
    }

    fn insert(&mut self, nonce: &str) {
        if self.set.insert(nonce.to_owned()) {
            self.order.push_back(nonce.to_owned());
        }
        while self.order.len() > SEEN_NONCES {
            if let Some(oldest) = self.order.pop_front() {
                self.set.remove(&oldest);
            }
        }
    }
}

impl std::fmt::Debug for MachineSecrets {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MachineSecrets")
            .field("machine_id", &self.machine_id)
            .field("home", &self.home)
            .finish_non_exhaustive()
    }
}

fn refused(code: &str, name: &str) -> RpcError {
    RpcError::new("secret-refused", format!("{code}: {name}"))
}

impl MachineSecrets {
    /// The service for the daemon whose static identity is `identity`, on
    /// the machine `machine_id`, writing under `home` and reading the guest's
    /// policy from `etc` (`/etc/cmux`).
    pub fn new(identity: &StaticIdentity, machine_id: String, home: PathBuf, etc: PathBuf) -> Self {
        Self {
            private_key: Zeroizing::new(*identity.private_key()),
            machine_id,
            home,
            etc,
            seen: Mutex::new(SeenNonces::default()),
            log: Arc::new(|line| eprintln!("{line}")),
        }
    }

    pub fn with_log(mut self, log: LogSink) -> Self {
        self.log = log;
        self
    }

    pub fn machine_id(&self) -> &str {
        &self.machine_id
    }

    fn log(&self, line: &str) {
        (self.log)(line);
    }

    /// Open `item` for `purpose`, refusing a malformed or already seen nonce.
    /// The nonce is not recorded here: [`Self::remember`] does that once a
    /// whole request has opened.
    fn open(&self, purpose: Purpose, item: &SealedSecret) -> Result<Zeroizing<Vec<u8>>, RpcError> {
        if !seal::is_nonce(&item.nonce) {
            return Err(refused("bad-nonce", &item.name));
        }
        if self.seen.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains(&item.nonce)
        {
            return Err(refused("replay", &item.name));
        }
        seal::open(&self.private_key, &self.machine_id, purpose, item)
            .map_err(|error| refused(error.code(), &item.name))
    }

    /// Record `items`' nonces as seen, all or none: one already seen (a
    /// concurrent request with the same item) refuses the whole request.
    fn remember(&self, items: &[SealedSecret]) -> Result<(), RpcError> {
        let mut seen = self.seen.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(item) = items.iter().find(|item| seen.contains(&item.nonce)) {
            return Err(refused("replay", &item.name));
        }
        for item in items {
            seen.insert(&item.nonce);
        }
        Ok(())
    }

    /// Replace `~/.config/cmux/machine-secrets.env` with exactly `items`:
    /// all of them open and pass, or the file is left as it was.
    pub fn replace_machine_secrets(&self, items: &[SealedSecret]) -> Result<u32, RpcError> {
        let result = self.replace_inner(items);
        match &result {
            Ok(count) => self.log(&format!("secrets-v1: wrote machine secrets ({count} names)")),
            Err(error) => self.log(&format!("secrets-v1: machine secrets refused ({error})")),
        }
        result
    }

    fn replace_inner(&self, items: &[SealedSecret]) -> Result<u32, RpcError> {
        if items.len() > MAX_ITEMS {
            return Err(refused("too-large", "machine-secrets.env"));
        }
        let declared = self.declared_names();
        let mut names = HashSet::new();
        let mut nonces = HashSet::new();
        let mut values = Vec::with_capacity(items.len());
        for item in items {
            if !files::is_secret_name(&item.name)
                || !declared.as_ref().is_some_and(|declared| declared.contains(&item.name))
            {
                return Err(refused("bad-name", &item.name));
            }
            if !names.insert(item.name.as_str()) {
                return Err(refused("duplicate", &item.name));
            }
            if !nonces.insert(item.nonce.as_str()) {
                return Err(refused("replay", &item.name));
            }
            let opened = self.open(Purpose::Secret, item)?;
            let value = std::str::from_utf8(&opened)
                .ok()
                .filter(|value| files::is_secret_value(value))
                .map(|value| Zeroizing::new(value.to_owned()))
                .ok_or_else(|| refused("bad-value", &item.name))?;
            values.push((item.name.clone(), value));
        }
        let rendered = files::render_env(&values);
        if rendered.len() > files::MAX_ENV_FILE_BYTES {
            return Err(refused("too-large", "machine-secrets.env"));
        }
        self.remember(items)?;
        let path = self.home.join(files::MACHINE_SECRETS_FILE);
        files::write_allowed(&self.home, &path, rendered.as_bytes())
            .map_err(|_| refused("write", "machine-secrets.env"))?;
        u32::try_from(values.len()).map_err(|_| refused("too-large", "machine-secrets.env"))
    }

    /// The names the machine's config declares; `None` while it has not
    /// finished an apply.
    fn declared_names(&self) -> Option<HashSet<String>> {
        let path = self.home.join(files::MACHINE_CONFIG_STATUS_FILE);
        let bytes = std::fs::read(&path).ok()?;
        files::declared_names(&bytes).map(|names| names.into_iter().collect())
    }

    /// Install one harness login (`claude` or `codex`).
    pub fn install_harness_login(
        &self,
        item: &SealedSecret,
        allow_team_guest: bool,
    ) -> Result<String, RpcError> {
        let result = self.install_inner(item, allow_team_guest);
        match &result {
            Ok(name) => self.log(&format!("secrets-v1: installed the {name} login")),
            Err(error) => self.log(&format!("secrets-v1: harness login refused ({error})")),
        }
        result
    }

    fn install_inner(
        &self,
        item: &SealedSecret,
        allow_team_guest: bool,
    ) -> Result<String, RpcError> {
        let login =
            HarnessLogin::from_name(&item.name).ok_or_else(|| refused("bad-name", &item.name))?;
        let value = self.open(Purpose::HarnessLogin, item)?;
        login.validate(&value).map_err(|error| refused(error.code(), &item.name))?;
        // A team guest's Unix user is every member's, and the daemon can't
        // tell its creator from a teammate: only a DEV daemon build honors
        // the DEV creator allowance. Every other build takes owner guests only.
        let allow_team_guest = allow_team_guest && cfg!(debug_assertions);
        harness::check_guest(&self.etc, login, allow_team_guest)
            .map_err(|error| refused(error.code(), &item.name))?;
        self.remember(std::slice::from_ref(item))?;
        harness::install(&self.home, login, &value)
            .map_err(|error| refused(error.code(), &item.name))?;
        Ok(login.name().to_owned())
    }
}
