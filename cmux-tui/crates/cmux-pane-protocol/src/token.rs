//! Capability tokens (spec "Security"; wire decision 10).
//!
//! A token is a compact JWS: `<header>.<claims>.<signature>`, each part
//! unpadded base64url. The header is exactly `{"alg":"EdDSA","typ":"cmux-cap+jwt"}`;
//! the signature is Ed25519 over the ASCII bytes `<header>.<claims>`. The
//! router mints; a provider verifies offline with the router's public key.
//!
//! One claims type covers both kinds of token: a page token
//! (`page` set, `aud` = [`ROUTER_AUDIENCE`]) that a page presents to the
//! router, and a data-plane token (`aud` = a provider) from
//! `cmux.router.resolve`.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::signature::{ED25519, Ed25519KeyPair, KeyPair, UnparsedPublicKey};
use serde::{Deserialize, Serialize};

/// The JWS `typ` of a capability token.
pub const TOKEN_TYPE: &str = "cmux-cap+jwt";
/// The JWS `alg`.
pub const TOKEN_ALG: &str = "EdDSA";
/// The audience of a page token: the page presents it to the router.
pub const ROUTER_AUDIENCE: &str = "router";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    alg: String,
    typ: String,
}

/// The claims of one capability token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Claims {
    /// The surface (page instance) the token was minted for.
    pub sub: String,
    /// The page id, on page tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page: Option<String>,
    /// The app id of that surface.
    pub app: String,
    /// Namespaces whose ops the token may call (empty on page tokens).
    #[serde(default)]
    pub ns: Vec<String>,
    /// Scopes granted, such as `git:read`.
    pub scopes: Vec<String>,
    /// Absolute canonical directories (the page's workspace roots). Every
    /// path param must resolve inside one (decision 20); empty allows no
    /// path at all.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roots: Vec<String>,
    /// The browser origin the token is bound to; `None` for a native peer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    /// The provider (app id) that accepts this token, or `router`.
    pub aud: String,
    /// Expiry, unix seconds.
    pub exp: u64,
    /// Issue time, unix seconds.
    pub iat: u64,
}

impl Claims {
    /// Whether these claims allow calling `op` (or subscribing to an event
    /// stream), which requires `scope`.
    pub fn allows(&self, op: &str, scope: &str) -> bool {
        let in_namespace = self.ns.iter().any(|ns| crate::router::within(op, ns) && op != ns);
        in_namespace && self.scopes.iter().any(|granted| granted == scope)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenError {
    Malformed,
    /// A header other than `{"alg":"EdDSA","typ":"cmux-cap+jwt"}`.
    WrongHeader,
    BadSignature,
    Expired,
    WrongAudience,
    WrongOrigin,
}

impl TokenError {
    /// The snake_case name used in conformance vectors and refusal details.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::WrongHeader => "wrong_header",
            Self::BadSignature => "bad_signature",
            Self::Expired => "expired",
            Self::WrongAudience => "wrong_audience",
            Self::WrongOrigin => "wrong_origin",
        }
    }
}

impl std::fmt::Display for TokenError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Malformed => "malformed token",
            Self::WrongHeader => "token header is not EdDSA cmux-cap+jwt",
            Self::BadSignature => "bad token signature",
            Self::Expired => "token expired",
            Self::WrongAudience => "token is for another audience",
            Self::WrongOrigin => "token is for another origin",
        })
    }
}

impl std::error::Error for TokenError {}

/// The router's signing key.
pub struct SigningKey {
    pair: Ed25519KeyPair,
}

impl SigningKey {
    /// A key from a 32-byte Ed25519 seed (tests and vectors use a fixed one).
    /// `ring` rejects only a seed of the wrong length, so this fails only if
    /// `ring` changes that rule.
    pub fn from_seed(seed: &[u8; 32]) -> anyhow::Result<Self> {
        let pair = Ed25519KeyPair::from_seed_unchecked(seed)
            .map_err(|error| anyhow::anyhow!("Ed25519 seed rejected: {error}"))?;
        Ok(Self { pair })
    }

    /// A fresh random key.
    pub fn generate() -> anyhow::Result<Self> {
        let mut seed = [0u8; 32];
        getrandom::fill(&mut seed).map_err(|error| anyhow::anyhow!("getrandom: {error}"))?;
        Self::from_seed(&seed)
    }

    /// The 32-byte public key providers verify with.
    pub fn public_key(&self) -> [u8; 32] {
        let mut key = [0u8; 32];
        key.copy_from_slice(self.pair.public_key().as_ref());
        key
    }

    pub fn sign(&self, claims: &Claims) -> String {
        let header = Header { alg: TOKEN_ALG.into(), typ: TOKEN_TYPE.into() };
        let header = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap_or_default());
        let claims = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap_or_default());
        let signed = format!("{header}.{claims}");
        let signature = self.pair.sign(signed.as_bytes());
        format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }
}

