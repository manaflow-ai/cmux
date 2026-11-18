//! The compact JWS checks shared by every token the Cloud keyset signs (the
//! Native link token and the carrier grant): the three-part shape, canonical
//! base64url, the `{alg, kid, typ}` header with `alg: EdDSA` and the expected
//! `typ`, a known kid, and the Ed25519 signature. Each refusal names its check
//! with the same reasons the link token always used.

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::signature;
use serde::Deserialize;

use crate::keyset::Keyset;
use crate::token::{TokenRefusal, TokenRefused};

/// A token whose header and signature passed: its decoded claims bytes (not
/// yet parsed or checked).
pub(crate) struct SignedToken {
    pub claims: Vec<u8>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    alg: String,
    kid: String,
    typ: String,
}

/// Check `token`'s shape, header (`typ` must equal `typ`) and signature
/// against `keys`. An unknown kid is [`TokenRefused::UnknownKey`], so the
/// keyset owner may make its bounded unknown-kid fetch.
pub(crate) fn verify_signed(
    token: &str,
    typ: &str,
    keys: &Keyset,
) -> Result<SignedToken, TokenRefusal> {
    use TokenRefused::Invalid;
    let no = TokenRefusal::new;
    let mut parts = token.split('.');
    let shape = || no(Invalid, "token_shape");
    let h = parts.next().ok_or_else(shape)?;
    let p = parts.next().ok_or_else(shape)?;
    let s = parts.next().ok_or_else(shape)?;
    if parts.next().is_some() {
        return Err(shape());
    }
    let header: Header = serde_json::from_slice(&decode(h).map_err(|k| no(k, "header_encoding"))?)
        .map_err(|_| no(Invalid, "header_malformed"))?;
    if header.alg != "EdDSA" {
        return Err(no(Invalid, "header_alg"));
    }
    if header.typ != typ {
        return Err(no(Invalid, "header_typ"));
    }
    if !kid(&header.kid) {
        return Err(no(Invalid, "kid"));
    }
    let key = *keys.keys.get(&header.kid).ok_or(no(TokenRefused::UnknownKey, "unknown_kid"))?;
    let sig = decode(s).map_err(|k| no(k, "signature"))?;
    if sig.len() != 64 {
        return Err(no(Invalid, "signature"));
    }
    let signed = token.get(..h.len() + 1 + p.len()).ok_or_else(shape)?;
    signature::UnparsedPublicKey::new(&signature::ED25519, key)
        .verify(signed.as_bytes(), &sig)
        .map_err(|_| no(Invalid, "signature"))?;
    let claims = decode(p).map_err(|k| no(k, "claims_encoding"))?;
    Ok(SignedToken { claims })
}

/// Canonical, non-empty base64url without padding.
pub(crate) fn decode(value: &str) -> Result<Vec<u8>, TokenRefused> {
    let bytes = URL_SAFE_NO_PAD.decode(value).map_err(|_| TokenRefused::Invalid)?;
    if value.is_empty() || URL_SAFE_NO_PAD.encode(&bytes) != value {
        return Err(TokenRefused::Invalid);
    }
    Ok(bytes)
}

/// A kid of 1 to 64 characters from `A-Z a-z 0-9 . _ -`.
pub(crate) fn kid(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// A keyset a verifier may hold: 1 or 2 valid kids and a 16-hex version.
pub(crate) fn valid_keys(keys: &Keyset) -> bool {
    (1..=2).contains(&keys.keys.len())
        && keys.keys.keys().all(|s| kid(s))
        && keys.version.len() == 16
        && keys.version.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A `jti`: 16 random bytes in canonical base64url.
pub(crate) fn valid_jti(jti: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(jti)
        .ok()
        .is_some_and(|b| b.len() == 16 && URL_SAFE_NO_PAD.encode(b) == jti)
}
