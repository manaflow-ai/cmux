//! Gesture tokens (decisions 29, 29a-29c): proof that a user really acted.
//!
//! The router mints one with its token key (typ `cmux-gesture+jwt`) when
//! the host asks through `cmux.router.gesture.mint` while it handles a real
//! user event. The page carries it in the call envelope's `gesture` field.
//! A provider accepts it for an op with `gesture: true` only when it is
//! bound to that op (or `*view` for an op with `view_state: true`), to the
//! provider (`aud`) and to the calling page instance (`sub`, `app`), has not
//! expired, and its `jti` was not spent. The jti is spent only when the call
//! passed every other check and reaches the handler.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::{self, ErrorBody};
use crate::token::{Claims, SigningKey, TokenError, verify_jws};

/// The JWS `typ` of a gesture token.
pub const GESTURE_TYPE: &str = "cmux-gesture+jwt";
/// A gesture token's lifetime.
pub const GESTURE_TTL_SECS: u64 = 10;
/// The op claim that covers any view-state op.
pub const ANY_VIEW: &str = "*view";
/// Spent jtis kept per provider (each lives at most 10 s).
pub const MAX_SPENT: usize = 65_536;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GestureClaims {
    /// The page instance.
    pub sub: String,
    pub app: String,
    /// The provider the gesture may be spent at.
    pub aud: String,
    /// The op it may be spent on, or `*view`.
    pub op: String,
    pub exp: u64,
    pub jti: String,
}

/// Sign a gesture token.
pub fn sign(key: &SigningKey, claims: &GestureClaims) -> String {
    key.sign_jws(GESTURE_TYPE, claims)
}

/// A fresh random jti.
pub fn new_jti() -> String {
    let mut bytes = [0u8; 16];
    let _ = getrandom::fill(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn required(message: impl Into<String>) -> ErrorBody {
    ErrorBody::new(error::FORBIDDEN, message).with_details(json!({ "reason": "gesture_required" }))
}

/// The spent jtis of one provider.
#[derive(Debug, Clone, Default)]
pub struct SpentJtis {
    inner: Arc<Mutex<HashMap<String, u64>>>,
}

impl SpentJtis {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, u64>> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn is_spent(&self, jti: &str) -> bool {
        self.lock().contains_key(jti)
    }

    /// Spend `jti` (valid until `exp`); an error when it was already spent.
    pub fn spend(&self, jti: &str, exp: u64, now: u64) -> Result<(), ErrorBody> {
        let mut spent = self.lock();
        spent.retain(|_, until| *until > now);
        if spent.len() >= MAX_SPENT {
            return Err(ErrorBody::new(error::BUSY, "too many gestures in flight").retryable());
        }
        if spent.insert(jti.to_owned(), exp).is_some() {
            return Err(required("the gesture was already used"));
        }
        Ok(())
    }
}

/// A checked gesture whose jti is spent only when the call reaches its handler.
#[derive(Debug, Clone)]
pub struct PendingGesture {
    claims: GestureClaims,
    spent: SpentJtis,
}

impl PendingGesture {
    pub fn spend(&self) -> Result<(), ErrorBody> {
        self.spent.spend(&self.claims.jti, self.claims.exp, crate::token::now())
    }
}

/// What a provider needs to check a gesture for one call.
pub struct GestureCheck<'a> {
    pub router_key: &'a [u8; 32],
    pub audience: &'a str,
    pub caller: &'a Claims,
    pub op: &'a str,
    pub view_state: bool,
    pub now: u64,
}

impl GestureCheck<'_> {
    /// Check `token` for this call without spending it.
    pub fn check(
        &self,
        token: Option<&str>,
        spent: &SpentJtis,
    ) -> Result<PendingGesture, ErrorBody> {
        let token = token.ok_or_else(|| required(format!("{} needs a user gesture", self.op)))?;
        let claims: GestureClaims = verify_jws(self.router_key, token, GESTURE_TYPE)
            .map_err(|problem: TokenError| required(format!("bad gesture token: {problem}")))?;
        if claims.exp <= self.now {
            return Err(required("the gesture expired"));
        }
        if claims.aud != self.audience {
            return Err(required("the gesture is for another provider"));
        }
        if claims.sub != self.caller.sub || claims.app != self.caller.app {
            return Err(required("the gesture is for another page"));
        }
        let covers = claims.op == self.op || (claims.op == ANY_VIEW && self.view_state);
        if !covers {
            return Err(required(format!("the gesture is for {}, not {}", claims.op, self.op)));
        }
        if spent.is_spent(&claims.jti) {
            return Err(required("the gesture was already used"));
        }
        Ok(PendingGesture { claims, spent: spent.clone() })
    }
}
