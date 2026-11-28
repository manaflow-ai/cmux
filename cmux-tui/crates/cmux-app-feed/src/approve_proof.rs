//! The phone approve proof's rules (`FeedApproveProofCheck`, cx-aocz): the presence keys of a
//! `user.presence_key.list` value, this Mac's context from its install token, and every check
//! before the signature. The P-256 verify stays in the app (CryptoKit): the app asks
//! [`precheck`], then verifies the signature with the key it returns.
//!
//! Fail closed: a key without `usable_from` is dropped, a missing `revoked_at` counts as
//! revoked, and the flags count only as JSON booleans.

use std::collections::BTreeMap;

use base64::Engine;
use base64::alphabet::STANDARD;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The oldest proof accepted, and the clock skew allowed ahead (ms).
pub const MAX_AGE_MS: f64 = 300_000.0;
pub const MAX_SKEW_MS: f64 = 60_000.0;

const ISSUER_PREFIX: &str = "https://cmux-api/";

/// One presence key.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Key {
    pub platform: String,
    /// The X9.63 public key: 0x04, x, y.
    #[serde(serialize_with = "as_base64")]
    pub public_key: Vec<u8>,
    pub attested: bool,
    /// When the key's cooldown ends (ms since 1970).
    pub usable_from_ms: f64,
    pub revoked: bool,
    pub install_active: bool,
}

fn as_base64<S: serde::Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// Who this Mac is, from its own install token (`iss`, `sub`, `inst`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Context {
    pub environment: String,
    pub user: String,
    pub mac_install: String,
}

/// The proof a phone's answer carries.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Proof {
    pub install: String,
    pub timestamp_ms: i64,
}

/// Why a proof fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    NoProof,
    OtherInstall,
    NoKey,
    NotPhone,
    NotAttested,
    Revoked,
    CoolingDown,
    Stale,
}

/// Foundation's `Data(base64Encoded:)` after the URL alphabet is mapped back and padding added.
pub fn base64_url(text: &str) -> Option<Vec<u8>> {
    let mut base: String = text
        .chars()
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            c => c,
        })
        .collect();
    let pad = (4 - base.chars().count() % 4) % 4;
    base.extend(std::iter::repeat_n('=', pad));
    let engine = GeneralPurpose::new(
        &STANDARD,
        GeneralPurposeConfig::new()
            .with_decode_allow_trailing_bits(true)
            .with_decode_padding_mode(DecodePaddingMode::RequireCanonical),
    );
    engine.decode(base).ok()
}

fn json_true(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(true)))
}

/// The keys of a `user.presence_key.list` value, by install (a later entry for an install wins).
pub fn keys(value: &Value) -> BTreeMap<String, Key> {
    let mut out = BTreeMap::new();
    let Some(entries) = value.get("keys").and_then(Value::as_array) else { return out };
    // `as? [[String: Any]]` drops the whole list when any entry is not an object.
    if !entries.iter().all(Value::is_object) {
        return out;
    }
    for entry in entries {
        let Some(install) = entry.get("install").and_then(Value::as_str) else { continue };
        let Some(jwk) = entry.get("jwk").filter(|j| j.is_object()) else { continue };
        let coordinate = |name: &str| {
            jwk.get(name).and_then(Value::as_str).and_then(base64_url).filter(|b| b.len() == 32)
        };
        let (Some(x), Some(y)) = (coordinate("x"), coordinate("y")) else { continue };
        let Some(usable_from_ms) = entry.get("usable_from").and_then(Value::as_f64) else {
            continue;
        };
        let mut public_key = Vec::with_capacity(65);
        public_key.push(0x04);
        public_key.extend(x);
        public_key.extend(y);
        out.insert(
            install.to_owned(),
            Key {
                platform: entry.get("platform").and_then(Value::as_str).unwrap_or("").to_owned(),
                public_key,
                attested: json_true(entry.get("attested")),
                usable_from_ms,
                revoked: !matches!(entry.get("revoked_at"), Some(Value::Null)),
                install_active: json_true(entry.get("install_active")),
            },
        );
    }
    out
}

