//! Trusted approvers: the person's own phones may allow a prompt, and answer
//! a question, with a Secure Enclave signature (cnx-ios
//! `verify/phone-approvals.md`).
//!
//! - The person's app enrolls each approver with
//!   `_acpmux/approvers_set {macDevice, approvers: [{id, publicKey, name}]}`
//!   on its person connection; nobody else may (`person_required`). The set
//!   lives in this daemon's memory only, never in a file: an agent that can
//!   write the user's files must not be able to add its own key. The app
//!   sends it again to each daemon run.
//! - A phone's `_acpmux/permission_respond` then counts with
//!   `_meta.acpmux = {decisionNonce, approverDecision: {approver, expiresAt,
//!   signature}}`. `signature` is ECDSA P-256 / SHA-256, raw `r || s` as
//!   lowercase hex, over [`message`]: the daemon run, the Mac's device id,
//!   the approver, the session, the permission, the option, the prompt's
//!   nonce, the expiry and the digest of the answers. It counts once (the
//!   person gate's spent-nonce store) and only until `expiresAt`, which may be
//!   at most [`MAX_LIFETIME`] ahead.
//! - The payload covers the answers ([`answers_digest`]), so a signed answer
//!   to a question cannot be swapped for another one on the way.

use super::*;

/// At most this many approvers.
pub const MAX_APPROVERS: usize = 16;
/// The furthest ahead an approver's `expiresAt` may be, in seconds.
pub const MAX_LIFETIME: u64 = 300;
/// `_meta.acpmux` field of a phone's signed decision.
pub const DECISION_FIELD: &str = "approverDecision";
/// The domain of an approver's decision signature.
const DOMAIN: &str = "acpmux-approver-decision-v1";

/// One enrolled approver.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Approver {
    pub id: String,
    /// The 65-byte uncompressed P-256 point.
    pub public_key: Vec<u8>,
    pub name: String,
}

/// The enrolled approvers and the Mac they approve for.
#[derive(Default)]
pub struct ApproverSet {
    inner: StdMutex<(String, Vec<Approver>)>,
}

impl ApproverSet {
    /// Replaces the set (`_acpmux/approvers_set`, the person only).
    pub fn set(&self, params: &Value) -> Result<Value, RpcError> {
        let mac =
            params.get("macDevice").and_then(Value::as_str).filter(|m| valid_id(m)).ok_or_else(
                || RpcError::invalid_params("macDevice must be 1 to 128 of [A-Za-z0-9_.:-]"),
            )?;
        let list = params
            .get("approvers")
            .and_then(Value::as_array)
            .ok_or_else(|| RpcError::invalid_params("approvers must be a list"))?;
        let approvers = parse_approvers(list)?;
        let count = approvers.len();
        *self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            (mac.to_owned(), approvers);
        Ok(json!({"count": count}))
    }

    /// This Mac's paired phones as a peer enrolls them (`host approvals enroll`, its
    /// `mac-approvers.json`): `{id, publicKey, name}`, each id [`peer_phone_id`]. A phone whose
    /// id does not fit is left out. Public keys only.
    pub fn peer_entries(&self) -> Vec<Value> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        inner
            .1
            .iter()
            .filter_map(|a| {
                let id = peer_phone_id(&inner.0, &a.id)?;
                Some(json!({"id": id, "publicKey": hex(&a.public_key), "name": a.name,
                            "fingerprint": fingerprint(&a.public_key)}))
            })
            .collect()
    }

    /// [`peer_phone_prefix`] of this Mac's device id; None before the app sent its set.
    pub fn peer_prefix(&self) -> Option<String> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        (!inner.0.is_empty()).then(|| peer_phone_prefix(&inner.0))
    }

    /// `_acpmux/approvers` (the person only): ids, names and key fingerprints.
    pub fn list(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        json!({
            "macDevice": inner.0,
            "approvers": inner.1.iter().map(|a| json!({
                "id": a.id, "name": a.name, "fingerprint": fingerprint(&a.public_key),
            })).collect::<Vec<_>>(),
        })
    }

    /// Whether `decision` is an enrolled approver's valid, unexpired
    /// signature over this exact answer. Spends nothing.
    #[allow(clippy::too_many_arguments)]
    pub fn verifies(
        &self,
        instance: &str,
        session: &str,
        permission: &str,
        option: &str,
        nonce: &str,
        answers: Option<&Value>,
        decision: &Value,
        now: u64,
    ) -> bool {
        self.verifies_then(
            instance,
            session,
            permission,
            option,
            nonce,
            answers,
            decision,
            now,
            || true,
        )
    }

    /// `verifies`, then `commit` (the answer counting: its nonce spent) when it does; whether
    /// both did. The set's lock is held from the key lookup through `commit`, so a revocation
    /// (`set`) waits for an answer being committed, and once it returns no signature of a
    /// removed approver counts (#24233, landing term 4). `commit` must not await or take this
    /// set's lock. Lock order: the prompt's lock (`session.permissions`, held by the caller),
    /// then this set's, then the person gate's spent-nonce store (`spend_decision`); nothing
    /// takes them the other way round (`set`, `list` and `verifies` hold this one alone).
    #[allow(clippy::too_many_arguments)]
    pub fn verifies_then(
        &self,
        instance: &str,
        session: &str,
        permission: &str,
        option: &str,
        nonce: &str,
        answers: Option<&Value>,
        decision: &Value,
        now: u64,
        commit: impl FnOnce() -> bool,
    ) -> bool {
        let field = |f: &str| decision.get(f).and_then(Value::as_str);
        let (Some(id), Some(signature)) = (field("approver"), field("signature")) else {
            return false;
        };
        let Some(expires) = decision.get("expiresAt").and_then(Value::as_u64) else { return false };
        if expires < now || expires > now.saturating_add(MAX_LIFETIME) {
            return false;
        }
        let Some(signature) = unhex(signature).filter(|s| s.len() == 64) else { return false };
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(key) = inner.1.iter().find(|a| a.id == id).map(|a| &a.public_key) else {
            return false;
        };
        let message = message(&Parts {
            instance,
            mac: &inner.0,
            approver: id,
            session,
            permission,
            option,
            nonce,
            expires_at: expires,
            answers: &answers_digest(answers),
        });
        ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
            .verify(&message, &signature)
            .is_ok()
            && commit()
    }
}

