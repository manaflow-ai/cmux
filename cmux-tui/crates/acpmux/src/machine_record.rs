//! This machine's join record and its consent gate, as the lower layers read them: the machine
//! credential on disk (`machine-credential.json`), whether the home holding it was copied from
//! another box, and the consent computer use and control ask for. `cli::cloud_join` (the join,
//! leave and status commands) writes them and re-exports these.

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;

use crate::host_fingerprint;

pub const CONSENT_REQUIRED: &str = "consent_required";

pub(crate) const CREDENTIAL_FILE: &str = "machine-credential.json";
static CONSENT_HOME: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// A hand later switches config::home to its private agent daemon. Consent
/// continues to belong to the physical machine's original enrolled state.
pub(crate) fn retain_machine_consent_home() {
    let _ = CONSENT_HOME.set(crate::config::home());
}

pub(crate) fn consent_home() -> PathBuf {
    CONSENT_HOME.get().cloned().unwrap_or_else(state_dir)
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct MachineCredential {
    pub credential: String,
    pub machine_id: String,
    pub team_id: String,
    pub name: String,
    pub hub_origin: String,
    pub last_heartbeat: Option<String>,
    pub revoked: bool,
    #[serde(rename = "wgPublicKey")]
    pub wg_public_key: String,
    #[serde(default)]
    pub credential_generation: u64,
    /// The person who enrolled this machine, from the hub's answer for this credential
    /// (`userId`). `meshRelay.controlFrom`'s `sameUser` entry matches it against the
    /// hub-stamped sender. None (an older join, or a hub that does not name it yet) grants
    /// nothing automatically.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    /// The box this credential was joined on (`host_fingerprint`). None on a record joined
    /// before it existed: the first daemon start adopts the box it runs on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_fingerprint: Option<String>,
    /// This record was copied here from the box that joined it. The credential is never used
    /// here again (it stays the original box's, untouched on the hub); a new join line gives
    /// this box its own.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cloned: bool,
    /// What joined this machine: `sign-in` when signing in enrolled it (`enroll.rs`), so signing
    /// out removes only that join. None for a pair code or a pasted join line: those stay.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub joined_by: Option<String>,
    /// What this machine told the hub it can do at its redeem, or what the hub recorded when it
    /// stated it later ([`machine_capabilities`]). None: joined before the hub took the list
    /// (cmux-platform#1015), so it states it with its own credential (`self_capabilities.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
    /// The box that found this record copied and gave itself a fresh node key (its
    /// `host_fingerprint`). A `cloned` record on any other box is a copy of that copy, its node
    /// key the settling box's: found and settled again. None on a record settled before it
    /// existed: the next start on the box it runs on takes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloned_on: Option<String>,
}

/// A hub-supplied id the store keeps: non-empty, one line, and no secret-shaped text.
pub(crate) fn safe_id(value: &str) -> Option<String> {
    Some(value)
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 256
                && !s.contains("cmj_")
                && !s.contains("cmm_")
                && !s.chars().any(char::is_control)
        })
        .map(str::to_owned)
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Consent {
    pub screen: ConsentState,
    pub control: ConsentState,
    /// Control for this person's other machines signed in to the same account: they open
    /// workspaces and terminals here through the hub carrier (`hub_carrier.rs`,
    /// [`SIGNED_IN_MACHINES`]). Off by default; signing in never grants it. A file an older
    /// build wrote has none (off), and an older build that rewrites the file drops it (off).
    #[serde(rename = "signedInMachines", default)]
    pub signed_in_machines: ConsentState,
    /// When the person last answered the ask for [`Self::signed_in_machines`] (Allow, Not now,
    /// or a later Off): it is asked once, so a later refusal records no new ask.
    #[serde(
        rename = "signedInMachinesAnsweredAt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub signed_in_machines_answered_at: Option<String>,
    /// The account (hub user id) [`Self::signed_in_machines`] was answered for: the grant and the
    /// answer hold only while this machine is joined as that account, so a switch to another
    /// account asks again and lets none of its machines in.
    #[serde(rename = "signedInMachinesUser", default, skip_serializing_if = "Option::is_none")]
    pub signed_in_machines_user: Option<String>,
    #[serde(rename = "grantedAt", skip_serializing_if = "Option::is_none")]
    pub granted_at: Option<String>,
}

