//! `secrets-v1`: secrets and harness logins sealed end to end to a machine.
//!
//! A device seals each value to this daemon's static X25519 key ([`seal`]).
//! The daemon opens it here, for its own machine id only, and writes it,
//! mode 0600: secrets to `~/.config/cmux/machine-secrets.env`, harness logins
//! where the harness reads them. A name outside the allowlist, a path outside
//! [`files::allowed_paths`], an item that doesn't open, one sealed more than
//! [`WINDOW_SECS`] from now and a replayed nonce are each refused. No value reaches a log line or an error.

#[cfg(unix)]
mod commit;
pub mod files;
pub mod harness;
mod replay;
pub mod request;
pub mod seal;
#[cfg(all(test, unix))]
mod tests;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use cmux_remote_protocol::{RpcError, SealedSecret};
use zeroize::Zeroizing;

use crate::crypto::StaticIdentity;
use harness::HarnessLogin;
use replay::Replay;
pub use replay::WINDOW_SECS;
pub use seal::Purpose;

/// The most items one replace may carry.
const MAX_ITEMS: usize = 256;

/// Where `secrets-v1` log lines go: names and counts only, never a value.
pub type LogSink = Arc<dyn Fn(&str) + Send + Sync>;
/// The daemon's clock, in Unix seconds.
pub type Clock = Arc<dyn Fn() -> u64 + Send + Sync>;

pub struct MachineSecrets {
    private_key: Zeroizing<[u8; 32]>,
    machine_id: String,
    home: PathBuf,
    etc: PathBuf,
    state: PathBuf,
    max_live: usize,
    clock: Clock,
    log: LogSink,
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

/// A refusal: a fixed code and the item's name, never a value. `not-ready`
/// (a guest that hasn't bound yet) and `busy` (the replay window is full)
/// are the ones a caller may retry.
fn refused(code: &str, name: &str) -> RpcError {
    let mut error = RpcError::new("secret-refused", format!("{code}: {name}"));
    error.retryable = matches!(code, "not-ready" | "busy");
    error
}

impl MachineSecrets {
    /// The service for the daemon whose static identity is `identity`, on
    /// the machine `machine_id`, writing under `home`, reading the guest's
    /// policy from `etc` (`/etc/cmux`) and keeping its taken nonces under
    /// `state` (the daemon's state folder).
    pub fn new(
        identity: &StaticIdentity,
        machine_id: String,
        home: PathBuf,
        etc: PathBuf,
        state: PathBuf,
    ) -> Self {
        Self {
            private_key: Zeroizing::new(*identity.private_key()),
            machine_id,
            home,
            etc,
            state,
            max_live: replay::MAX_LIVE,
            clock: Arc::new(seal::unix_now),
            log: Arc::new(|line| eprintln!("{line}")),
        }
    }

