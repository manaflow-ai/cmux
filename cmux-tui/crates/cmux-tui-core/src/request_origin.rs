//! Who a `cmux.protocol/2` request comes from (plans/cmux-next/
//! request-origin.md).
//!
//! The daemon derives one origin per request from its connection:
//! - `page` on every request of a connection whose `client-hello` role is
//!   `page_relay` (a page's JS reaches the daemon only through one);
//! - `user` only on a `verified_app` connection (role `main` and a proof;
//!   P8 sets the proof, so no connection is verified before P8);
//! - `app` on the in-process app supervisor router (`apps::routing`);
//! - `agent` otherwise, including every connection without a hello.
//!
//! A request's `origin` claim may only narrow that origin. On a page relay
//! the only claims are `{claim: "page"}` and `{claim: "user", confirmation}`,
//! where the confirmation is a single-use token the verified app minted for
//! exactly this operation, these params and this relay connection
//! (`origin.confirmation.issue`). Gate A2: `apps.install`, `apps.uninstall`
//! and `apps.enable` need origin `user`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::resource::ResourceError;

/// Advertised by `identify` once client-hello step 1, the envelope `origin`
/// field and `origin.confirmation.issue` exist.
pub(crate) const ORIGIN_CLAIM_CAPABILITY: &str = "origin-claim-v1";
/// The operation that mints a confirmation token.
pub(crate) const ISSUE_OPERATION: &str = "origin.confirmation.issue";
/// How long an issued confirmation token is valid.
pub(crate) const CONFIRMATION_TTL_MS: u64 = 60_000;
/// Gate A2: operations that need origin `user`.
pub(crate) const USER_ONLY_OPERATIONS: [&str; 3] =
    ["apps.install", "apps.uninstall", "apps.enable"];
/// Unconsumed tokens one relay connection may hold; the oldest goes first.
const MAX_CONFIRMATIONS_PER_RELAY: usize = 16;
const ORIGIN_FORBIDDEN: &str = "origin.forbidden";
pub(crate) const NEEDS_VERIFIED_APP: &str = "needs a verified cmux app connection";

/// The origin of one request, least to most trusted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestOrigin {
    Page,
    Agent,
    App,
    User,
}

impl RequestOrigin {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::Agent => "agent",
            Self::App => "app",
            Self::User => "user",
        }
    }
}

/// The role a connection fixes with `client-hello`; `Legacy` without one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum HelloRole {
    #[default]
    Legacy,
    Main,
    PageRelay,
}

impl HelloRole {
    /// A role a client may declare (`main` or `page_relay`).
    pub(crate) fn declared(value: &str) -> Option<Self> {
        match value {
            "main" => Some(Self::Main),
            "page_relay" => Some(Self::PageRelay),
            _ => None,
        }
    }
}

/// `install_id`: 1 to 128 characters of `[A-Za-z0-9_-]`.
pub(crate) fn valid_install_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// The envelope's optional `origin` member.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OriginClaim {
    pub claim: RequestOrigin,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confirmation: Option<String>,
}

/// What the daemon knows about one connection's origin. Lives in the
/// connection's registry record, so it ends with the connection.
#[derive(Default)]
pub(crate) struct ConnectionOrigin {
    pub(crate) role: HelloRole,
    /// `token:<pid>.<pidversion>` of the socket peer, read at the hello;
    /// P8 adds `install:<id>` once the install key is proven.
    pub(crate) peer_key: Option<String>,
    /// Role main plus a proof. Always false before P8.
    pub(crate) verified_app: bool,
    /// Tokens issued for this connection as a relay (page relays only).
    confirmations: Vec<Confirmation>,
}

struct Confirmation {
    token: String,
    operation: String,
    params_sha256: String,
    expires_at_ms: u64,
}

impl ConnectionOrigin {
    pub(crate) fn derive(&self) -> RequestOrigin {
        match self.role {
            HelloRole::PageRelay => RequestOrigin::Page,
            HelloRole::Main if self.verified_app => RequestOrigin::User,
            HelloRole::Main | HelloRole::Legacy => RequestOrigin::Agent,
        }
    }

    /// Stores a token minted for this relay connection.
    pub(crate) fn store_confirmation(
        &mut self,
        token: String,
        operation: String,
        params_sha256: String,
        expires_at_ms: u64,
        now_ms: u64,
    ) {
        self.confirmations.retain(|confirmation| confirmation.expires_at_ms > now_ms);
        if self.confirmations.len() >= MAX_CONFIRMATIONS_PER_RELAY {
            self.confirmations.remove(0);
        }
        self.confirmations.push(Confirmation { token, operation, params_sha256, expires_at_ms });
    }

