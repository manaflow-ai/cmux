//! Open tokens for app servers (Cloud C10).
//!
//! Open tokens: the op line of a user run (origin user, admitted by the A2
//! gate) of an op in the app's `openOps` (options of its terminal backend
//! and connector implementations) carries a top-level `"open_token"`, a
//! fresh 128-bit hex token, single use, bound to {app, op,
//! idempotency_key} and valid for 60 s. No other op and no
//! other origin gets one, and a client's `open_token` (top level of the
//! request or of `args`) never reaches the server. The host side of a
//! connect checks a token the server passes on with
//! [`Supervisor::consume_open_token`].

use std::time::{Duration, Instant};

use super::supervisor::{Inner, Supervisor};

/// How long a stamped open token stays valid.
const OPEN_TOKEN_TTL: Duration = Duration::from_secs(60);
/// Open tokens kept at once; past it the one closest to expiry goes.
const MAX_OPEN_TOKENS: usize = 1024;

/// A minted open token: single use, for one app, op and idempotency key.
pub(super) struct OpenToken {
    app: String,
    op: String,
    idempotency_key: Option<String>,
    expires: Instant,
}

/// What a consumed open token was minted for, so the caller can check the op.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct OpenTokenUse {
    pub op: String,
    pub idempotency_key: Option<String>,
}

/// Mints a fresh 128-bit open token for one user run of `op`.
pub(super) fn mint_open_token(
    inner: &mut Inner,
    app: &str,
    op: &str,
    idempotency_key: Option<String>,
    now: Instant,
) -> String {
    inner.open_tokens.retain(|_, t| t.expires > now);
    if inner.open_tokens.len() >= MAX_OPEN_TOKENS
        && let Some(oldest) =
            inner.open_tokens.iter().min_by_key(|(_, t)| t.expires).map(|(k, _)| k.clone())
    {
        inner.open_tokens.remove(&oldest);
    }
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("the OS random source");
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    inner.open_tokens.insert(
        token.clone(),
        OpenToken {
            app: app.to_string(),
            op: op.to_string(),
            idempotency_key,
            expires: now + OPEN_TOKEN_TTL,
        },
    );
    token
}

impl Supervisor {
    /// Verifies an open token a server passed on (the host side of the
    /// terminal connector and backend calls this in its connect path). A
    /// token works once, for the app it was minted for, within 60 s of its
    /// run; any lookup consumes it, so a wrong app's attempt burns it too.
    /// Answers what the token was minted for, so the caller can check the op.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn consume_open_token(&self, token: &str, app: &str) -> Option<OpenTokenUse> {
        self.consume_open_token_at(token, app, Instant::now())
    }

    /// [`Self::consume_open_token`] at `now` (tests of callers inject the clock).
    pub(crate) fn consume_open_token_at(
        &self,
        token: &str,
        app: &str,
        now: Instant,
    ) -> Option<OpenTokenUse> {
        let mut inner = self.inner.lock().unwrap();
        let minted = inner.open_tokens.remove(token)?;
        inner.open_tokens.retain(|_, t| t.expires > now);
        // The op must still be one of the app's openOps (the manifest may have
        // changed since the token was minted).
        let open_op =
            inner.catalog.packages.get(app).is_some_and(|p| p.open_ops().contains(&minted.op));
        (minted.app == app && minted.expires > now && open_op)
            .then_some(OpenTokenUse { op: minted.op, idempotency_key: minted.idempotency_key })
    }
}