    /// Tests: another clock, and another cap on the nonces one window holds.
    #[cfg(test)]
    fn with_clock(mut self, clock: Clock, max_live: usize) -> Self {
        self.clock = clock;
        self.max_live = max_live;
        self
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

    /// Open `item` for `purpose` and check it against the replay window:
    /// sealed within [`WINDOW_SECS`] of now, with a nonce not taken yet.
    /// Nothing is taken here: [`Self::take`] does that once a whole request
    /// has opened.
    fn open(
        &self,
        replay: &Replay,
        now: u64,
        purpose: Purpose,
        item: &SealedSecret,
    ) -> Result<seal::Opened, RpcError> {
        if !seal::is_nonce(&item.nonce) {
            return Err(refused("bad-nonce", &item.name));
        }
        let opened = seal::open(&self.private_key, &self.machine_id, purpose, item)
            .map_err(|error| refused(error.code(), &item.name))?;
        replay
            .check(&item.nonce, opened.issued_at, now)
            .map_err(|refusal| refused(refusal.code(), &item.name))?;
        Ok(opened)
    }

    /// Take `taken`'s nonces (saved before anything is written), run
    /// `write`, and give them back when it fails, so the same sealed request
    /// can be sent again. A second success is a replay.
    fn take<T>(
        replay: &mut Replay,
        now: u64,
        taken: &[(String, u64)],
        refusal_name: &str,
        write: impl FnOnce() -> Result<T, RpcError>,
    ) -> Result<T, RpcError> {
        replay.take(taken, now).map_err(|refusal| refused(refusal.code(), refusal_name))?;
        let result = write();
        if result.is_err() {
            replay.release(taken);
        }
        result
    }

    /// One request at a time on this machine, from its replay check to its
    /// last write or rollback: an exclusive `flock` on the state folder's
    /// lock file, held until the returned [`Replay`] drops. Two requests
    /// (two threads, or an old and a new daemon) never interleave their
    /// writes, and one's rollback never undoes the other's files. The
    /// window is read from disk under the lock, so every daemon sees every
    /// nonce taken.
    fn begin(&self, name: &str) -> Result<(Replay, u64), RpcError> {
        let lock = replay::lock(&self.state).map_err(|_| refused("write", name))?;
        let now = (self.clock)();
        Ok((Replay::load(lock, self.state.clone(), now, self.max_live), now))
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
        let (mut replay, now) = self.begin("machine-secrets.env")?;
        let replay = &mut replay;
        let declared = self.declared_names();
        let mut names = HashSet::new();
        let mut nonces = HashSet::new();
        let mut values = Vec::with_capacity(items.len());
        let mut taken = Vec::with_capacity(items.len());
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
            let opened = self.open(replay, now, Purpose::Secret, item)?;
            taken.push((item.nonce.clone(), opened.issued_at));
            let value = std::str::from_utf8(&opened.value)
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
        let count =
            u32::try_from(values.len()).map_err(|_| refused("too-large", "machine-secrets.env"))?;
        let path = self.home.join(files::MACHINE_SECRETS_FILE);
        Self::take(replay, now, &taken, "machine-secrets.env", || {
            files::write_allowed(&self.home, &path, rendered.as_bytes())
                .map_err(|_| refused("write", "machine-secrets.env"))
        })?;
        Ok(count)
    }

    /// The names the machine's config declares; `None` while it has not
    /// finished an apply.
    fn declared_names(&self) -> Option<HashSet<String>> {
        let path = self.home.join(files::MACHINE_CONFIG_STATUS_FILE);
        let bytes = std::fs::read(&path).ok()?;
        files::declared_names(&bytes).map(|names| names.into_iter().collect())
    }

    /// Install one harness login (`claude` or `codex`), on an owner guest
    /// only: a team guest's Unix user is every member's, and the daemon can't
    /// tell the guest's creator from a teammate.
    pub fn install_harness_login(&self, item: &SealedSecret) -> Result<String, RpcError> {
        let result = self.install_inner(item);
        match &result {
            Ok(name) => self.log(&format!("secrets-v1: installed the {name} login")),
            Err(error) => self.log(&format!("secrets-v1: harness login refused ({error})")),
        }
        result
    }

    fn install_inner(&self, item: &SealedSecret) -> Result<String, RpcError> {
        let login =
            HarnessLogin::from_name(&item.name).ok_or_else(|| refused("bad-name", &item.name))?;
        let (mut replay, now) = self.begin(&item.name)?;
        let replay = &mut replay;
        let opened = self.open(replay, now, Purpose::HarnessLogin, item)?;
        login.validate(&opened.value).map_err(|error| refused(error.code(), &item.name))?;
        harness::check_guest(&self.etc, login)
            .map_err(|error| refused(error.code(), &item.name))?;
        let taken = [(item.nonce.clone(), opened.issued_at)];
        Self::take(replay, now, &taken, &item.name, || {
            harness::install(&self.home, login, &opened.value)
                .map_err(|error| refused(error.code(), &item.name))
        })?;
        Ok(login.name().to_owned())
    }
}