/// Offline verification in a provider (or in the router, for page tokens,
/// with audience [`ROUTER_AUDIENCE`]).
#[derive(Debug, Clone)]
pub struct Verifier {
    public_key: [u8; 32],
    audience: String,
}

impl Verifier {
    pub fn new(public_key: [u8; 32], audience: impl Into<String>) -> Self {
        Self { public_key, audience: audience.into() }
    }

    pub fn audience(&self) -> &str {
        &self.audience
    }

    /// Verify `token` at unix time `now` for a connection whose normalized
    /// `Origin` is `origin`. A connection without an `Origin` header (a
    /// native peer) skips the origin check; a browser connection requires
    /// the token's origin to equal its own.
    pub fn verify(
        &self,
        token: &str,
        now: u64,
        origin: Option<&str>,
    ) -> Result<Claims, TokenError> {
        let claims = verify_signature(&self.public_key, token)?;
        if claims.exp <= now {
            return Err(TokenError::Expired);
        }
        if claims.aud != self.audience {
            return Err(TokenError::WrongAudience);
        }
        if origin.is_some() && claims.origin.as_deref() != origin {
            return Err(TokenError::WrongOrigin);
        }
        Ok(claims)
    }
}

/// Check the header and signature and decode the claims, without the time,
/// audience or origin checks.
pub fn verify_signature(public_key: &[u8; 32], token: &str) -> Result<Claims, TokenError> {
    let mut parts = token.split('.');
    let (Some(header), Some(claims), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(TokenError::Malformed);
    };
    let header_json = URL_SAFE_NO_PAD.decode(header).map_err(|_| TokenError::Malformed)?;
    let parsed: Header = serde_json::from_slice(&header_json).map_err(|_| TokenError::Malformed)?;
    if parsed.alg != TOKEN_ALG || parsed.typ != TOKEN_TYPE {
        return Err(TokenError::WrongHeader);
    }
    let signature = URL_SAFE_NO_PAD.decode(signature).map_err(|_| TokenError::Malformed)?;
    let signed_len = header.len() + 1 + claims.len();
    UnparsedPublicKey::new(&ED25519, public_key)
        .verify(&token.as_bytes()[..signed_len], &signature)
        .map_err(|_| TokenError::BadSignature)?;
    let json = URL_SAFE_NO_PAD.decode(claims).map_err(|_| TokenError::Malformed)?;
    serde_json::from_slice(&json).map_err(|_| TokenError::Malformed)
}

/// Unix seconds now.
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claims() -> Claims {
        Claims {
            sub: "surface-1".into(),
            page: None,
            app: "cmux.agent".into(),
            ns: vec!["cmux".into()],
            scopes: vec!["git:read".into()],
            roots: Vec::new(),
            origin: Some("http://127.0.0.1:4100".into()),
            aud: "cmux.git".into(),
            exp: 2_000,
            iat: 1_000,
        }
    }

    #[test]
    fn mint_and_verify() {
        let key = SigningKey::from_seed(&[7; 32]).unwrap();
        let token = key.sign(&claims());
        let verifier = Verifier::new(key.public_key(), "cmux.git");
        let origin = Some("http://127.0.0.1:4100");
        assert_eq!(verifier.verify(&token, 1_000, origin), Ok(claims()));
        assert_eq!(verifier.verify(&token, 1_000, None), Ok(claims()));
        assert_eq!(verifier.verify(&token, 2_000, origin), Err(TokenError::Expired));
        assert_eq!(
            verifier.verify(&token, 1_000, Some("http://evil.test")),
            Err(TokenError::WrongOrigin)
        );
        let other = Verifier::new(key.public_key(), "com.acme.diff");
        assert_eq!(other.verify(&token, 1_000, origin), Err(TokenError::WrongAudience));
        let stranger =
            Verifier::new(SigningKey::from_seed(&[8; 32]).unwrap().public_key(), "cmux.git");
        assert_eq!(stranger.verify(&token, 1_000, origin), Err(TokenError::BadSignature));
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"none","typ":"cmux-cap+jwt"}"#);
        let forged = format!("{header}.{}", token.split_once('.').unwrap().1);
        assert_eq!(verifier.verify(&forged, 1_000, origin), Err(TokenError::WrongHeader));
    }

    #[test]
    fn allows_checks_namespace_boundary_and_scope() {
        let claims = claims();
        assert!(claims.allows("cmux.git.status", "git:read"));
        assert!(!claims.allows("cmux.git.status", "git:write"));
        assert!(!claims.allows("cmuxevil.git.status", "git:read"));
    }
}
