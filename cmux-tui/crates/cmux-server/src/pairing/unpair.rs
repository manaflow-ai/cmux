//! `cmux server unpair` (and `cmux unpair`): this machine leaves cmux Cloud.
//!
//! A paired machine signs its own install out first (`install.sign_out`, with a
//! short-lived token minted by its install key, as `confirmation.rs` does). The
//! backend then removes its host from the team's servers and spends the
//! pairing code and invite that made it, so that key cannot pair again with
//! them. Only after the backend agreed, or already refused this key, is the
//! local enrollment record (identity, keys and any pending attempt) removed.
//! `--local` skips the backend: the person then removes the server in the app.

use std::path::Path;

use serde_json::{Value, json};

use super::{Transport, confirmation, identity};
use crate::error::{Error, Result};

/// The backend did not answer the sign-out: nothing was removed.
pub const UNREACHABLE: &str = "server.unpair.cloud_unreachable";
/// The backend answered the sign-out with a refusal other than "already revoked".
pub const REFUSED: &str = "server.unpair.cloud_refused";

/// What happened in cmux Cloud.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cloud {
    /// The install signed itself out; its host left the team's servers.
    SignedOut,
    /// The backend refused this install's key already (revoked in the app).
    AlreadyRevoked,
    /// `--local`: not asked.
    Skipped,
    /// No approved pairing: there was no install to sign out.
    None,
}

impl Cloud {
    pub fn as_str(self) -> &'static str {
        match self {
            Cloud::SignedOut => "signed_out",
            Cloud::AlreadyRevoked => "already_revoked",
            Cloud::Skipped => "skipped",
            Cloud::None => "none",
        }
    }
}

fn cloud_error(error: Error) -> Error {
    if error.kind == crate::ExitKind::Unreachable {
        Error::unreachable(UNREACHABLE)
    } else if error.kind == crate::ExitKind::Rejected {
        Error::rejected(REFUSED)
    } else {
        error
    }
}

/// Sign the paired install out with its own key.
fn sign_out(record: &identity::Identity, transport: &dyn Transport) -> Result<Cloud> {
    let paired =
        record.paired.as_ref().ok_or_else(|| Error::internal("server.unpair.not_paired"))?;
    // The challenge refuses only an unknown or revoked install (one answer for both): that alone
    // means "already revoked". A refused token mint (an old client, an SSO or team policy gate)
    // leaves the install active, so it keeps the local record.
    let ids = json!({"user": paired.user, "install": paired.install});
    match transport.backend_post(&record.api, "/v1/auth/challenge", &ids, None) {
        Ok(_) => {}
        Err(error) if error.kind == crate::ExitKind::Rejected => return Ok(Cloud::AlreadyRevoked),
        Err(error) => return Err(cloud_error(error)),
    }
    let bearer = confirmation::token(record, transport).map_err(cloud_error)?;
    let key = format!("server-unpair:{}", paired.install);
    let answer = transport
        .backend_post(
            &record.api,
            "/v1/ops",
            &json!({"op": "install.sign_out", "idempotency_key": key, "origin": "cli", "params": {}}),
            Some(bearer.as_str()),
        )
        .map_err(cloud_error)?;
    if answer["ok"] == true
        && answer["op"] == "install.sign_out"
        && answer["value"]["id"] == paired.install
    {
        return Ok(Cloud::SignedOut);
    }
    Err(if answer["ok"] == false && answer["error"]["retryable"] == true {
        Error::unreachable(UNREACHABLE)
    } else {
        Error::rejected(REFUSED)
    })
}

/// Leave cmux Cloud and forget the local enrollment. `{"state":"unpaired",
/// "cloud": ..., "removed": bool}` plus the `host` and `install` it was.
pub fn unpair(path: &Path, transport: &dyn Transport, local_only: bool) -> Result<Value> {
    // Nothing on disk: say so without creating the pairing directory.
    if identity::read(path)?.is_none() {
        return Ok(json!({"state": "unpaired", "cloud": Cloud::None.as_str(), "removed": false}));
    }
    let store = identity::Store::acquire(path)?;
    let Some(record) = store.read()? else {
        return Ok(json!({"state": "unpaired", "cloud": Cloud::None.as_str(), "removed": false}));
    };
    let cloud = match (&record.paired, local_only) {
        (None, _) => Cloud::None,
        (Some(_), true) => Cloud::Skipped,
        (Some(_), false) => sign_out(&record, transport)?,
    };
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(Error::internal("server.unpair.remove_failed")),
    }
    let mut out = json!({"state": "unpaired", "cloud": cloud.as_str(), "removed": true});
    if let Some(paired) = &record.paired {
        out["host"] = paired.host.clone().into();
        out["install"] = paired.install.clone().into();
    }
    drop(store);
    Ok(out)
}
