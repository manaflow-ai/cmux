//! Device request signatures.
//!
//! Every device call to the coordinator is signed by the device's machine
//! key over `weft-v1`, the method, the path with query, the timestamp, a
//! random nonce and the SHA-256 of the body. TLS gives confidentiality; the
//! signature binds the request to the device so a captured request cannot be
//! replayed (nonce cache), delayed (60 s window) or altered.

use std::collections::{HashMap, VecDeque};

use sha2::{Digest, Sha256};

use crate::keys::{SigningKey, verify};

/// Allowed clock difference between device and coordinator.
pub const MAX_SKEW_MS: u64 = 60_000;
/// How long a nonce is remembered; longer than the whole accepted window.
const NONCE_TTL_MS: u64 = 2 * MAX_SKEW_MS + 1_000;
/// Remembered nonces at most; beyond this the oldest are forgotten early,
/// which can only refuse more, never accept a replay inside the window,
/// because a request older than the window fails the clock check.
const MAX_NONCES: usize = 200_000;

pub const HEADER_NODE: &str = "weft-node";
pub const HEADER_TS: &str = "weft-ts";
pub const HEADER_NONCE: &str = "weft-nonce";
pub const HEADER_SIG: &str = "weft-sig";

/// The four signature headers of one request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignedHeaders {
    pub node: String,
    pub ts: String,
    pub nonce: String,
    pub sig: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignError {
    Malformed,
    Clock,
    BadSignature,
    Replay,
}

impl std::fmt::Display for SignError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Malformed => "malformed signature headers",
            Self::Clock => "request time outside the accepted window",
            Self::BadSignature => "bad signature",
            Self::Replay => "replayed request",
        })
    }
}

fn message(node: &str, method: &str, path: &str, ts: &str, nonce: &str, body: &[u8]) -> Vec<u8> {
    let body_hash = hex::encode(Sha256::digest(body));
    format!("weft-v1\n{node}\n{method}\n{path}\n{ts}\n{nonce}\n{body_hash}").into_bytes()
}

/// Sign one request as `node`.
pub fn sign_request(
    key: &SigningKey,
    node: &str,
    method: &str,
    path: &str,
    body: &[u8],
    now_ms: u64,
) -> SignedHeaders {
    let ts = now_ms.to_string();
    let nonce = crate::random_hex(16);
    let signature = key.sign(&message(node, method, path, &ts, &nonce, body));
    SignedHeaders { node: node.to_owned(), ts, nonce, sig: crate::b64::encode_url(&signature) }
}

/// Checks signatures and remembers nonces.
#[derive(Default)]
pub struct Verifier {
    seen: HashMap<String, u64>,
    order: VecDeque<(u64, String)>,
}

impl Verifier {
    pub fn new() -> Self {
        Self::default()
    }

    /// Verify `headers` against `public` for this request. A request that
    /// fails any check leaves no trace, so it cannot burn a genuine nonce.
    pub fn verify(
        &mut self,
        public: &[u8; 32],
        headers: &SignedHeaders,
        method: &str,
        path: &str,
        body: &[u8],
        now_ms: u64,
    ) -> Result<(), SignError> {
        if headers.nonce.len() != 32 || !headers.nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(SignError::Malformed);
        }
        if headers.node.is_empty() || headers.node.len() > 64 {
            return Err(SignError::Malformed);
        }
        let ts: u64 = headers.ts.parse().map_err(|_| SignError::Malformed)?;
        if ts.abs_diff(now_ms) > MAX_SKEW_MS {
            return Err(SignError::Clock);
        }
        let signature = crate::b64::decode_url(&headers.sig).ok_or(SignError::Malformed)?;
        if signature.len() != 64 {
            return Err(SignError::Malformed);
        }
        let signed = message(&headers.node, method, path, &headers.ts, &headers.nonce, body);
        if !verify(public, &signed, &signature) {
            return Err(SignError::BadSignature);
        }
        self.prune(now_ms);
        let key = format!("{}/{}", headers.node, headers.nonce);
        if self.seen.contains_key(&key) {
            return Err(SignError::Replay);
        }
        self.seen.insert(key.clone(), now_ms);
        self.order.push_back((now_ms, key));
        Ok(())
    }

    fn prune(&mut self, now_ms: u64) {
        while let Some((at, key)) = self.order.front() {
            if now_ms.saturating_sub(*at) > NONCE_TTL_MS || self.order.len() > MAX_NONCES {
                self.seen.remove(key);
                self.order.pop_front();
            } else {
                break;
            }
        }
    }
}