/// The consent surface "control for my other machines signed in to this account" (Leo,
/// 2026-11-14: "ok then do that", to one click on the new Mac).
pub const SIGNED_IN_MACHINES: &str = "signedInMachines";

/// Every consent surface the person can grant on this machine.
pub(crate) fn is_consent_surface(surface: &str) -> bool {
    matches!(surface, "screen" | "control" | SIGNED_IN_MACHINES)
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ConsentState {
    #[default]
    None,
    Granted,
}

pub(crate) fn state_dir() -> PathBuf {
    crate::config::home()
}

/// What `record`, read from `home`, is to the box whose fingerprint is `current`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CopyState {
    /// Joined here, or nothing to compare (no fingerprint on the record or this box).
    Own,
    /// Copied from another box and settled on this one: marked `cloned` here, the node key
    /// replaced with this box's own.
    SettledHere,
    /// Copied and not settled here: joined on another box, or marked `cloned` on another box
    /// (a copy of a copy). The node key in `home` is another box's.
    Unsettled,
}

/// Whether `stamp`, a box fingerprint recorded in `home`, names another box than `current`. A
/// missing stamp or a box with no fingerprint compares nothing.
pub(crate) fn other_box(
    home: &std::path::Path,
    stamp: Option<&str>,
    current: Option<&str>,
) -> bool {
    matches!((stamp, current), (Some(then), Some(here)) if !host_fingerprint::same_box(home, then, here))
}

pub(crate) fn copy_state(
    home: &std::path::Path,
    record: &MachineCredential,
    current: Option<&str>,
) -> CopyState {
    if record.cloned {
        if other_box(home, record.cloned_on.as_deref(), current) {
            CopyState::Unsettled
        } else {
            CopyState::SettledHere
        }
    } else if other_box(home, record.host_fingerprint.as_deref(), current) {
        CopyState::Unsettled
    } else {
        CopyState::Own
    }
}

/// The one "was this home copied here" predicate, from every piece of evidence a home holds
/// about the box it was made on: its machine record (`record`, the one on disk or the one a
/// caller is about to replace) and a join begun there and not finished
/// (`machine-join.pending.json`, [`recovery::pending_made_on`]). A pending join proposed on
/// another box makes the home a copy not settled here, whatever the record says: the node key
/// beside it is that box's. Every caller that decides "copied home" goes through it
/// ([`copied_here`], [`copied_at`], [`node_key_copied_at`], `host join`'s set-aside).
pub(crate) fn home_copy_state(
    home: &std::path::Path,
    record: Option<&MachineCredential>,
    current: Option<&str>,
) -> CopyState {
    let by_record = record.map_or(CopyState::Own, |record| copy_state(home, record, current));
    if by_record != CopyState::Unsettled
        && recovery::pending_made_on(home)
            .is_some_and(|made| other_box(home, made.as_deref(), current))
    {
        return CopyState::Unsettled;
    }
    by_record
}

