//! Enrolled Macs (peer-route approvals): the person's cmux app on a Mac may
//! allow a prompt of this daemon that reached the app through the Mac's own
//! daemon (a chat opened with `--host`, which that daemon mirrors over the
//! peer link), with a P-256 signature of its own. The person key never leaves
//! the Mac: only the signed answer crosses the link.
//!
//! - Who may sign is a file, `ACPMUX_HOME/mac-approvers.json` ([`FILE`]),
//!   `{"macs": [{id, publicKey, name}]}`, written by `acpmux host approvals
//!   add` on this machine (which `acpmux host enroll` on the Mac runs here over
//!   ssh). No RPC adds a key: an agent of this daemon that may only talk to its
//!   socket cannot enroll one. Writing the file takes this user's own power on
//!   this machine (ssh, or a shell command the person allowed), which can
//!   already replace this daemon. It is read as this user's private state (no
//!   link, not writable by others).
//! - The Mac's `_acpmux/permission_respond` carries the phone's shape
//!   (`approvers.rs`): `_meta.acpmux = {decisionNonce, approverDecision:
//!   {approver, expiresAt, signature}}`. `signature` is ECDSA P-256 / SHA-256,
//!   raw `r || s` as lowercase hex, over [`message`]: its own domain, then the
//!   daemon run, the Mac's id, the session, the permission, the tool call id,
//!   the option, the prompt's nonce, the expiry and the digest of the answers.
//! - A group's Allow once (`_acpmux/permission_group_respond`, `permission_groups.rs`) carries
//!   one such signature per pending member, `_meta.acpmux.approverDecisions = {permissionId:
//!   {decisionNonce, approverDecision}}`; it counts only when every member's does (`person.rs`).
//! - It counts once (the person gate's spent-nonce store), only until
//!   `expiresAt` (at most [`MAX_LIFETIME`] ahead), and only as a one-time allow
//!   (`allow_once`) of a tool's ask or an agent's question ([`may_allow`]): never
//!   a lasting allow, a plan, a mode switch or a folder-trust card, so it never
//!   changes a mode, a policy or a rule (a policy raise is its own signature, below). A deny needs no signature, from anyone.
//! - `acpmux host approvals rm ID` removes a Mac and then has the daemon reload
//!   (`_acpmux/mac_approvers {reload: true}`), which takes the set's lock: it
//!   returns only after an answer being committed, and from then on none of
//!   that Mac's signatures counts. Every check also re-reads the file when it
//!   changed, so a hand edit counts too.
//! - A policy raise of one chat (`person/policy_grant.rs`): the same key may sign
//!   `_meta.acpmux.approverPolicy = {approver, signature}` over [`policy_message`], its own
//!   domain, then the daemon run, the Mac's id, the session, the policy and a challenge nonce
//!   this daemon issued. It counts once, for that one chat's `_acpmux/set_policy`, never a
//!   default, a rule or a mode; a decision signature never counts as one, nor one as a decision.
//! - The app on this machine gives its own public key with
//!   `_acpmux/mac_approver_set {id, publicKey, name}` (the person only, memory
//!   only), so `acpmux host enroll` here knows which key to enroll on a peer.

use super::approvers::{Approver, MAX_LIFETIME, answers_digest, fingerprint, parse_approvers};
use super::*;
use std::path::{Path, PathBuf};

/// The enrolled Macs' file, in `ACPMUX_HOME`.
pub const FILE: &str = "mac-approvers.json";
/// The domain of an enrolled Mac's decision signature.
const DOMAIN: &str = "acpmux-mac-approver-decision-v1";
/// The domain of an enrolled Mac's signature over a policy raise (`person/policy_grant.rs`).
const POLICY_DOMAIN: &str = "acpmux-mac-approver-policy-v1";
/// The file is a few kilobytes at most; one past this is refused (read as no Macs).
const MAX_BYTES: u64 = 256 * 1024;

/// What a file looked like when it was read: its length and modification time.
type Stamp = (u64, Option<std::time::SystemTime>);

#[derive(Default)]
struct Inner {
    path: Option<PathBuf>,
    /// The file as last read (None: not read yet, or missing).
    stamp: Option<Stamp>,
    macs: Vec<Approver>,
}

/// The Macs that may allow here, and this machine's own app key.
#[derive(Default)]
pub struct MacApprovers {
    inner: StdMutex<Inner>,
    own: StdMutex<Option<Approver>>,
}