    /// Consumes `token` whatever the outcome (single use), and says whether
    /// it was issued for exactly this operation and params and is live.
    fn consume_confirmation(
        &mut self,
        token: &str,
        operation: &str,
        params: &Value,
        now_ms: u64,
    ) -> bool {
        let Some(index) = self
            .confirmations
            .iter()
            .position(|confirmation| cmux_local_auth::tokens_match(token, &confirmation.token))
        else {
            return false;
        };
        let confirmation = self.confirmations.remove(index);
        confirmation.expires_at_ms > now_ms
            && confirmation.operation == operation
            && cmux_local_auth::tokens_match(&params_sha256(params), &confirmation.params_sha256)
    }

    /// The origin of one request on this connection: the derived origin,
    /// narrowed by `claim`, then checked against the operation's needs.
    pub(crate) fn request_origin(
        &mut self,
        operation: &str,
        params: &Value,
        claim: Option<&OriginClaim>,
        now_ms: u64,
    ) -> Result<RequestOrigin, ResourceError> {
        let derived = self.derive();
        let origin = match (self.role, claim) {
            (_, None) => derived,
            (
                HelloRole::PageRelay,
                Some(OriginClaim { claim: RequestOrigin::Page, confirmation: None }),
            ) => RequestOrigin::Page,
            (
                HelloRole::PageRelay,
                Some(OriginClaim { claim: RequestOrigin::User, confirmation: Some(token) }),
            ) => {
                if !self.consume_confirmation(token, operation, params, now_ms) {
                    return Err(forbidden(
                        "the confirmation is not valid for this request",
                        json!({"derived": derived.wire_name(), "claim": "user", "reason": "confirmation_invalid"}),
                    ));
                }
                RequestOrigin::User
            }
            (
                HelloRole::Main | HelloRole::Legacy,
                Some(OriginClaim { claim, confirmation: None }),
            ) if *claim <= derived => *claim,
            (_, Some(claim)) => {
                return Err(forbidden(
                    "the origin claim may only narrow the connection's origin",
                    json!({"derived": derived.wire_name(), "claim": claim.claim.wire_name()}),
                ));
            }
        };
        if self.role == HelloRole::PageRelay && operation == ISSUE_OPERATION {
            return Err(forbidden(
                "a page relay connection cannot issue confirmations",
                json!({"derived": RequestOrigin::Page.wire_name()}),
            ));
        }
        require_origin(operation, origin)?;
        Ok(origin)
    }
}

/// Gate A2 for one operation and origin.
pub(crate) fn require_origin(operation: &str, origin: RequestOrigin) -> Result<(), ResourceError> {
    if USER_ONLY_OPERATIONS.contains(&operation) && origin != RequestOrigin::User {
        return Err(needs_user(origin));
    }
    Ok(())
}

/// The A2 refusal: `{required: "user", derived}`.
pub(crate) fn needs_user(derived: RequestOrigin) -> ResourceError {
    forbidden(NEEDS_VERIFIED_APP, json!({"required": "user", "derived": derived.wire_name()}))
}

pub(crate) fn forbidden(message: &str, details: Value) -> ResourceError {
    ResourceError::new(ORIGIN_FORBIDDEN, message, details, false)
}

/// A fresh confirmation token: 32 random bytes, base64url without padding.
pub(crate) fn mint_token() -> Result<String, ResourceError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| {
        ResourceError::operation_failed(
            ISSUE_OPERATION,
            "could not mint a confirmation token",
            json!({"error": error.to_string()}),
        )
    })?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

/// 64 lowercase hex digits.
pub(crate) fn valid_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// SHA-256 (lowercase hex) of `params` in canonical JSON.
pub(crate) fn params_sha256(params: &Value) -> String {
    let mut canonical = String::new();
    write_canonical_json(params, &mut canonical);
    Sha256::digest(canonical.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Canonical JSON: object keys sorted by code point, no whitespace, strings
/// and numbers as serde_json writes them (no `/` escape, UTF-8 kept).
pub(crate) fn write_canonical_json(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut keys = map.keys().collect::<Vec<_>>();
            keys.sort();
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                if let Some(member) = map.get(key) {
                    write_canonical_json(member, out);
                }
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical_json(item, out);
            }
            out.push(']');
        }
        scalar => out.push_str(&scalar.to_string()),
    }
}

/// Wall-clock milliseconds for token expiry. Tests move it forward instead
/// of waiting.
#[derive(Default)]
pub(crate) struct OriginClock {
    offset_ms: AtomicU64,
}

impl OriginClock {
    pub(crate) fn now_ms(&self) -> u64 {
        let wall = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX));
        wall.saturating_add(self.offset_ms.load(Ordering::Relaxed))
    }

    #[cfg(test)]
    pub(crate) fn advance(&self, ms: u64) {
        self.offset_ms.fetch_add(ms, Ordering::Relaxed);
    }
}

#[cfg(test)]
#[path = "request_origin_tests.rs"]
mod tests;
