//! The sign-in owner's rules for the Mac's install token (remote-cloud-durability F13, sections 4.2 and 4.5):
//! when a held token is used, when it is renewed, how long a caller waits on a mint, and what state the
//! person reads while it runs. Pure: the app holds the token and runs the mint, sends the facts (its clock,
//! the held token's life, the mint in flight) and acts on the answer.
//!
//! - Make-before-break: a token is renewed at 2/3 of its life while the held one keeps answering, so a
//!   stalled renewal never stalls a Cloud call that still has a valid token.
//! - Every wait bounded: a caller with no usable token waits at most [`MINT_BOUND`] on one mint, then reads
//!   `mint_stalled` naming the step, never "the cmux API did not answer". The stalled mint is replaced, so
//!   the next caller is not stuck behind it (H15).

use std::time::Duration;

use serde::{Deserialize, Serialize};

/// The longest a caller waits on one install-token mint. Longer than one bounded Keychain call
/// ([`crate::keychain::DEADLINE`]: the mint signs with the install key), so a stuck Keychain answers with its
/// own refusal first; shorter than the credential relay's 25 s, so the relay hears this state, not its own
/// timeout.
pub const MINT_BOUND: Duration = Duration::from_secs(15);

/// A held token closer than this to its expiry is not handed out (clock skew, the request's own time).
pub const EXPIRY_MARGIN: Duration = Duration::from_secs(5);

/// The refusal code of a caller that waited [`MINT_BOUND`] on a mint.
pub const STALLED_CODE: &str = "credential.minting";

/// What the app knows when a caller asks for a token. Times are the app's wall clock, in ms since the epoch.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseFacts {
    pub now_ms: u64,
    /// The token the app holds, if any.
    pub held: Option<Held>,
    /// The mint in flight, if any.
    pub mint: Option<Mint>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Held {
    /// When this app received the token.
    pub minted_ms: u64,
    /// When the owner says it expires (already capped by the app).
    pub expires_ms: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mint {
    pub started_ms: u64,
    /// The step the mint is in, in words ("signing the challenge").
    pub step: String,
}

/// What the app does now. At most one of `use_held`, `wait_until_ms` and `refusal` is set; none set never
/// happens.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    /// Answer with the held token.
    pub use_held: bool,
    /// Start a mint (a renewal when `use_held`). Never set while a mint that is within its bound runs.
    pub start_mint: bool,
    /// Cancel the mint in flight first: it ran past its bound.
    pub cancel_mint: bool,
    /// Wait on the mint until it answers or this time, then ask again.
    pub wait_until_ms: Option<u64>,
    /// Fail the call with this answer (`{code, message, retryable, details}`).
    pub refusal: Option<serde_json::Value>,
    /// What the person reads about sign-in.
    pub state: State,
}

/// The install token's state, for the Cloud log and the person.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum State {
    /// A token is held and is not due for renewal.
    Ready { expires_in_ms: u64 },
    /// A token is held and a renewal runs (or is starting) beside it.
    Renewing { expires_in_ms: u64, step: String },
    /// No usable token; a mint runs within its bound.
    Minting { since_ms: u64, bound_ms: u64, step: String },
    /// No usable token; the mint ran past its bound.
    MintStalled { since_ms: u64, bound_ms: u64, step: String },
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// The step a mint starts in.
pub const FIRST_STEP: &str = "starting the mint";

/// When a token minted at `minted_ms` that expires at `expires_ms` is renewed: at 2/3 of its life.
pub fn renew_at_ms(minted_ms: u64, expires_ms: u64) -> u64 {
    minted_ms.saturating_add(expires_ms.saturating_sub(minted_ms) / 3 * 2)
}

/// The decision for one caller.
pub fn lease(facts: &LeaseFacts) -> Decision {
    let now = facts.now_ms;
    let bound = millis(MINT_BOUND);
    let stalled = facts.mint.as_ref().is_some_and(|m| now.saturating_sub(m.started_ms) >= bound);
    let usable =
        facts.held.as_ref().filter(|h| now.saturating_add(millis(EXPIRY_MARGIN)) < h.expires_ms);
    if let Some(held) = usable {
        let expires_in_ms = held.expires_ms - now;
        // A clock that went back before the mint can't place the token in its life: renew.
        let due = now >= renew_at_ms(held.minted_ms, held.expires_ms) || now < held.minted_ms;
        if !due && facts.mint.is_none() {
            return Decision { use_held: true, ..decision(State::Ready { expires_in_ms }) };
        }
        let step = match &facts.mint {
            Some(m) if !stalled => m.step.clone(),
            _ => FIRST_STEP.into(),
        };
        return Decision {
            use_held: true,
            start_mint: due && (facts.mint.is_none() || stalled),
            cancel_mint: stalled,
            ..decision(State::Renewing { expires_in_ms, step })
        };
    }
    match &facts.mint {
        None => Decision {
            start_mint: true,
            wait_until_ms: Some(now.saturating_add(bound)),
            ..decision(State::Minting { since_ms: now, bound_ms: bound, step: FIRST_STEP.into() })
        },
        Some(m) if !stalled => Decision {
            wait_until_ms: Some(m.started_ms.saturating_add(bound)),
            ..decision(State::Minting {
                since_ms: m.started_ms,
                bound_ms: bound,
                step: m.step.clone(),
            })
        },
        Some(m) => {
            let state = State::MintStalled {
                since_ms: m.started_ms,
                bound_ms: bound,
                step: m.step.clone(),
            };
            Decision {
                // The stalled mint goes; the next caller starts a fresh one instead of waiting behind it.
                cancel_mint: true,
                refusal: Some(stalled_refusal(m, now)),
                ..decision(state)
            }
        }
    }
}

fn decision(state: State) -> Decision {
    Decision {
        use_held: false,
        start_mint: false,
        cancel_mint: false,
        wait_until_ms: None,
        refusal: None,
        state,
    }
}

fn stalled_refusal(mint: &Mint, now: u64) -> serde_json::Value {
    let waited = now.saturating_sub(mint.started_ms).div_ceil(1000);
    let bound = MINT_BOUND.as_secs();
    serde_json::json!({
        "code": STALLED_CODE,
        "message": format!(
            "this Mac is still minting its cmux install token ({}, {waited} s, past its {bound} s bound); \
             cmux starts a fresh mint on the next try",
            mint.step
        ),
        "retryable": true,
        "details": { "mint": { "step": mint.step, "waited_seconds": waited, "bound_seconds": bound } },
    })
}

#[cfg(test)]
#[path = "signin_tests.rs"]
mod tests;
