//! Shared server/Chief enrollment wire contract. No transport or filesystem.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::PairingCode;
use cmux_json::JsonSet as _;

pub const MAX_WAIT_MS: u64 = 10 * 60 * 1000;
pub const MAX_CLOCK_SKEW_MS: u64 = 5 * 60 * 1000;
pub const MAX_FRAME_BYTES: usize = 16 * 1024;

/// RFC 7638: only these four public members, in lexical order.
pub fn jwk_thumbprint(jwk: &Value) -> Result<String, String> {
    let coordinate = |key: &str| {
        let text = jwk[key].as_str().ok_or("pairing.invalid_public_key")?;
        let bytes = B64.decode(text).map_err(|_| "pairing.invalid_public_key")?;
        if bytes.len() != 32 || B64.encode(bytes) != text {
            return Err("pairing.invalid_public_key");
        }
        Ok(text)
    };
    if jwk["kty"] != "EC" || jwk["crv"] != "P-256" {
        return Err("pairing.invalid_public_key".into());
    }
    let (x, y) = (coordinate("x")?, coordinate("y")?);
    let canonical = format!(r#"{{"crv":"P-256","kty":"EC","x":"{x}","y":"{y}"}}"#);
    Ok(B64.encode(Sha256::digest(canonical.as_bytes())))
}

pub fn begin_proof(environment: &str, thumbprint: &str, wg_public: &str, issued_at: u64) -> String {
    format!("cmux-pair-begin\n{environment}\n{thumbprint}\n{wg_public}\n{issued_at}")
}

/// The request used by general servers and Chief hosts. Only the signer sees
/// the private key; it receives the same environment-bound proof as the API.
pub fn begin_request(
    public_jwk: &Value,
    wg_public: &str,
    info: Value,
    environment: &str,
    issued_at: u64,
    sign: impl FnOnce(&[u8]) -> Result<String, String>,
) -> Result<Value, String> {
    use base64::engine::general_purpose::STANDARD;
    let thumbprint = jwk_thumbprint(public_jwk)?;
    if environment.is_empty()
        || environment.len() > 32
        || !environment.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        || !STANDARD
            .decode(wg_public)
            .is_ok_and(|key| key.len() == 32 && STANDARD.encode(key) == wg_public)
        || !valid_info(&info)
    {
        return Err("pairing.invalid_begin_request".into());
    }
    let proof = begin_proof(environment, &thumbprint, wg_public, issued_at);
    let signature = sign(proof.as_bytes())?;
    let mut public_info = json!({"name":info["name"],"platform":info["platform"],
        "os_version":info["os_version"],"arch":info["arch"],"cmux_version":info["cmux_version"]});
    if let Some(capabilities) = info.get("capabilities") {
        public_info.set("capabilities", capabilities.clone());
    }
    Ok(json!({"public_jwk":public_jwk,"wg_public_key":wg_public,"info":public_info,
        "issued_at":issued_at,"signature":signature}))
}

fn valid_info(info: &Value) -> bool {
    let bounded = |key: &str, min: usize, max: usize| {
        info[key].as_str().is_some_and(|s| (min..=max).contains(&s.encode_utf16().count()))
    };
    let capability = |value: &Value| {
        value.as_str().is_some_and(|s| {
            !s.is_empty()
                && s.len() <= 40
                && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && s.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        })
    };
    bounded("name", 1, 80)
        && bounded("os_version", 0, 80)
        && bounded("cmux_version", 0, 40)
        && matches!(info["platform"].as_str(), Some("macos" | "ios" | "linux" | "windows" | "web"))
        && matches!(info["arch"].as_str(), Some("x86_64" | "aarch64"))
        && info
            .get("capabilities")
            .is_none_or(|v| v.as_array().is_some_and(|a| a.len() <= 8 && a.iter().all(capability)))
}

/// Matches the approving app's four-word derivation from the JWK thumbprint.
pub fn fingerprint_words(thumbprint: &str) -> Option<[&'static str; 4]> {
    let bytes = B64.decode(thumbprint).ok()?;
    (bytes.len() == 32).then(|| super::fingerprint_words(&bytes))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Paired {
    pub host: String,
    pub team: String,
    pub user: String,
    pub install: String,
}

impl Paired {
    pub fn validate(&self) -> Result<(), String> {
        // backend/packages/protocol/src/schemas.ts prefixedId contract.
        let valid = |id: &str, prefix: &str| {
            id.strip_prefix(prefix).and_then(|rest| rest.strip_prefix('_')).is_some_and(|tail| {
                tail.len() == 20
                    && tail.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
            })
        };
        if valid(&self.host, "host")
            && valid(&self.team, "team")
            && valid(&self.user, "user")
            && valid(&self.install, "inst")
        {
            Ok(())
        } else {
            Err("pairing.invalid_result".into())
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Waited {
    Paired(Paired),
    NetworkPaired { paired: Paired, grant: Box<super::native::Grant> },
    Refused,
    Expired,
}

/// Read-only local enrollment state. It carries no execution authority or
/// serving/readiness claim, and never contains key or collection material.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum EnrollmentStatus {
    Unpaired,
    Pending { expires_at: u64 },
    Indeterminate { retry_not_before: u64 },
    Paired(Paired),
}

/// The collect secret is deliberately excluded from Debug and public output.
pub struct Begun {
    pub code: PairingCode,
    pub expires_at: u64,
    pub thumbprint: String,
    collect_secret: String,
}

impl std::fmt::Debug for Begun {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Begun")
            .field("code", &self.code)
            .field("expires_at", &self.expires_at)
            .field("thumbprint", &self.thumbprint)
            .finish_non_exhaustive()
    }
}

impl Begun {
    pub fn parse(value: &Value, expected_thumbprint: &str, now_ms: u64) -> Result<Self, String> {
        let text = |key: &str| value[key].as_str().ok_or("pairing.invalid_begin");
        let raw_code = text("code")?;
        let code = PairingCode::normalize(raw_code).map_err(|_| "pairing.invalid_begin")?;
        let thumbprint = text("thumbprint")?;
        let collect_secret = text("collect_secret")?;
        let expires_at = value["expires_at"].as_u64().ok_or("pairing.invalid_begin")?;
        if code.as_str() != raw_code
            || thumbprint != expected_thumbprint
            || fingerprint_words(thumbprint).is_none()
            || !valid_collect_secret(collect_secret)
            || expires_at.saturating_add(MAX_CLOCK_SKEW_MS) <= now_ms
            || expires_at.saturating_sub(now_ms) > MAX_WAIT_MS + MAX_CLOCK_SKEW_MS
        {
            return Err("pairing.invalid_begin".into());
        }
        Ok(Self {
            code,
            expires_at,
            thumbprint: thumbprint.into(),
            collect_secret: collect_secret.into(),
        })
    }

    pub fn collect_secret(&self) -> &str {
        &self.collect_secret
    }

    /// No secret, arbitrary server URL or key material is shown to a person.
    pub fn public_progress(&self) -> Value {
        json!({"state":"pending", "code":self.code.display(), "expires_at":self.expires_at,
            "words":fingerprint_words(&self.thumbprint), "thumbprint":self.thumbprint})
    }
}

/// pair-collect.ts: a 16-byte nonce, dot, 32-byte lowercase hex HMAC.
pub fn valid_collect_secret(secret: &str) -> bool {
    let Some((nonce, mac)) = secret.split_once('.') else { return false };
    nonce.len() == 22
        && nonce.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        && B64.decode(nonce).is_ok_and(|v| v.len() == 16 && B64.encode(v) == nonce)
        && mac.len() == 64
        && mac.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// One pushed message; `None` means pending, never a successful enrollment.
pub fn read_frame(text: &str) -> Result<Option<Waited>, String> {
    if text.len() > MAX_FRAME_BYTES {
        return Err("pairing.invalid_frame".into());
    }
    let frame: Value = serde_json::from_str(text).map_err(|_| "pairing.invalid_frame")?;
    match frame["t"].as_str() {
        Some("paired") => {
            let network = match (frame.get("network"), frame.get("network_enrollment")) {
                (None, None) => None,
                (Some(reservation), Some(value)) => {
                    let grant = super::native::Grant::parse(value)?;
                    if !grant.matches_reservation(reservation) {
                        return Err("pairing.invalid_network_enrollment".into());
                    }
                    Some(grant)
                }
                _ => return Err("pairing.invalid_network_enrollment".into()),
            };
            let paired: Paired =
                serde_json::from_value(frame).map_err(|_| "pairing.invalid_result")?;
            paired.validate()?;
            Ok(Some(match network {
                Some(grant) => Waited::NetworkPaired { paired, grant: Box::new(grant) },
                None => Waited::Paired(paired),
            }))
        }
        Some("refused") => Ok(Some(Waited::Refused)),
        // Pending, or a type a newer backend added: keep waiting, as Chief did.
        Some(_) => Ok(None),
        None => Err("pairing.invalid_frame".into()),
    }
}
