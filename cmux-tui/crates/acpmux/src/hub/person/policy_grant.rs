//! A policy raise the person approved in another machine's app (#26987: person-approved policy
//! raises on owned peers).
//!
//! The person's app on a Mac shows a chat that lives on this daemon and picks a policy that does
//! not ask. The request reaches this daemon over a peer link or a remote connection, which is
//! never the person: anything that read this machine's peer token, or that runs as the user on
//! the Mac, can open such a link and send the same request, and a marker the forwarding daemon
//! adds proves nothing here (its own person key is not this daemon's, and a value it sends in
//! the handshake is one any peer-token client can choose). So this daemon counts such a raise
//! only with a proof that only the person's own app can make, and checks it itself, with a
//! credential the app enrolled here before:
//!
//! - this daemon run's person key (`hub/person.rs`), which the app holds when it started this
//!   daemon itself (a keyed start over ssh or Cloud, `AcpmuxRemotePersonKeys`), the key a
//!   relayed allow is proved with: `_meta.acpmux` [`PROOF_FIELD`] = lowercase hex
//!   HMAC-SHA256(key, "acpmux-person-policy-v1" 0 instance 0 session 0 policy 0 nonce)
//!   ([`policy_proof`]);
//! - or an enrolled Mac's approver key (`hub/mac_approvers.rs`, P-256, enrolled only by a write
//!   of `mac-approvers.json` on this machine, never over RPC), which the app holds for a chat of
//!   a peer of its Mac's daemon: `_meta.acpmux` [`APPROVER_FIELD`] = `{approver, signature}`
//!   over `mac_approvers::policy_message`, a domain of its own.
//!
//! Either covers a nonce this daemon issued, so a captured proof never counts twice:
//!
//! - A raise from a client that is not the person, without a proof that counts, is refused as
//!   before. When the chat is this daemon's own and the raise is refused only for the person
//!   (`remote.policy_refused`, `permission.person_required`), `error.data` carries
//!   [`CHALLENGE_FIELD`] `{sessionId, personInstance, nonce}`: this daemon's id of the chat, this
//!   daemon run and a new random nonce, open for [`CHALLENGE_TTL`].
//! - The app sends the raise again with `_meta.acpmux` [`NONCE_FIELD`] = that nonce and one of
//!   the proofs above over the exact `policy` string it sends.
//! - It counts when the proof verifies under this run's key or an enrolled Mac's, and the nonce
//!   is open, was issued by this run for that same chat and has not expired. The nonce is taken
//!   out when it counts (for a Mac, under the Mac set's lock, so a revocation lands before or
//!   after it), so a proof counts once. A proof made for another chat, policy, daemon run,
//!   nonce or key, a decision proof or signature, or one sent again counts for nothing.
//! - It is counted once per request, before any check reads it (`server/requests.rs`), so the
//!   remote guard's Web rule, the person check and the change all see the same answer, and the
//!   change applies to the chat the proof was checked for, never to what the request's key
//!   names by then. A
//!   daemon that only forwards the raise names no such chat of its own: it neither counts nor
//!   issues a challenge, and the proof goes on to the daemon that owns the chat.
//! - It covers `_acpmux/set_policy` of that one chat only: never a daemon, family or preset
//!   default, a rule or a mode, and full access stays bound by `refuse_full_access_policy`. A
//!   chat at the VM boundary still refuses everyone but its owner's devices first
//!   (`hub/vm_boundary.rs`).
//!
//! Residual risks:
//! - The proof covers ids, not what the app shows. A forwarder that hands the app another
//!   chat's challenge gets that chat signed, so the app signs only a challenge whose
//!   `sessionId` is the owning daemon's id of the chat the person picked, as it does for a
//!   relayed prompt's ids.
//! - Anyone who may send the request may have a challenge issued (a refused raise). At most
//!   [`CHALLENGE_LIMIT`] are open, the oldest dropped first: a flood can make the person's
//!   raise fail and be asked again, never count without a proof.

use super::{PersonGate, new_nonce, valid_key};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// `error.data` of a refused raise: the challenge the app proves.
pub const CHALLENGE_FIELD: &str = "personPolicyChallenge";
/// `_meta.acpmux` field of a proved raise: the challenge's nonce.
pub const NONCE_FIELD: &str = "policyNonce";
/// `_meta.acpmux` field of a raise proved with this run's person key.
pub const PROOF_FIELD: &str = "personPolicy";
/// `_meta.acpmux` field of a raise signed by an enrolled Mac: `{approver, signature}`.
pub const APPROVER_FIELD: &str = "approverPolicy";
/// At most this many challenges are open at once.
pub const CHALLENGE_LIMIT: usize = 64;
/// A challenge counts this long after it was issued.
pub const CHALLENGE_TTL: Duration = Duration::from_secs(120);

