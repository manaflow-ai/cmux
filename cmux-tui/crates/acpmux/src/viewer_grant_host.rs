//! The host gate for viewer Touch ID grants (CMUX-572; the rules are
//! [`crate::viewer_grant`]). When this Mac's machine-join consent has not
//! granted screen (or control) to its signed-in machines, the app's Mac Screen
//! gate asks here instead of refusing: `_acpmux/viewer_grant_challenge` for a
//! one-time challenge for the ticket, which the app sends to the viewer over
//! the session's signaling (the hub's authenticated device channel), and
//! `_acpmux/viewer_grant_admit` with the viewer's signed proof, before it
//! serves. A first proof may carry its key's registration; it is kept only
//! when that new key signed the proof, so a grant is never made without the
//! viewer's Touch ID (or login password).
//!
//! Only the person's own app, on the local socket, may call these: it passes
//! the ticket as the hub delivered it (session, hub-authenticated viewer,
//! scope) and this Mac's own hub device id. The book lives in acpmux's home
//! (`machine-consent/viewer-grants.json`, 0600) for the account this machine is
//! joined as ([`crate::machine_record::machine_user_id`], from the join's
//! machine credential); a sign-out or another account's join keeps none.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Value, json};

use crate::viewer_grant::{
    Challenges, GrantBook, Proof, Refused, Registration, Scope, Ticket, register, verify,
};

/// The book's file under acpmux's home.
pub const BOOK_FILE: &str = "machine-consent/viewer-grants.json";

/// This daemon's open challenges (memory only: a restart drops them, and the viewer asks again).
static CHALLENGES: Mutex<Option<Challenges>> = Mutex::new(None);

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default()
}

fn book_path(home: &Path) -> PathBuf {
    home.join(BOOK_FILE)
}

/// The book as it holds for `account` (none for a signed-out machine or another account).
pub fn load(home: &Path, account: Option<&str>) -> GrantBook {
    let stored = crate::home_fs::private_state_file(book_path(home))
        .ok()
        .and_then(|file| serde_json::from_reader::<_, GrantBook>(file).ok())
        .unwrap_or_default();
    stored.for_account(account.unwrap_or_default())
}

fn save(home: &Path, book: &GrantBook) -> Result<(), Refused> {
    let bytes = serde_json::to_vec_pretty(book).map_err(|_| store_failed())?;
    crate::agent_tools::write_private(&book_path(home), &bytes).map_err(|_| store_failed())
}

fn store_failed() -> Refused {
    Refused { code: "grant.store", message: "this Mac could not keep the grant".into() }
}

/// What a person-line call names: the ticket and this Mac's hub id.
struct Call {
    host: String,
    session: String,
    viewer: String,
    scope: Scope,
}

fn text(params: &Value, key: &str) -> Result<String, Refused> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Refused { code: "grant.bad_request", message: format!("{key} is required") })
}

fn call(params: &Value) -> Result<Call, Refused> {
    let scope =
        serde_json::from_value(params.get("scope").cloned().unwrap_or_default()).map_err(|_| {
            Refused { code: "grant.bad_request", message: "scope is view or control".into() }
        })?;
    Ok(Call {
        host: text(params, "host")?,
        session: text(params, "session")?,
        viewer: text(params, "viewer")?,
        scope,
    })
}

/// `_acpmux/viewer_grant_challenge {host, session, viewer, scope}`: a one-time challenge for
/// that ticket, and whether this Mac holds a grant the viewer can answer with.
pub fn challenge(home: &Path, account: Option<&str>, params: &Value) -> Result<Value, Refused> {
    let call = call(params)?;
    let book = load(home, account);
    if book.account.is_empty() {
        return Err(Refused {
            code: "grant.signed_out",
            message: "this Mac is not joined to an account".into(),
        });
    }
    let mut challenges = CHALLENGES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let challenge = challenges
        .get_or_insert_with(Challenges::default)
        .issue(&call.session, &call.viewer, now())
        .ok_or_else(|| Refused {
            code: "grant.random",
            message: "no challenge could be made".into(),
        })?;
    let granted = book.covering(&call.viewer, call.scope).is_some();
    Ok(json!({"challenge": challenge, "host": call.host, "granted": granted}))
}

/// `_acpmux/viewer_grant_admit {host, session, viewer, scope, proof, registration?}`: whether
/// this Mac serves the ticket. A registration is kept only when its own key signed `proof`.
pub fn admit(home: &Path, account: Option<&str>, params: &Value) -> Result<Value, Refused> {
    let call = call(params)?;
    let proof: Proof = serde_json::from_value(params.get("proof").cloned().unwrap_or_default())
        .map_err(|_| Refused { code: "grant.bad_request", message: "proof is required".into() })?;
    let registration = match params.get("registration") {
        None | Some(Value::Null) => None,
        Some(value) => {
            Some(serde_json::from_value::<Registration>(value.clone()).map_err(|_| Refused {
                code: "grant.bad_request",
                message: "registration is not readable".into(),
            })?)
        }
    };
    let ticket = Ticket { session: &call.session, viewer: &call.viewer, scope: call.scope };
    let mut book = load(home, account);
    let mut challenges = CHALLENGES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let challenges = challenges.get_or_insert_with(Challenges::default);
    let registered =
        admit_in(&mut book, challenges, &call.host, &ticket, &proof, registration.as_ref(), now())?;
    if registered {
        save(home, &book)?;
    }
    Ok(json!({"admitted": true, "registered": registered}))
}

/// [`admit`]'s decision on a book: a registration goes into a copy, and the copy is the book only
/// when the proof verifies against it, so a key that did not sign registers nothing.
pub fn admit_in(
    book: &mut GrantBook,
    challenges: &mut Challenges,
    host: &str,
    ticket: &Ticket<'_>,
    proof: &Proof,
    registration: Option<&Registration>,
    now: u64,
) -> Result<bool, Refused> {
    let Some(registration) = registration else {
        verify(book, challenges, host, ticket, proof, now)?;
        return Ok(false);
    };
    if registration.scope != ticket.scope {
        return Err(Refused {
            code: "grant.wrong_scope",
            message: "the registration is for another scope".into(),
        });
    }
    let mut next = book.clone();
    register(&mut next, registration, ticket.viewer, host, now)?;
    verify(&next, challenges, host, ticket, proof, now)?;
    *book = next;
    Ok(true)
}

/// `_acpmux/viewer_grant_revoke {viewer, scope?}`: deletes the viewer's key here.
pub fn revoke(home: &Path, account: Option<&str>, params: &Value) -> Result<Value, Refused> {
    let viewer = text(params, "viewer")?;
    let scope: Option<Scope> = match params.get("scope") {
        None | Some(Value::Null) => None,
        Some(value) => Some(serde_json::from_value(value.clone()).map_err(|_| Refused {
            code: "grant.bad_request",
            message: "scope is view or control".into(),
        })?),
    };
    let mut book = load(home, account);
    let revoked = book.revoke(&viewer, scope);
    if revoked {
        save(home, &book)?;
    }
    Ok(json!({"revoked": revoked}))
}

#[cfg(test)]
#[path = "viewer_grant_host_tests.rs"]
mod tests;
