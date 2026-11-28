//! A joined machine signs in by itself (hq docs/design/remote-screen-share-zero-touch.md, Linux,
//! L1). `acpmux host join` keeps a cmux-platform machine credential in
//! `$ACPMUX_HOME/machine-credential.json`, never a person's Stack token.
//! The device hub signs the machine in from it (`POST /v1/auth/machine`, docs/device-hub/
//! PROTOCOL.md, Machine sign-in) as the person who joined it, for one device and at most an hour,
//! so this host signs in again before each hour ends instead of anchoring.
//!
//! Leo, 2026-11-16: "if you've connected to a headlessly running mini why... would it need
//! anything?"

use crate::Res;
use cmux_hub_host::identity;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// acpmux's file, beside its daemon's state.
pub const CREDENTIAL_FILE: &str = "machine-credential.json";

/// The fields of acpmux's machine record this host reads; the rest stay acpmux's.
#[derive(Deserialize, Clone)]
pub struct MachineCredential {
    pub credential: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub revoked: bool,
    /// Copied here from the box that joined it: never used here (acpmux's `cloned`).
    #[serde(default)]
    pub cloned: bool,
    /// Which join this credential is (acpmux's `mark_of`): a new join line gives another
    /// machine id or generation, even for the same account.
    #[serde(default)]
    pub machine_id: String,
    #[serde(default)]
    pub credential_generation: u64,
    /// The platform that issued it: only its deployment's device hub signs it in ([`Join`]).
    #[serde(default)]
    pub hub_origin: String,
}

impl std::fmt::Debug for MachineCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The credential is a bearer secret: never printed.
        f.debug_struct("MachineCredential")
            .field("name", &self.name)
            .field("revoked", &self.revoked)
            .field("cloned", &self.cloned)
            .finish_non_exhaustive()
    }
}

/// The acpmux home that runs this command: acpmux's daemon sets `ACPMUX_HOME` to its own (its
/// resolver names it per build) when it runs `enable --non-interactive --hub <the join's device
/// hub>` at its start on a joined Linux machine (acpmux's `share_host/linux.rs`), and the sign-in
/// records it in [`JOINED_FILE`] for the host unit. This never guesses a default home: a build's
/// state is only ever its own.
pub fn acpmux_home() -> Option<PathBuf> {
    std::env::var_os("ACPMUX_HOME").filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// This machine's usable credential in `home`: None when it was never joined, or its record
/// is revoked, copied from another box, or empty. A file another user could read or swap is
/// an error ([`identity::read_private`]).
pub fn load(home: &Path) -> Res<Option<MachineCredential>> {
    let Some(bytes) = identity::read_private(&home.join(CREDENTIAL_FILE))? else {
        return Ok(None);
    };
    let record: MachineCredential = serde_json::from_slice(&bytes)
        .map_err(|e| format!("{}: {e}", home.join(CREDENTIAL_FILE).display()))?;
    let usable = !record.revoked && !record.cloned && !record.credential.trim().is_empty();
    Ok(usable.then_some(record))
}

/// [`load`] from [`acpmux_home`]: the home and its credential.
pub fn current() -> Res<Option<(PathBuf, MachineCredential)>> {
    let Some(home) = acpmux_home() else { return Ok(None) };
    Ok(load(&home)?.map(|credential| (home, credential)))
}

/// One read of a join: its acpmux home, its credential and the device hub that credential signs
/// in at, all from the same credential file (review F2 of #45480). Every sign-in for a join
/// takes one ([`Join::of`] is the only way to make one outside tests), so a credential is only
/// ever sent to its own deployment's hub, whatever hub a caller held from an earlier join.
#[derive(Clone, Debug)]
pub struct Join {
    pub home: PathBuf,
    pub credential: MachineCredential,
    pub hub: String,
}

impl Join {
    /// The join `credential` from `home` is, at its deployment's device hub; an error when no
    /// deployment issued it (`hub_origin` names no platform this build knows).
    pub fn of(home: &Path, credential: MachineCredential) -> Res<Self> {
        // The tests' stub hubs: a loopback origin is its own deployment's hub.
        #[cfg(test)]
        if credential.hub_origin.starts_with("http://127.0.0.1:") {
            let hub = credential.hub_origin.clone();
            return Ok(Self { home: home.to_owned(), credential, hub });
        }
        let hub =
            cmux_hub_host::deployment::device_hub_of(&credential.hub_origin).ok_or_else(|| {
                format!(
                    "no device hub serves the platform this machine was joined at ({})",
                    cmux_hub_host::printable(&credential.hub_origin)
                )
            })?;
        Ok(Self { home: home.to_owned(), credential, hub: hub.to_owned() })
    }

    /// The join in `home` now: None when it has no usable credential ([`load`]).
    pub fn read(home: &Path) -> Res<Option<Self>> {
        load(home)?.map(|credential| Self::of(home, credential)).transpose()
    }

    /// A join at `hub` as it is, for tests that sign in at a stub hub.
    #[cfg(test)]
    pub fn at(home: &Path, credential: MachineCredential, hub: &str) -> Self {
        Self { home: home.to_owned(), credential, hub: hub.to_owned() }
    }
}

/// Beside `account.json`: the host's sign-in came from a join, never from a person's token.
pub const JOINED_FILE: &str = "joined.json";

/// What [`JOINED_FILE`] keeps: the acpmux home whose credential signs this host in, so every
/// session comes from `POST /v1/auth/machine` and nothing is anchored.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Joined {
    pub acpmux_home: PathBuf,
    /// The join it was signed in for ([`MachineCredential::machine_id`] and generation): a
    /// record written before these existed names no join, so it is never the current one until
    /// the hub says it is ([`Joined::unmarked_from`]).
    #[serde(default)]
    pub machine_id: String,
    #[serde(default)]
    pub credential_generation: u64,
    /// Whether this join's consent is tracked by consent-join.json (#45480): set when a build
    /// that writes that marker first signs the join in. A record without it is from before, so
    /// its consent.json, or the absence of one, is its person's choice, never a stopped run.
    #[serde(default)]
    pub consent_tracked: bool,
}

