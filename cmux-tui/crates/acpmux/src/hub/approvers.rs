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
            .filter(|k| k.len() == 65 && k[0] == 4)
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
mod tests {
    use super::*;
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};

    fn key() -> EcdsaKeyPair {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
    }

    fn sign(k: &EcdsaKeyPair, p: &Parts<'_>) -> String {
        let rng = ring::rand::SystemRandom::new();
        hex(k.sign(&rng, &message(p)).unwrap().as_ref())
    }

    fn parts<'a>(expires: u64, answers: &'a str) -> Parts<'a> {
        Parts {
            instance: "inst",
            mac: "mac-1",
            approver: "phone-1",
            session: "s1",
            permission: "p1",
            option: "allow",
            nonce: "n1",
            expires_at: expires,
            answers,
        }
    }

    fn enrolled(k: &EcdsaKeyPair) -> ApproverSet {
        let set = ApproverSet::default();
        set.set(&json!({"macDevice": "mac-1", "approvers": [
            {"id": "phone-1", "publicKey": hex(k.public_key().as_ref()), "name": "iPhone"}]}))
            .unwrap();
        set
    }

    fn check(
        set: &ApproverSet,
        sig: &str,
        expires: u64,
        answers: Option<&Value>,
        now: u64,
    ) -> bool {
        let decision = json!({"approver": "phone-1", "expiresAt": expires, "signature": sig});
        set.verifies("inst", "s1", "p1", "allow", "n1", answers, &decision, now)
    }

    #[test]
    fn the_wire_payload_is_fixed() {
        // The same vector is in the phone's ApprovalPayloadTests.
        use sha2::Digest;
        let nonce = "ab".repeat(32);
        let answers =
            json!({"Which?": "B", "a\"b": ["x\ny", "\u{1}"], "codex": {"answers": ["é"]}});
        let mut text = String::new();
        canonical_json(&answers, &mut text);
        assert_eq!(text, r#"{"Which?":"B","a\"b":["x\ny","\u0001"],"codex":{"answers":["é"]}}"#);
        let digest = answers_digest(Some(&answers));
        assert_eq!(digest, "44ba30ad88bf4d244b42c361e7ba2a97441780fce0cdfd2a175df95d6e2d6fc8");
        for (answers, expected) in [
            ("", "3093d49d440c85bb9f357d0940a5bbd0e822c944fdfe650e9faae0b58afb6c2c"),
            (digest.as_str(), "764300d7c596ec827c3d7ffb2b8b5819816151589c5edce1feecd0937b125fe8"),
        ] {
            let m = message(&Parts {
                instance: "0123abcd",
                mac: "9f1c2d3e-0000-4000-8000-000000000001",
                approver: "6a7b8c9d-0000-4000-8000-000000000002",
                session: "sess-1",
                permission: "perm-7",
                option: "allow_once",
                nonce: &nonce,
                expires_at: 1_760_000_000,
                answers,
            });
            assert_eq!(hex(&sha2::Sha256::digest(&m)), expected);
        }
    }

    #[test]
    fn a_valid_signature_counts_and_every_change_fails() {
        let k = key();
        let set = enrolled(&k);
        let now = 1_000;
        let good = sign(&k, &parts(now + 120, ""));
        assert!(check(&set, &good, now + 120, None, now));
        // Expired, too far ahead, a changed expiry, another key, an unknown approver.
        assert!(!check(&set, &good, now + 120, None, now + 121));
        let far = sign(&k, &parts(now + MAX_LIFETIME + 1, ""));
        assert!(!check(&set, &far, now + MAX_LIFETIME + 1, None, now));
        assert!(!check(&set, &good, now + 119, None, now));
        let other = sign(&key(), &parts(now + 120, ""));
        assert!(!check(&set, &other, now + 120, None, now));
        let decision = json!({"approver": "phone-2", "expiresAt": now + 120, "signature": good});
        assert!(!set.verifies("inst", "s1", "p1", "allow", "n1", None, &decision, now));
        // Another option, nonce, session or daemon run.
        let decision = json!({"approver": "phone-1", "expiresAt": now + 120, "signature": good});
        assert!(!set.verifies("inst", "s1", "p1", "deny", "n1", None, &decision, now));
        assert!(!set.verifies("inst", "s1", "p1", "allow", "n2", None, &decision, now));
        assert!(!set.verifies("inst", "s2", "p1", "allow", "n1", None, &decision, now));
        assert!(!set.verifies("other", "s1", "p1", "allow", "n1", None, &decision, now));
        // Signed with answers: only those answers count.
        let answers = json!({"q": "A"});
        let digest = answers_digest(Some(&answers));
        let signed = sign(&k, &parts(now + 60, &digest));
        assert!(check(&set, &signed, now + 60, Some(&answers), now));
        assert!(!check(&set, &signed, now + 60, Some(&json!({"q": "B"})), now));
        assert!(!check(&set, &signed, now + 60, None, now));
        assert!(!check(&set, &good, now + 120, Some(&answers), now));
    }

    #[test]
    fn revoking_is_replacing_the_set() {
        let k = key();
        let set = enrolled(&k);
        let good = sign(&k, &parts(200, ""));
        assert!(check(&set, &good, 200, None, 100));
        set.set(&json!({"macDevice": "mac-1", "approvers": []})).unwrap();
        assert!(!check(&set, &good, 200, None, 100));
        // A signature for another Mac never counts here.
        set.set(&json!({"macDevice": "mac-2", "approvers": [
            {"id": "phone-1", "publicKey": hex(k.public_key().as_ref()), "name": "iPhone"}]}))
            .unwrap();
        assert!(!check(&set, &good, 200, None, 100));
    }

    /// Landing term 4 of #24233: revoking the phone stops even a signature made before. A
    /// revocation sent while a signed answer is being committed returns only after that commit,
    /// and from then on the same signature counts nothing.
    #[test]
    fn a_revocation_during_a_commit_waits_for_it_and_then_the_signature_counts_nothing() {
        use std::time::Duration;
        let k = key();
        let set = std::sync::Arc::new(enrolled(&k));
        let good = sign(&k, &parts(200, ""));
        let decision = json!({"approver": "phone-1", "expiresAt": 200, "signature": good});
        let (revoked, returned) = std::sync::mpsc::channel();
        let revoker = set.clone();
        let committed =
            set.verifies_then("inst", "s1", "p1", "allow", "n1", None, &decision, 100, || {
                std::thread::spawn(move || {
                    revoker.set(&json!({"macDevice": "mac-1", "approvers": []})).unwrap();
                    let _ = revoked.send(());
                });
                // The commit is in flight: the revocation has not returned.
                returned.recv_timeout(Duration::from_millis(300)).is_err()
            });
        assert!(committed, "the revocation returned while the answer was being committed");
        returned.recv_timeout(Duration::from_secs(10)).expect("the revocation returns");
        assert!(!check(&set, &good, 200, None, 100), "the old signature counts after revocation");
    }

    #[test]
    fn bad_sets_are_refused_whole() {
        let set = ApproverSet::default();
        let k = hex(key().public_key().as_ref());
        for bad in [
            json!({"approvers": []}),
            json!({"macDevice": "m", "approvers": [{"id": "a b", "publicKey": k}]}),
            json!({"macDevice": "m", "approvers": [{"id": "a", "publicKey": "04"}]}),
            json!({"macDevice": "m", "approvers": [{"id": "a", "publicKey": k}, {"id": "a", "publicKey": k}]}),
            json!({"macDevice": "m", "approvers": (0..=MAX_APPROVERS).map(|i| json!({"id": format!("p{i}"), "publicKey": k})).collect::<Vec<_>>()}),
        ] {
            assert!(set.set(&bad).is_err(), "{bad}");
        }
        assert_eq!(set.list()["approvers"], json!([]));
    }
}
