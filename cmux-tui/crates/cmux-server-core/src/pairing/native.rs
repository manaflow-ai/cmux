//! The private invitation delivered by backend pairing. These public bindings
//! describe a reservation; neither the code nor a registration activates a role.
use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use cmux_json::JsonSet as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct WireGrant {
    origin: String,
    code: String,
    tenant_id: String,
    mesh_id: String,
    device_id: String,
    expires_at: String,
    binding: Binding,
}
#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Binding {
    name: String,
    wg_public_key: String,
    install_public_key: String,
}

/// No Serialize or secret-bearing Debug implementation. Persist only through
/// `private_record`, inside the OS-protected enrollment record.
#[derive(Clone, PartialEq, Eq)]
pub struct Grant {
    wire: WireGrant,
    expires_ms: u64,
}
impl std::fmt::Debug for Grant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NativeGrant").field("device", &self.wire.device_id).finish_non_exhaustive()
    }
}
const INVALID: &str = "pairing.invalid_network_enrollment";
fn opaque(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).is_some_and(|tail| {
        tail.len() == 26 && tail.bytes().all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(&b))
    })
}
fn origin(value: &str) -> bool {
    // Coarse wire shape; the I/O adapter additionally requires URL-parser canonicalization.
    let Some(authority) = value.strip_prefix("https://") else { return false };
    !authority.is_empty()
        && !authority
            .bytes()
            .any(|b| b.is_ascii_whitespace() || b < 0x20 || b == 0x7f || b"/@?#\\".contains(&b))
}
fn tenant(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
fn public_point(jwk: &Value) -> Option<String> {
    if jwk["kty"] != "EC" || jwk["crv"] != "P-256" {
        return None;
    }
    let x = URL_SAFE_NO_PAD.decode(jwk["x"].as_str()?).ok()?;
    let y = URL_SAFE_NO_PAD.decode(jwk["y"].as_str()?).ok()?;
    if x.len() != 32 || y.len() != 32 {
        return None;
    }
    let mut point = vec![4];
    point.extend(x);
    point.extend(y);
    Some(STANDARD.encode(point))
}
impl Grant {
    pub fn parse(value: &Value) -> Result<Self, String> {
        let wire: WireGrant = serde_json::from_value(value.clone()).map_err(|_| INVALID)?;
        let expiry = OffsetDateTime::parse(&wire.expires_at, &Rfc3339)
            .map_err(|_| INVALID)?
            .unix_timestamp_nanos()
            / 1_000_000;
        let expires_ms = u64::try_from(expiry).map_err(|_| INVALID)?;
        let name = &wire.binding.name;
        let canonical_key = |text: &str, size: usize| {
            STANDARD
                .decode(text)
                .is_ok_and(|bytes| bytes.len() == size && STANDARD.encode(bytes) == text)
        };
        if !origin(&wire.origin)
            || !opaque(&wire.code, "msc_")
            || !opaque(&wire.mesh_id, "mesh_")
            || !opaque(&wire.device_id, "dev_")
            || !tenant(&wire.tenant_id)
            || name.is_empty()
            || name.len() > 63
            || !name.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
            || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._ -".contains(&b))
            || !canonical_key(&wire.binding.wg_public_key, 32)
            || !canonical_key(&wire.binding.install_public_key, 65)
            || !STANDARD
                .decode(&wire.binding.install_public_key)
                .is_ok_and(|p| p.first() == Some(&4))
            || expires_ms == 0
        {
            return Err(INVALID.into());
        }
        Ok(Self { wire, expires_ms })
    }
    pub fn private_record(&self) -> Result<Value, String> {
        serde_json::to_value(&self.wire).map_err(|_| INVALID.into())
    }
    pub fn matches_reservation(&self, value: &Value) -> bool {
        value["state"] == "reserved"
            && value["tenant"] == self.wire.tenant_id
            && value["mesh"] == self.wire.mesh_id
            && value["device"] == self.wire.device_id
    }
    pub fn matches_keys(&self, jwk: &Value, wg: &str) -> bool {
        public_point(jwk).as_deref() == Some(self.wire.binding.install_public_key.as_str())
            && wg == self.wire.binding.wg_public_key
    }
    pub fn expires_ms(&self) -> u64 {
        self.expires_ms
    }
    pub fn origin(&self) -> &str {
        &self.wire.origin
    }
    pub fn enrollment_path(&self) -> String {
        format!("/v1/meshes/{}/overlay-server-enrollments", self.wire.mesh_id)
    }
    pub fn policy_path(&self) -> String {
        format!("/v1/overlay-servers/{}/signed/policy", self.wire.device_id)
    }
    pub fn public_pending(&self) -> Value {
        json!({"state":"pending","tenant":self.wire.tenant_id,"mesh":self.wire.mesh_id,"device":self.wire.device_id})
    }

    /// Native's eight-line signature, with a fresh caller-supplied nonce/time.
    /// The install signer returns base64url r||s; Native uses standard base64.
    pub fn request(
        &self,
        enroll: bool,
        at: u64,
        nonce: [u8; 16],
        sign: impl FnOnce(&[u8]) -> Result<String, String>,
    ) -> Result<Value, String> {
        let (purpose, target, wg, name) = if enroll {
            (
                "enroll-overlay-server",
                self.wire.mesh_id.as_str(),
                self.wire.binding.wg_public_key.as_str(),
                format!("{}:{}", self.wire.code, self.wire.binding.name),
            )
        } else {
            ("overlay-server-policy", self.wire.device_id.as_str(), "", String::new())
        };
        let mut body = signed_proof(
            [purpose, target, wg, &self.wire.binding.install_public_key, &name],
            at,
            nonce,
            sign,
        )?;
        if enroll {
            body.set("code", self.wire.code.clone().into());
            body.set("name", self.wire.binding.name.clone().into());
            body.set("wgPublicKey", self.wire.binding.wg_public_key.clone().into());
            body.set("installPublicKey", self.wire.binding.install_public_key.clone().into());
        }
        Ok(body)
    }
    pub fn accepts_enrollment(&self, value: &Value) -> bool {
        value["id"] == self.wire.device_id
            && value["meshId"] == self.wire.mesh_id
            && value["name"] == self.wire.binding.name
            && value["wgPublicKey"] == self.wire.binding.wg_public_key
            && value["installPublicKey"] == self.wire.binding.install_public_key
            && value["kind"] == "server"
            && value["transport"] == "overlay"
    }
    pub fn registration(&self, policy: &Value) -> Result<Registration, String> {
        if policy["tenantId"] != self.wire.tenant_id
            || policy["meshId"] != self.wire.mesh_id
            || policy["deviceId"] != self.wire.device_id
            || policy["wgPublicKey"] != self.wire.binding.wg_public_key
            || policy["installPublicKey"] != self.wire.binding.install_public_key
        {
            return Err(INVALID.into());
        }
        Ok(Registration {
            origin: self.wire.origin.clone(),
            tenant: self.wire.tenant_id.clone(),
            mesh: self.wire.mesh_id.clone(),
            device: self.wire.device_id.clone(),
            wg_public_key: self.wire.binding.wg_public_key.clone(),
            install_public_key: self.wire.binding.install_public_key.clone(),
        })
    }
}

/// Public identity metadata only. This does not attest current policy freshness,
/// peer enforcement, relay admission, role activation or execution authority.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub origin: String,
    pub tenant: String,
    pub mesh: String,
    pub device: String,
    wg_public_key: String,
    install_public_key: String,
}
impl Registration {
    /// A fresh policy proof for this saved identity. The consumer forwards it
    /// once to Native, directly or through the authenticated backend.
    pub fn policy_proof(
        &self,
        at: u64,
        nonce: [u8; 16],
        sign: impl FnOnce(&[u8]) -> Result<String, String>,
    ) -> Result<Value, String> {
        if !opaque(&self.device, "dev_")
            || !STANDARD.decode(&self.install_public_key).is_ok_and(|p| {
                p.len() == 65
                    && p.first() == Some(&4)
                    && STANDARD.encode(p) == self.install_public_key
            })
        {
            return Err(INVALID.into());
        }
        signed_proof(
            ["overlay-server-policy", &self.device, "", &self.install_public_key, ""],
            at,
            nonce,
            sign,
        )
    }
    pub fn matches_keys(&self, jwk: &Value, wg: &str) -> bool {
        origin(&self.origin)
            && opaque(&self.mesh, "mesh_")
            && opaque(&self.device, "dev_")
            && tenant(&self.tenant)
            && self.wg_public_key == wg
            && public_point(jwk).as_deref() == Some(self.install_public_key.as_str())
    }
    pub fn public_status(&self) -> Value {
        json!({"state":"registered","tenant":self.tenant,"mesh":self.mesh,"device":self.device})
    }
}

fn signed_proof(
    lines: [&str; 5],
    at: u64,
    nonce: [u8; 16],
    sign: impl FnOnce(&[u8]) -> Result<String, String>,
) -> Result<Value, String> {
    if at == 0 || at > 9_007_199_254_740_991 {
        return Err(INVALID.into());
    }
    let nonce = URL_SAFE_NO_PAD.encode(nonce);
    let message = format!("cmux-mesh-v1\n{}\n{at}\n{nonce}", lines.join("\n"));
    let signature = URL_SAFE_NO_PAD.decode(sign(message.as_bytes())?).map_err(|_| INVALID)?;
    if signature.len() != 64 {
        return Err(INVALID.into());
    }
    Ok(json!({"signedAt":at,"nonce":nonce,"signature":STANDARD.encode(signature)}))
}