impl Joined {
    /// The record of a sign-in with `credential` from `acpmux_home`.
    pub fn of(acpmux_home: &Path, credential: &MachineCredential) -> Self {
        Self {
            acpmux_home: acpmux_home.to_owned(),
            machine_id: credential.machine_id.clone(),
            credential_generation: credential.credential_generation,
            consent_tracked: false,
        }
    }

    /// The record a sign-in with `credential` from `acpmux_home` writes over `previous` (what
    /// `joined.json` held): a new join's consent is tracked from now on; the same join (or a
    /// record from before joins were marked, from this home) keeps what it had, so signing in
    /// again never makes a person's earlier choice read as a stopped run.
    pub fn signed_in(
        previous: Option<&Self>,
        acpmux_home: &Path,
        credential: &MachineCredential,
    ) -> Self {
        let of = Self::of(acpmux_home, credential);
        let consent_tracked = match previous {
            Some(previous) if previous.same_machine(&of) || previous.unmarked_from(acpmux_home) => {
                previous.consent_tracked
            }
            _ => true,
        };
        Self { consent_tracked, ..of }
    }

    /// Whether this record and `other` are the same joined machine from the same acpmux home,
    /// whatever credential generation the hub gave it since.
    pub fn same_machine(&self, other: &Self) -> bool {
        !self.machine_id.is_empty()
            && self.machine_id == other.machine_id
            && self.acpmux_home == other.acpmux_home
    }

    /// Whether this record is the join `credential` from `acpmux_home` is now.
    pub fn is(&self, acpmux_home: &Path, credential: &MachineCredential) -> bool {
        let of = Self::of(acpmux_home, credential);
        self.same_machine(&of) && self.credential_generation == of.credential_generation
    }

    /// Whether this record was written from `acpmux_home` before joins were marked (#45369): it
    /// names no join, so only the hub can say whether its account is the current join's.
    pub fn unmarked_from(&self, acpmux_home: &Path) -> bool {
        self.machine_id.is_empty() && self.acpmux_home == acpmux_home
    }

    pub fn load(dir: &Path) -> Res<Option<Self>> {
        match identity::read_private(&dir.join(JOINED_FILE))? {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn save(&self, dir: &Path) -> Res<()> {
        identity::write_private(&dir.join(JOINED_FILE), &serde_json::to_vec_pretty(self)?)
    }

    /// A person's own sign-in (`enable` with a token) replaces the join's.
    pub fn clear(dir: &Path) -> Res<()> {
        match std::fs::remove_file(dir.join(JOINED_FILE)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
#[path = "machine_tests.rs"]
mod tests;
