//! The deadline of the app's calls into its own Keychain items, and what a call that misses it answers.
//!
//! A Keychain that is locked, asking for its password, or stuck held the app's machine list for good: the relay's
//! install-token mint waited in the Security read and add of the install key with no deadline, the
//! daemon's apps relay gave up after 30 s, and the card read "Something went wrong. Try again." (a CI Mac whose
//! keychain was a per-job file keychain, 2026-11-14). The app still makes the Security call; the app FFI's gate
//! (`cmux-layout-reducer-ffi` `keychain`) runs it on its own thread and answers [`refusal`] once [`DEADLINE`] passes,
//! naming the item, so the person knows which item to unlock or allow.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// How long one call may wait in the Keychain. Under the daemon apps relay's 30 s provider deadline
/// (cmux-tui-core `apps/relay.rs`), with room for a relay call's second mint (a 401) and the API round trip, so
/// the card names the item rather than "the cmux app did not answer in time".
pub const DEADLINE: Duration = Duration::from_secs(10);

/// The code of a [`refusal`]: one every relayed `cloud.*` read and op declares (the Cloud app server's
/// `ops/declared.rs`), so the server passes its message and details through rather than calling it a protocol break.
pub const REFUSAL_CODE: &str = "owner.unreachable";

/// One Keychain item of the app's own: a generic password's service and account (the install key's are
/// `<bundle id>.install-key[.<namespace>].<API host>` and [`crate::identity::install_key_account`]).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Item {
    pub service: String,
    pub account: String,
}

impl Item {
    /// The item as Keychain Access lists it: its name (the service) and its account.
    pub fn name(&self) -> String {
        format!("\"{}\" (account {})", self.service, self.account)
    }
}

/// Whole seconds of `deadline`, rounded up and at least 1, as a person reads it.
pub fn seconds(deadline: Duration) -> u64 {
    let whole = deadline.as_secs() + u64::from(deadline.subsec_nanos() > 0);
    whole.max(1)
}

/// The answer of a call on `item` that did not end within `deadline`, in the credential relay's refusal shape
/// `{code, message, retryable, details}`: the message names the item and the next step; `details.keychain`
/// carries the item and the deadline, so the app writes the person's sentence in their language.
pub fn refusal(item: &Item, deadline: Duration) -> Value {
    let seconds = seconds(deadline);
    json!({
        "code": REFUSAL_CODE,
        "message": format!(
            "the Keychain did not answer for {} within {seconds} s: unlock it or allow cmux access",
            item.name()
        ),
        "retryable": true,
        "details": { "keychain": { "service": item.service, "account": item.account, "deadline_seconds": seconds } },
    })
}

#[cfg(test)]
#[path = "keychain_tests.rs"]
mod tests;