/// [`home_copy_state`], recording a copy not settled here (`mesh_node_key::record_copied_key`)
/// before it answers.
///
/// The key recorded is the one read before the evidence that shows the copy, never the one in
/// place when it is recorded: a settle saves the settled record before it replaces the key
/// ([`settle_clone_at`]), so a record still unsettled when read again after the key means that
/// key is the copy's. A `host join` or a settled start may replace it meanwhile with this box's
/// own (registered) key, which is never marked.
pub(crate) fn settle_evidence(
    home: &std::path::Path,
    record: Option<&MachineCredential>,
    current: Option<&str>,
) -> CopyState {
    let key = crate::mesh_node_key::public_key_at(home);
    let state = home_copy_state(home, record, current);
    if state != CopyState::Unsettled {
        return state;
    }
    // Asked again after the key: the record the caller read may predate a settle (and a
    // join) since; one a leave removed meanwhile leaves the caller's.
    let again = load_at(home).ok().flatten();
    if let Some(key) = key
        && home_copy_state(home, again.as_ref().or(record), current) == CopyState::Unsettled
        && let Err(e) = crate::mesh_node_key::record_copied_public_key(home, &key)
    {
        tracing::warn!("could not record the copied node key: {e:#}");
    }
    state
}

/// Whether `record`, read from `home`, was copied here from another box: marked so, or joined
/// (or settled) on a box whose fingerprint differs from this one's. A record or a box with no
/// fingerprint is no clone.
///
/// A copy found here and not settled here yet ([`CopyState::Unsettled`]) is recorded first,
/// durably, whatever the caller does next: the node key now in `home` is another box's
/// (`mesh_node_key::record_copied_key`, which keeps every key it was ever told). A `machine
/// leave` may delete this record right after, and the key may stay (the cmux link adopted
/// it); the record keeps every later holder, the link included, from serving that key here.
pub(crate) fn copied_here(
    home: &std::path::Path,
    record: &MachineCredential,
    current: Option<&str>,
) -> bool {
    settle_evidence(home, Some(record), current) != CopyState::Own
}

/// Whether the node key now in acpmux home `home` is another box's: its record is a copy not
/// settled here (found live, and recorded), or the key is one recorded as copied
/// (`mesh_node_key::serves_copied_key`, which outlives the record). A home settled here (its
/// own fresh key) is not. What the cmux link asks before it adopts or serves the key.
pub(crate) fn node_key_copied_at(home: &std::path::Path) -> bool {
    let current = host_fingerprint::current();
    let record = load_at(home).ok().flatten();
    settle_evidence(home, record.as_ref(), current.as_deref()) == CopyState::Unsettled
        || crate::mesh_node_key::serves_copied_key(home)
}

/// Whether `home`'s machine record provably belongs to this box: live, made (or settled) on a
/// box with a fingerprint, that box this one, and no evidence of a copy
/// (`home_copy_state`). A box that names no machine proves nothing.
pub(crate) fn record_own_here(home: &std::path::Path) -> bool {
    let Some(current) = host_fingerprint::current() else { return false };
    let Some(record) = load_at(home).ok().flatten() else { return false };
    let stamped =
        if record.cloned { record.cloned_on.is_some() } else { record.host_fingerprint.is_some() };
    !record.revoked
        && stamped
        && home_copy_state(home, Some(&record), Some(&current)) != CopyState::Unsettled
}

/// Whether the node key in acpmux home `home` is provably this box's own
/// (`mesh_node_key::node_key_own_here`): the record is live and joined or settled on this
/// box, nothing shows a copy, and the key is not one recorded as copied.
pub(crate) fn node_key_own_at(home: &std::path::Path) -> bool {
    let current = host_fingerprint::current();
    let Some(record) = load_at(home).ok().flatten() else { return false };
    !record.revoked
        && home_copy_state(home, Some(&record), current.as_deref()) != CopyState::Unsettled
        && !crate::mesh_node_key::serves_copied_key(home)
}

pub(crate) fn load() -> Result<Option<MachineCredential>> {
    load_at(&state_dir())
}

/// The joined machine credential, for the vault pull (`crate::vault`), which
/// sends it only as the bearer of its own hub request.
///
/// A record copied from another box is no credential of this one: None, as if not joined.
pub(crate) fn machine_credential() -> Result<Option<MachineCredential>> {
    let current = host_fingerprint::current();
    Ok(load()?.filter(|record| !copied_here(&state_dir(), record, current.as_deref())))
}