/// The approvers of a list `[{id, publicKey, name}]`, checked whole: at most
/// [`MAX_APPROVERS`], each id once, each key a 65-byte uncompressed P-256 point as hex.
/// The enrolled Macs' file is read with it too (`mac_approvers.rs`).
pub fn parse_approvers(list: &[Value]) -> Result<Vec<Approver>, RpcError> {
    if list.len() > MAX_APPROVERS {
        return Err(RpcError::invalid_params(format!("at most {MAX_APPROVERS} approvers")));
    }
    let mut approvers = Vec::with_capacity(list.len());
    for entry in list {
        let id =
            entry.get("id").and_then(Value::as_str).filter(|i| valid_id(i)).ok_or_else(|| {
                RpcError::invalid_params("approver id must be 1 to 128 of [A-Za-z0-9_.:-]")
            })?;
        let public_key = entry
            .get("publicKey")
            .and_then(Value::as_str)
            .and_then(unhex)
            .filter(|k| k.len() == 65 && k.first() == Some(&4))
            .ok_or_else(|| {
                RpcError::invalid_params(
                    "publicKey must be a 65-byte uncompressed P-256 point as hex",
                )
            })?;
        let name: String = entry
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .chars()
            .filter(|c| !c.is_control())
            .take(64)
            .collect();
        if approvers.iter().any(|a: &Approver| a.id == id) {
            return Err(RpcError::invalid_params(format!("approver {id} is listed twice")));
        }
        approvers.push(Approver { id: id.to_owned(), public_key, name });
    }
    Ok(approvers)
}

/// What an approver signs.
pub struct Parts<'a> {
    pub instance: &'a str,
    pub mac: &'a str,
    pub approver: &'a str,
    pub session: &'a str,
    pub permission: &'a str,
    pub option: &'a str,
    pub nonce: &'a str,
    pub expires_at: u64,
    /// [`answers_digest`] of the answers, empty for none.
    pub answers: &'a str,
}

/// The signed bytes: the domain, then each part after one NUL.
pub fn message(p: &Parts<'_>) -> Vec<u8> {
    let expires = p.expires_at.to_string();
    let mut out = DOMAIN.as_bytes().to_vec();
    for part in [
        p.instance,
        p.mac,
        p.approver,
        p.session,
        p.permission,
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

/// Lowercase hex SHA-256 of [`canonical_json`] of the answers; empty for none.
pub fn answers_digest(answers: Option<&Value>) -> String {
    use sha2::Digest;
    match answers.filter(|a| !a.is_null()) {
        None => String::new(),
        Some(a) => {
            let mut text = String::new();
            canonical_json(a, &mut text);
            hex(&sha2::Sha256::digest(text.as_bytes()))
        }
    }
}

/// JSON with object keys in byte order, no whitespace, and only `"`, `\`
/// and control characters escaped (`\b \f \n \r \t`, else `\u00xx`). The
/// phone writes the same bytes (`ApprovalPayload.canonicalJSON`).
pub fn canonical_json(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => canonical_string(s, out),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_json(x, out);
            }
            out.push(']');
        }
        Value::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_string(k, out);
                out.push(':');
                canonical_json(&o[k], out);
            }
            out.push('}');
        }
    }
}

fn canonical_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// The start of every paired phone's id in a peer's enrolled Macs ([`peer_phone_prefix`]).
pub const PEER_PHONE: &str = "phone:";

/// The start of every id a peer gives this Mac's paired phones: `phone:`, then the first 6
/// bytes of the SHA-256 of the Mac's device id as hex, then `:`. `host approvals` finds and
/// removes this Mac's phones on a peer by it, and never another Mac's.
pub fn peer_phone_prefix(mac_device: &str) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(mac_device.as_bytes());
    format!("{PEER_PHONE}{}:", hex(digest.get(..6).unwrap_or_default()))
}

/// The id a paired phone has in a peer's enrolled Macs ([`peer_phone_prefix`], then the phone's
/// id). The phone signs a peer chat's answer as this id, with the enrolled Mac's message
/// (`mac_approvers.rs`), and computes it the same way (the iOS app's `PeerApprovalPayload`). None when
/// it would not be a valid id.
pub fn peer_phone_id(mac_device: &str, phone: &str) -> Option<String> {
    let id = format!("{}{phone}", peer_phone_prefix(mac_device));
    valid_id(&id).then_some(id)
}

/// The first 8 bytes of the key's SHA-256, as hex.
pub fn fingerprint(key: &[u8]) -> String {
    use sha2::Digest;
    hex(&sha2::Sha256::digest(key)[..8])
}

pub fn valid_id(s: &str) -> bool {
    (1..=128).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(super) fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2)
        || !s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

/// Seconds since the Unix epoch.
pub fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