impl MacApprovers {
    /// Reads the enrolled Macs from `path` (the daemon's start).
    pub fn open(&self, path: PathBuf) {
        let mut inner = self.lock();
        inner.path = Some(path);
        inner.stamp = None;
        refresh(&mut inner);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `_acpmux/mac_approvers {reload?}`: the enrolled Macs (ids, names, key
    /// fingerprints) and this machine's own app key. `reload` reads the file
    /// again under the set's lock, so it returns only after an answer being
    /// committed (`host approvals rm`).
    pub fn view(&self, params: &Value) -> Value {
        let reload = params.get("reload").and_then(Value::as_bool) == Some(true);
        let mut inner = self.lock();
        if reload {
            inner.stamp = None;
        }
        refresh(&mut inner);
        let own = self.own.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        json!({
            "macs": inner.macs.iter().map(|m| json!({
                "id": m.id, "name": m.name, "fingerprint": fingerprint(&m.public_key),
            })).collect::<Vec<_>>(),
            "thisMac": own.map(|m| json!({
                "id": m.id, "name": m.name, "publicKey": super::approvers::hex(&m.public_key),
                "fingerprint": fingerprint(&m.public_key),
            })),
            "file": inner.path,
        })
    }

    /// Whether this machine's app gave its own key (`set_own`): its app can sign an allow
    /// for a peer that enrolled it (`server/peer_forward.rs`).
    pub fn has_own(&self) -> bool {
        self.own.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
    }

    /// `_acpmux/mac_approver_set {id, publicKey, name}` (the person only): this
    /// machine's app key, which `host enroll` enrolls on a peer. Memory only.
    pub fn set_own(&self, params: &Value) -> Result<Value, RpcError> {
        let mut parsed = parse_approvers(std::slice::from_ref(params))?;
        let own = parsed.pop();
        let fingerprint = own.as_ref().map(|o| fingerprint(&o.public_key));
        *self.own.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = own;
        Ok(json!({"fingerprint": fingerprint}))
    }

    /// Whether `decision` is an enrolled Mac's valid, unexpired signature
    /// over this exact answer to `request`, an answer a Mac may give
    /// ([`may_allow`]); then `commit` (the answer counting: its nonce spent).
    /// The set's lock is held from the key lookup through `commit`, so a
    /// reload that drops the Mac waits for an answer being committed. Lock
    /// order as `ApproverSet::verifies_then`: the prompt's lock (held by the
    /// caller), then this set's, then the spent-nonce store.
    #[allow(clippy::too_many_arguments)]
    pub fn verifies_then(
        &self,
        instance: &str,
        session: &str,
        permission: &str,
        request: &Value,
        option: &str,
        nonce: &str,
        answers: Option<&Value>,
        decision: &Value,
        now: u64,
        commit: impl FnOnce() -> bool,
    ) -> bool {
        let proof = MacProof { permission, request, option, nonce, answers, decision };
        self.all_verify_then(instance, session, std::slice::from_ref(&proof), now, commit)
    }

    /// [`Self::verifies_then`] for a group's members together (`permission_groups.rs`): each
    /// of `proofs` is an enrolled Mac's valid signature over its own answer, and then `commit`
    /// (all their nonces spent at once), under one hold of the set's lock. A reload that drops
    /// a Mac lands before the check or after `commit`, never between two members. None counts
    /// when `proofs` is empty or any one fails.
    pub fn all_verify_then(
        &self,
        instance: &str,
        session: &str,
        proofs: &[MacProof<'_>],
        now: u64,
        commit: impl FnOnce() -> bool,
    ) -> bool {
        if proofs.is_empty() {
            return false;
        }
        let mut inner = self.lock();
        refresh(&mut inner);
        proofs.iter().all(|p| verify(&inner, instance, session, p, now)) && commit()
    }
}

impl MacApprovers {
    /// Whether `signed` (`{approver, signature}`) is an enrolled Mac's signature over the raise
    /// of `session` to `policy` for the challenge `nonce` of daemon run `instance`
    /// ([`policy_message`]); then `commit` (the challenge spent), under the set's lock as
    /// [`Self::verifies_then`], so a reload that drops the Mac lands before or after it.
    pub fn policy_verifies_then(
        &self,
        instance: &str,
        session: &str,
        policy: &str,
        nonce: &str,
        signed: &Value,
        commit: impl FnOnce() -> bool,
    ) -> bool {
        let field = |f: &str| signed.get(f).and_then(Value::as_str);
        let (Some(id), Some(signature)) = (field("approver"), field("signature")) else {
            return false;
        };
        let Some(signature) = super::approvers::unhex(signature).filter(|s| s.len() == 64) else {
            return false;
        };
        let mut inner = self.lock();
        refresh(&mut inner);
        let Some(key) = inner.macs.iter().find(|m| m.id == id).map(|m| &m.public_key) else {
            return false;
        };
        ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
            .verify(&policy_message(instance, id, session, policy, nonce), &signature)
            .is_ok()
            && commit()
    }
}

/// The bytes an enrolled Mac signs for a policy raise: [`POLICY_DOMAIN`], then the daemon run,
/// the Mac's id, the session, the policy and the challenge nonce, each after one NUL.
pub fn policy_message(
    instance: &str,
    mac: &str,
    session: &str,
    policy: &str,
    nonce: &str,
) -> Vec<u8> {
    let mut out = POLICY_DOMAIN.as_bytes().to_vec();
    for part in [instance, mac, session, policy, nonce] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// One answer an enrolled Mac signed: the prompt, its request, the option, the prompt's nonce,
/// the answers (None for a tool's ask) and `_meta.acpmux.approverDecision`.
pub struct MacProof<'a> {
    pub permission: &'a str,
    pub request: &'a Value,
    pub option: &'a str,
    pub nonce: &'a str,
    pub answers: Option<&'a Value>,
    pub decision: &'a Value,
}

/// Whether `p.decision` is a Mac of `inner`'s valid, unexpired signature over `p`, an answer a
/// Mac may give ([`may_allow`]).
fn verify(inner: &Inner, instance: &str, session: &str, p: &MacProof<'_>, now: u64) -> bool {
    let field = |f: &str| p.decision.get(f).and_then(Value::as_str);
    let (Some(id), Some(signature)) = (field("approver"), field("signature")) else {
        return false;
    };
    let Some(expires) = p.decision.get("expiresAt").and_then(Value::as_u64) else { return false };
    if expires < now || expires > now.saturating_add(MAX_LIFETIME) {
        return false;
    }
    if !may_allow(p.request, p.option, p.answers) {
        return false;
    }
    let Some(signature) = super::approvers::unhex(signature).filter(|s| s.len() == 64) else {
        return false;
    };
    let Some(key) = inner.macs.iter().find(|m| m.id == id).map(|m| &m.public_key) else {
        return false;
    };
    let message = message(&Parts {
        instance,
        mac: id,
        session,
        permission: p.permission,
        tool_call: p
            .request
            .pointer("/toolCall/toolCallId")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        option: p.option,
        nonce: p.nonce,
        expires_at: expires,
        answers: &answers_digest(p.answers),
    });
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(&message, &signature)
        .is_ok()
}

/// Reads the file again when it is not what was read last. A file that is
/// missing, unreadable, too large or not a Macs file enrolls no Mac.
fn refresh(inner: &mut Inner) {
    let Some(path) = inner.path.clone() else { return };
    let stamp = std::fs::symlink_metadata(&path).ok().map(|m| (m.len(), m.modified().ok()));
    if stamp.is_some() && stamp == inner.stamp {
        return;
    }
    inner.stamp = stamp;
    inner.macs = match read(&path) {
        Ok(macs) => macs,
        Err(e) => {
            tracing::warn!("{}: {e:#}; no Mac may allow until it is fixed", path.display());
            Vec::new()
        }
    };
}

/// The Macs in `path`; none when it does not exist.
pub fn read(path: &Path) -> anyhow::Result<Vec<Approver>> {
    use std::io::Read;
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
        Ok(_) => {}
    }
    let file = crate::config::private_state_file(path)?;
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= MAX_BYTES, "larger than {MAX_BYTES} bytes");
    let v: Value = serde_json::from_slice(&bytes)?;
    let list = v.get("macs").and_then(Value::as_array).cloned().unwrap_or_default();
    parse_approvers(&list).map_err(|e| anyhow::anyhow!("{}", e.message))
}

/// Whether an enrolled Mac may give `option` (with `answers`) to `request`: a
/// one-time allow offered once, of a tool's ask (no answers) or an agent's
/// question (with answers); never a plan, a mode switch or a folder-trust
/// card (each widens what runs, or stays the person's on this machine).
pub fn may_allow(request: &Value, option: &str, answers: Option<&Value>) -> bool {
    let offered: Vec<&Value> = request["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|o| o["optionId"] == option)
        .collect();
    if !matches!(offered.as_slice(), [one] if one["kind"] == "allow_once") {
        return false;
    }
    let tool = &request["toolCall"];
    let widens = tool["kind"] == "switch_mode"
        || super::questions::trust_cwd(request).is_some()
        || tool.pointer("/_meta/claude/tool").and_then(Value::as_str) == Some("ExitPlanMode");
    let answers = answers.filter(|a| !a.is_null());
    !widens
        && match answers {
            None => super::permission_groups::plain_tool_ask(request),
            Some(_) => super::questions::needs_person(request),
        }
}

/// What an enrolled Mac signs.
pub struct Parts<'a> {
    pub instance: &'a str,
    pub mac: &'a str,
    pub session: &'a str,
    pub permission: &'a str,
    /// The prompt's `toolCall.toolCallId`, empty for none.
    pub tool_call: &'a str,
    pub option: &'a str,
    pub nonce: &'a str,
    pub expires_at: u64,
    /// `approvers::answers_digest` of the answers, empty for none.
    pub answers: &'a str,
}

/// The signed bytes: the domain, then each part after one NUL.
pub fn message(p: &Parts<'_>) -> Vec<u8> {
    let expires = p.expires_at.to_string();
    let mut out = DOMAIN.as_bytes().to_vec();
    for part in [
        p.instance,
        p.mac,
        p.session,
        p.permission,
        p.tool_call,
        p.option,
        p.nonce,
        &expires,
        p.answers,
    ] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

#[cfg(test)]
#[path = "mac_approvers_tests.rs"]
mod tests;