/// The person this machine recorded at join, for `controlFrom`'s `sameUser` entry. None when
/// the machine is not joined, is revoked, or recorded no person.
pub(crate) fn machine_user_id() -> Option<String> {
    // A copy of another box's join speaks for nobody here.
    let record = machine_credential().ok().flatten()?;
    (!record.revoked).then_some(record.user_id?).and_then(|user| safe_id(&user))
}

pub(crate) fn load_at(home: &std::path::Path) -> Result<Option<MachineCredential>> {
    let path = home.join(CREDENTIAL_FILE);
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let file = crate::config::private_state_file(&path)?;
    Ok(Some(serde_json::from_reader(file).context("read machine credential")?))
}

pub(crate) fn authority() -> Result<crate::machine_consent::Authority> {
    crate::machine_consent::Authority::current(consent_home())
}

/// A held `flock`. Dropping it unlocks explicitly: a process spawned meanwhile (an agent, a
/// tool, a login shell) shares the lock's open file description from its fork until its exec,
/// so closing this descriptor alone would leave the lock held until then, and the next
/// nonblocking take would fail as if another holder were still at work.
pub(crate) struct HeldLock(pub(crate) std::fs::File);

impl HeldLock {
    /// Takes `file`'s exclusive lock without waiting (`flock` on Unix, `LockFileEx` on Windows);
    /// `busy` is the error when another holder has it.
    pub(crate) fn take(file: std::fs::File, busy: &'static str) -> Result<Self> {
        match file.try_lock() {
            Ok(()) => Ok(HeldLock(file)),
            Err(std::fs::TryLockError::WouldBlock) => Err(anyhow::anyhow!(busy)),
            Err(std::fs::TryLockError::Error(e)) => Err(e.into()),
        }
    }
}

impl Drop for HeldLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

pub(crate) fn consent_status() -> Value {
    authority().map(|authority| authority.status()).unwrap_or_else(
        |_| json!({"consentRequired":true,"consent":Consent::default(),"lastRefusal":null}),
    )
}

pub fn require_consent(surface: &str) -> Result<()> {
    let status = consent_status();
    if matches!(surface, "screen" | "control") && status["consent"][surface] == "granted" {
        Ok(())
    } else {
        let _ = record_consent_refusal(surface);
        Err(anyhow!(CONSENT_REQUIRED))
    }
}

/// Whether the Mac's own sessions keep computer use with no consent: the requirement comes only
/// from joins signing in made ([`machine_consent::Authority::required_only_by_sign_in`]).
pub(crate) fn local_computer_use_kept() -> bool {
    authority().is_ok_and(|authority| authority.required_only_by_sign_in())
}

pub fn require_joined_consent(surface: &str) -> Result<()> {
    if consent_status()["consentRequired"] == false { Ok(()) } else { require_consent(surface) }
}

pub(crate) fn record_consent_refusal(surface: &str) -> Result<()> {
    authority()?.refused(surface)
}

/// `joined_by` of a join signing in made.
pub(crate) const JOINED_BY_SIGN_IN: &str = "sign-in";

/// The pending join's file (`cli::cloud_join::recovery`), read here for its fingerprint only.
pub(crate) mod recovery {
    use std::path::Path;

    pub(crate) const FILE: &str = "machine-join.pending.json";

    /// The box a join pending in `home` was proposed on: `None` when there is none (or it cannot be
    /// read: `cloud_join::recovery`'s `read` refuses it before it is used), `Some(None)` for one an
    /// older build wrote with no fingerprint. Read for its fingerprint only, by any process that
    /// decides whether `home` was copied (`home_copy_state`).
    pub(crate) fn pending_made_on(home: &Path) -> Option<Option<String>> {
        let file = crate::config::private_state_file(&home.join(FILE)).ok()?;
        let pending: serde_json::Value = serde_json::from_reader(file).ok()?;
        Some(pending.get("host_fingerprint").and_then(|made| made.as_str()).map(str::to_owned))
    }
}
