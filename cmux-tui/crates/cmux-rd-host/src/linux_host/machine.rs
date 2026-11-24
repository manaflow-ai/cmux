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
}

impl Joined {
    /// The record of a sign-in with `credential` from `acpmux_home`.
    pub fn of(acpmux_home: &Path, credential: &MachineCredential) -> Self {
        Self {
            acpmux_home: acpmux_home.to_owned(),
            machine_id: credential.machine_id.clone(),
            credential_generation: credential.credential_generation,
        }
    }

    /// Whether this record is the join `credential` from `acpmux_home` is now.
    pub fn is(&self, acpmux_home: &Path, credential: &MachineCredential) -> bool {
        !self.machine_id.is_empty() && *self == Self::of(acpmux_home, credential)
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
mod tests {
    use super::*;

    fn home(tag: &str, body: Option<&str>) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("cmux-rd-machine-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        identity::private_dir(&dir).unwrap();
        if let Some(body) = body {
            identity::write_private(&dir.join(CREDENTIAL_FILE), body.as_bytes()).unwrap();
        }
        dir
    }

    #[test]
    fn a_joined_machine_has_a_credential() {
        let dir = home(
            "joined",
            Some(
                r#"{"credential":"cmm_x","machine_id":"m","team_id":"t","name":"vm-1","hub_origin":"https://p","last_heartbeat":null,"revoked":false,"wgPublicKey":""}"#,
            ),
        );
        let c = load(&dir).unwrap().unwrap();
        assert_eq!((c.credential.as_str(), c.name.as_str()), ("cmm_x", "vm-1"));
        assert!(!format!("{c:?}").contains("cmm_x"), "the credential is never printed");
    }

    #[test]
    fn revoked_copied_empty_or_missing_records_sign_nothing_in() {
        assert!(load(&home("none", None)).unwrap().is_none());
        for body in [
            r#"{"credential":"cmm_x","revoked":true}"#,
            r#"{"credential":"cmm_x","cloned":true}"#,
            r#"{"credential":" "}"#,
        ] {
            assert!(load(&home("unusable", Some(body))).unwrap().is_none(), "{body}");
        }
    }

    #[test]
    fn a_record_others_can_read_is_refused() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = home("open", Some(r#"{"credential":"cmm_x"}"#));
        std::fs::set_permissions(dir.join(CREDENTIAL_FILE), std::fs::Permissions::from_mode(0o644))
            .unwrap();
        assert!(load(&dir).is_err());
    }
}