/// This Mac's context from its install token's claims.
pub fn context(token: &str) -> Option<Context> {
    let parts = crate::swift_split(token, '.', usize::MAX);
    let [_, claims, _] = parts.as_slice() else { return None };
    let claims: Value = serde_json::from_slice(&base64_url(claims)?).ok()?;
    let text = |name: &str| claims.get(name).and_then(Value::as_str).map(str::to_owned);
    let issuer = text("iss")?;
    let environment = issuer.strip_prefix(ISSUER_PREFIX)?.to_owned();
    let user = text("sub").filter(|u| !u.is_empty())?;
    let mac_install = text("inst").filter(|i| !i.is_empty())?;
    if environment.is_empty() {
        return None;
    }
    Some(Context { environment, user, mac_install })
}

/// Every check before the signature, in the app's order; the key whose signature the app then
/// verifies on success.
pub fn precheck<'a>(
    proof: Option<&Proof>,
    by: &str,
    keys: &'a BTreeMap<String, Key>,
    now_ms: f64,
) -> Result<&'a Key, Failure> {
    let proof = proof.ok_or(Failure::NoProof)?;
    if proof.install != by {
        return Err(Failure::OtherInstall);
    }
    // The time first: it needs no key, so a stale proof is named as such.
    let signed = proof.timestamp_ms as f64;
    if !(signed <= now_ms + MAX_SKEW_MS && now_ms - signed <= MAX_AGE_MS) {
        return Err(Failure::Stale);
    }
    let key = keys.get(&proof.install).ok_or(Failure::NoKey)?;
    if key.platform != "ios" {
        return Err(Failure::NotPhone);
    }
    if !key.attested {
        return Err(Failure::NotAttested);
    }
    if key.revoked || !key.install_active {
        return Err(Failure::Revoked);
    }
    if key.usable_from_ms > now_ms {
        return Err(Failure::CoolingDown);
    }
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn b64u(bytes: &[u8]) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
    }

    fn entry(install: &str) -> Value {
        json!({
            "install": install, "platform": "ios",
            "jwk": {"x": b64u(&[1; 32]), "y": b64u(&[2; 32])},
            "usable_from": 1000, "revoked_at": null, "attested": true, "install_active": true,
        })
    }

    fn with(install: &str, change: impl FnOnce(&mut serde_json::Map<String, Value>)) -> Value {
        let mut e = entry(install);
        change(e.as_object_mut().unwrap());
        e
    }

    #[test]
    fn keys_read_a_good_entry() {
        let got = keys(&json!({"keys": [entry("p1")]}));
        let key = &got["p1"];
        assert_eq!(key.public_key.len(), 65);
        assert_eq!(key.public_key[0], 4);
        assert_eq!(&key.public_key[1..33], &[1; 32]);
        assert_eq!(&key.public_key[33..], &[2; 32]);
        assert!(key.attested && key.install_active && !key.revoked);
        assert_eq!(key.usable_from_ms, 1000.0);
        assert_eq!(key.platform, "ios");
    }

    #[test]
    fn keys_fail_closed() {
        let list = json!({"keys": [
            with("no-usable", |e| { e.remove("usable_from"); }),
            with("bool-usable", |e| { e.insert("usable_from".into(), json!(true)); }),
            with("short-x", |e| { e.insert("jwk".into(), json!({"x": b64u(&[1; 31]), "y": b64u(&[2; 32])})); }),
            with("bad-y", |e| { e.insert("jwk".into(), json!({"x": b64u(&[1; 32]), "y": "*"})); }),
            with("no-jwk", |e| { e.remove("jwk"); }),
            with("", |e| { e.remove("install"); }),
            with("missing-revoked", |e| { e.remove("revoked_at"); }),
            with("revoked", |e| { e.insert("revoked_at".into(), json!(5)); }),
            with("string-flags", |e| { e.insert("attested".into(), json!("true")); e.insert("install_active".into(), json!(1)); }),
            with("no-platform", |e| { e.remove("platform"); }),
        ]});
        let got = keys(&list);
        let mut names: Vec<&str> = got.keys().map(String::as_str).collect();
        names.sort_unstable();
        assert_eq!(names, ["missing-revoked", "no-platform", "revoked", "string-flags"]);
        assert!(got["missing-revoked"].revoked);
        assert!(got["revoked"].revoked);
        assert!(!got["string-flags"].attested && !got["string-flags"].install_active);
        assert_eq!(got["no-platform"].platform, "");
    }

    #[test]
    fn keys_need_a_list_of_objects() {
        assert!(keys(&json!({})).is_empty());
        assert!(keys(&json!({"keys": [entry("p1"), 3]})).is_empty());
    }

    #[test]
    fn base64_url_maps_and_pads() {
        assert_eq!(base64_url("-_8"), Some(vec![0xfb, 0xff]));
        assert_eq!(base64_url("AQ"), Some(vec![1]));
        assert_eq!(base64_url("A"), None);
        assert_eq!(base64_url("A*=="), None);
    }

    fn token(claims: Value) -> String {
        format!("h.{}.s", b64u(claims.to_string().as_bytes()))
    }

    #[test]
    fn context_reads_the_token_claims() {
        assert_eq!(
            context(&token(json!({"iss": "https://cmux-api/prod", "sub": "u1", "inst": "mac1"}))),
            Some(Context {
                environment: "prod".into(),
                user: "u1".into(),
                mac_install: "mac1".into()
            })
        );
        // Empty pieces do not count, like Swift's split.
        assert!(
            context(&format!(
                "h..{}.s",
                b64u(br#"{"iss":"https://cmux-api/e","sub":"u","inst":"i"}"#)
            ))
            .is_some()
        );
        for bad in [
            json!({"iss": "https://other/prod", "sub": "u1", "inst": "mac1"}),
            json!({"iss": "https://cmux-api/", "sub": "u1", "inst": "mac1"}),
            json!({"iss": "https://cmux-api/p", "sub": "", "inst": "mac1"}),
            json!({"iss": "https://cmux-api/p", "sub": "u1"}),
            json!({"iss": "https://cmux-api/p", "sub": "u1", "inst": 3}),
        ] {
            assert_eq!(context(&token(bad)), None);
        }
        assert_eq!(context("a.b"), None);
        assert_eq!(context("a.!!.c"), None);
        assert_eq!(context(&format!("a.{}.c", b64u(b"[1]"))), None);
    }

    fn proof(install: &str, at: i64) -> Proof {
        Proof { install: install.into(), timestamp_ms: at }
    }

    #[test]
    fn precheck_order() {
        let now = 1_000_000.0;
        let list = keys(&json!({"keys": [
            entry("good"),
            with("mac", |e| { e.insert("platform".into(), json!("macos")); }),
            with("unattested", |e| { e.insert("attested".into(), json!(false)); }),
            with("revoked", |e| { e.insert("revoked_at".into(), json!(1)); }),
            with("inactive", |e| { e.insert("install_active".into(), json!(false)); }),
            with("cooling", |e| { e.insert("usable_from".into(), json!(2_000_000)); }),
        ]}));
        let at = 1_000_000;
        assert_eq!(precheck(None, "good", &list, now), Err(Failure::NoProof));
        assert_eq!(
            precheck(Some(&proof("good", at)), "other", &list, now),
            Err(Failure::OtherInstall)
        );
        assert_eq!(
            precheck(Some(&proof("good", at + 60_001)), "good", &list, now),
            Err(Failure::Stale)
        );
        assert_eq!(
            precheck(Some(&proof("good", at - 300_001)), "good", &list, now),
            Err(Failure::Stale)
        );
        // Stale is named before a missing key.
        assert_eq!(
            precheck(Some(&proof("none", at - 300_001)), "none", &list, now),
            Err(Failure::Stale)
        );
        assert_eq!(precheck(Some(&proof("none", at)), "none", &list, now), Err(Failure::NoKey));
        assert_eq!(precheck(Some(&proof("mac", at)), "mac", &list, now), Err(Failure::NotPhone));
        assert_eq!(
            precheck(Some(&proof("unattested", at)), "unattested", &list, now),
            Err(Failure::NotAttested)
        );
        assert_eq!(
            precheck(Some(&proof("revoked", at)), "revoked", &list, now),
            Err(Failure::Revoked)
        );
        assert_eq!(
            precheck(Some(&proof("inactive", at)), "inactive", &list, now),
            Err(Failure::Revoked)
        );
        assert_eq!(
            precheck(Some(&proof("cooling", at)), "cooling", &list, now),
            Err(Failure::CoolingDown)
        );
        assert!(precheck(Some(&proof("good", at + 60_000)), "good", &list, now).is_ok());
        assert!(precheck(Some(&proof("good", at - 300_000)), "good", &list, now).is_ok());
    }
}