/// One open challenge: its nonce, the chat it is for, and when it was issued.
pub(super) struct Challenge {
    nonce: String,
    session: String,
    at: Instant,
}

/// The person's proof that they set `policy` on `session` with the challenge `nonce`, on daemon
/// run `instance`, as lowercase hex; None when `key` is not a person key.
pub fn policy_proof(
    key: &str,
    instance: &str,
    session: &str,
    policy: &str,
    nonce: &str,
) -> Option<String> {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).filter(|_| valid_key(key))?;
    let mut message = b"acpmux-person-policy-v1".to_vec();
    for part in [instance, session, policy, nonce] {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    Some(hex(&hmac_sha256(&key, &message)))
}

impl PersonGate {
    /// A new challenge for this daemon's chat `session`.
    pub fn policy_challenge(&self, session: &str) -> Value {
        let nonce = new_nonce();
        let now = Instant::now();
        let mut open = self.open_policy_challenges();
        open.retain(|c| now.duration_since(c.at) <= CHALLENGE_TTL);
        while open.len() >= CHALLENGE_LIMIT {
            open.pop_front();
        }
        open.push_back(Challenge { nonce: nonce.clone(), session: session.to_owned(), at: now });
        json!({"sessionId": session, "personInstance": self.instance(), "nonce": nonce})
    }

    fn open_policy_challenges(
        &self,
    ) -> std::sync::MutexGuard<'_, std::collections::VecDeque<Challenge>> {
        self.policy_challenges.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Takes the open challenge `nonce` of `session`; false when there is none, it was for
    /// another chat or it expired (a challenge for another chat stays open).
    fn spend_policy_challenge(&self, session: &str, nonce: &str) -> bool {
        let now = Instant::now();
        let mut open = self.open_policy_challenges();
        let Some(index) = open.iter().position(|c| c.nonce == nonce && c.session == session) else {
            return false;
        };
        open.remove(index).is_some_and(|c| now.duration_since(c.at) <= CHALLENGE_TTL)
    }

    /// Whether `meta` (`_meta.acpmux`) proves the person's raise of `session` to `policy` for
    /// an open challenge of this run, with this run's key or an enrolled Mac's signature; when
    /// it does, the challenge is spent.
    pub fn take_policy_grant(&self, session: &str, policy: &str, meta: &Value) -> bool {
        let Some(nonce) = meta.get(NONCE_FIELD).and_then(Value::as_str) else { return false };
        let instance = self.instance();
        if let Some(proof) = meta.get(PROOF_FIELD).and_then(Value::as_str) {
            let key = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
            return key
                .and_then(|k| policy_proof(&k, instance, session, policy, nonce))
                .is_some_and(|expected| cmux_local_auth::tokens_match(proof, &expected))
                && self.spend_policy_challenge(session, nonce);
        }
        meta.get(APPROVER_FIELD).is_some_and(|signed| {
            self.macs.policy_verifies_then(instance, session, policy, nonce, signed, || {
                self.spend_policy_challenge(session, nonce)
            })
        })
    }
}

impl crate::hub::Hub {
    /// The chat here that `m`, an `_acpmux/set_policy` with a person's policy proof that counts
    /// (module docs), raises; its challenge is spent when it does. Called once per request. The
    /// request acts on this very chat from here on, never on what its key names later: a rename
    /// or a purge while it waits could make the key name another chat, which no proof covers.
    pub fn take_person_policy(
        &self,
        m: &str,
        params: &Value,
    ) -> Option<std::sync::Arc<crate::hub::Session>> {
        if m != crate::rpc::method::MUX_SET_POLICY {
            return None;
        }
        let meta = params.pointer("/_meta/acpmux")?;
        let policy = params.get("policy").and_then(Value::as_str)?;
        let session = self.resolve(crate::server::session_key(params).ok()?).ok()?;
        self.person.take_policy_grant(&session.id, policy, meta).then_some(session)
    }

    /// `e`, a raise of a chat here refused only for the person (`refused_as`), with a challenge
    /// the person's app can prove (module docs); any other error as it is.
    pub(crate) fn with_policy_challenge(
        &self,
        m: &str,
        params: &Value,
        refused_as: &[&str],
        mut e: RpcError,
    ) -> RpcError {
        if m != crate::rpc::method::MUX_SET_POLICY
            || super::asking_policy_value(params.get("policy"))
        {
            return e;
        }
        let Some(data) = e.data.as_mut().and_then(Value::as_object_mut) else { return e };
        if !data.get("reason").and_then(Value::as_str).is_some_and(|r| refused_as.contains(&r)) {
            return e;
        }
        let Ok(key) = crate::server::session_key(params) else { return e };
        let Ok(session) = self.resolve(key) else { return e };
        data.insert(CHALLENGE_FIELD.into(), self.person.policy_challenge(&session.id));
        e
    }
}

#[cfg(test)]
#[path = "policy_grant_tests.rs"]
mod tests;
