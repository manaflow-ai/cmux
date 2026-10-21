//! General server enrollment through the existing human-approved Cloud flow.
//! This records identity; it never installs, starts roles or grants execution.

mod confirmation;
mod credentials;
mod identity;
pub(crate) mod info;
pub(crate) mod messages;
mod native;
mod network;
mod protect;

use std::path::Path;

use cmux_server_core::install_key::SystemRandom;
use cmux_server_core::pairing::enrollment::{self, Begun, EnrollmentStatus, Paired, Waited};
use serde_json::{Value, json};

use crate::error::{Error, Result};

pub use credentials::EnrolledIdentity;
pub use network::Network;

pub const DEFAULT_API: &str = "https://cloud-api.cmux.dev";
// A lost begin reply may have made a code. It expires within ten minutes,
// plus the backend's five-minute clock-skew window and request deadline.
const UNKNOWN_BEGIN_MS: u64 = enrollment::MAX_WAIT_MS + 5 * 60 * 1000 + 20_000;

/// Transport adapters preserve the same signed request and pushed result.
pub trait Transport {
    fn health(&self, api: &str) -> Result<Value>;
    fn begin(&self, api: &str, body: &Value) -> Result<Value>;
    fn wait(&self, api: &str, begun: &Begun) -> Result<Waited>;
    fn now_ms(&self) -> u64 {
        crate::host::now_ms()
    }
    /// None means HTTP 404 only. Other refusals and operational failures stay distinct.
    fn native_post(&self, _origin: &str, _path: &str, _body: &Value) -> Result<Option<Value>> {
        Err(Error::unreachable("server.pair.network_unavailable"))
    }
    /// The selected backend only; bearer credentials never reach Native.
    fn backend_post(
        &self,
        _api: &str,
        _path: &str,
        _body: &Value,
        _bearer: Option<&str>,
    ) -> Result<Value> {
        Err(Error::unreachable("server.pair.backend_unavailable"))
    }
}

/// Canonical HTTPS origin only: no path, userinfo, query or fragment.
pub fn api_origin(input: &str) -> Result<String> {
    let url = url::Url::parse(input).map_err(|_| Error::rejected("server.pair.invalid_api"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(Error::rejected("server.pair.invalid_api"));
    }
    Ok(url.as_str().trim_end_matches('/').into())
}

/// Read-only, including when there is no server install or identity file.
pub fn status(path: &Path) -> Result<Value> {
    let record = identity::read(path)?;
    if let Some(record) = &record
        && record.paired.is_some()
        && record.native.is_some()
    {
        return native::public_result(record);
    }
    let state = match record {
        Some(record) => match (record.paired, record.attempt) {
            (Some(paired), _) => EnrollmentStatus::Paired(paired),
            (_, Some(attempt)) if attempt.response.is_some() => EnrollmentStatus::Pending {
                expires_at: attempt
                    .expires_at
                    .ok_or_else(|| Error::verification("server.pair.invalid_identity"))?,
            },
            (_, Some(attempt)) => EnrollmentStatus::Indeterminate {
                retry_not_before: attempt.started_at.saturating_add(UNKNOWN_BEGIN_MS),
            },
            _ => EnrollmentStatus::Unpaired,
        },
        None => EnrollmentStatus::Unpaired,
    };
    serde_json::to_value(state).map_err(|_| Error::internal("server.pair.invalid_status"))
}

/// Whether the backend may still accept a code expiring at `expires_at` (its clock): it allows
/// five minutes of skew, so a code past expiry here is resumed, never replaced, until then.
fn code_live(expires_at: u64, now_ms: u64) -> bool {
    expires_at.saturating_add(enrollment::MAX_CLOCK_SKEW_MS) > now_ms
}

fn public_result(paired: &Paired) -> Result<Value> {
    serde_json::to_value(EnrollmentStatus::Paired(paired.clone()))
        .map_err(|_| Error::internal("server.pair.invalid_status"))
}

/// One identity and pending attempt, serialized across callers and restarts.
/// `progress` receives public code/check words only; its error stops the wait.
pub fn enroll(
    path: &Path,
    api: &str,
    info: Value,
    intent: Option<&str>,
    transport: &dyn Transport,
    now_ms: u64,
    mut progress: impl FnMut(&Value) -> Result<()>,
) -> Result<Value> {
    let api = api_origin(api)?;
    if intent.is_some_and(|s| s.is_empty() || s.encode_utf16().count() > 128 || s.contains('\0')) {
        return Err(Error::usage("server.pair.invalid_intent"));
    }
    let store = identity::Store::acquire(path)?;
    let mut identity = store.read()?.map_or_else(|| identity::Identity::new(&api), Ok)?;
    if identity.api != api {
        return Err(Error::rejected("server.pair.api_mismatch"));
    }
    let key = identity.signing_key()?;
    let thumbprint = enrollment::jwk_thumbprint(&identity.public_jwk)
        .map_err(|_| Error::verification("server.pair.invalid_identity"))?;
    if identity.paired.is_some() {
        return native::finish(&mut identity, &store, transport);
    }
    if let Some(attempt) = &identity.attempt {
        let active = if attempt.response.is_some() {
            attempt.expires_at.is_some_and(|at| code_live(at, now_ms))
        } else {
            now_ms < attempt.started_at.saturating_add(UNKNOWN_BEGIN_MS)
        };
        if active && attempt.intent.as_deref() != intent {
            return Err(Error::new(crate::ExitKind::Conflict, "server.pair.intent_conflict"));
        }
        if attempt.response.is_none()
            && now_ms < attempt.started_at.saturating_add(UNKNOWN_BEGIN_MS)
        {
            return Err(Error::unreachable("server.pair.begin_indeterminate"));
        }
    }
    let response = identity.begin_response()?;
    let begun = response
        .as_ref()
        .filter(|v| v["expires_at"].as_u64().is_some_and(|at| code_live(at, now_ms)))
        .map(|v| Begun::parse(v, &thumbprint, now_ms))
        .transpose()
        .map_err(|_| Error::verification("server.pair.invalid_begin"))?;
    let begun = match begun {
        Some(begun) => begun,
        None => {
            let health = transport.health(&api)?;
            let env = health["environment"]
                .as_str()
                .filter(|s| {
                    !s.is_empty()
                        && s.len() <= 32
                        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
                })
                .ok_or_else(|| Error::verification("server.pair.invalid_environment"))?;
            let wg = identity.wg_public()?;
            let body =
                enrollment::begin_request(&identity.public_jwk, &wg, info, env, now_ms, |proof| {
                    key.sign(proof, &SystemRandom::new())
                })
                .map_err(|_| Error::verification("server.pair.invalid_begin_request"))?;
            identity.attempt = Some(identity::Attempt {
                started_at: now_ms,
                intent: intent.map(str::to_owned),
                response: None,
                expires_at: None,
            });
            store.save(&identity)?;
            let response = match transport.begin(&api, &body) {
                Ok(response) => response,
                Err(error)
                    if error.kind == crate::ExitKind::Rejected
                        || error.message == network::UNSENT =>
                {
                    // The begin route's 4xx replies acknowledge that no code
                    // was issued, and an unsent begin made none. Keep the key
                    // and allow a corrected or repeated attempt.
                    identity.attempt = None;
                    store.save(&identity)?;
                    return Err(error);
                }
                Err(error) => return Err(error),
            };
            let begun = Begun::parse(&response, &thumbprint, now_ms)
                .map_err(|_| Error::verification("server.pair.invalid_begin"))?;
            // Store only the bounded, validated fields needed for same-code recovery.
            let mut saved = json!({"code":begun.code.as_str(),"expires_at":begun.expires_at,
                "thumbprint":begun.thumbprint,"collect_secret":begun.collect_secret()});
            if let Some(uri) = verification_uri(&response, &begun) {
                saved["verification_uri"] = uri.into();
            }
            identity.save_response(&saved)?;
            store.save(&identity)?;
            begun
        }
    };
    let mut public_progress = begun.public_progress();
    if let Some(response) = identity.begin_response()?
        && let Some(uri) = verification_uri(&response, &begun)
    {
        public_progress["verification_uri"] = uri.into();
    }
    progress(&public_progress)?;
    match transport.wait(&api, &begun)? {
        Waited::NetworkPaired { paired, grant } => {
            paired.validate().map_err(|_| Error::verification("server.pair.invalid_result"))?;
            if api_origin(grant.origin())? != grant.origin()
                || !grant.matches_keys(&identity.public_jwk, &identity.wg_public()?)
            {
                return Err(Error::verification("server.pair.invalid_network_identity"));
            }
            identity.paired = Some(paired);
            identity.attempt = None;
            identity.save_native(&grant, transport.now_ms())?;
            native::validate(&identity)?;
            store.save(&identity)?;
            native::finish(&mut identity, &store, transport)
        }
        Waited::Paired(paired) => {
            paired.validate().map_err(|_| Error::verification("server.pair.invalid_result"))?;
            identity.paired = Some(paired.clone());
            identity.attempt = None;
            store.save(&identity)?;
            public_result(&paired)
        }
        Waited::Refused => {
            identity.attempt = None;
            store.save(&identity)?;
            Err(Error::rejected("server.pair.refused"))
        }
        Waited::Expired => {
            identity.attempt = None;
            store.save(&identity)?;
            Err(Error::unreachable("server.pair.expired"))
        }
    }
}

fn verification_uri(response: &Value, begun: &Begun) -> Option<String> {
    let text = response.get("verification_uri")?.as_str()?;
    if text.len() > 2048
        || text.to_ascii_lowercase().contains(&begun.collect_secret().to_ascii_lowercase())
    {
        return None;
    }
    let uri = url::Url::parse(text).ok()?;
    let query = uri.query_pairs().collect::<Vec<_>>();
    (uri.scheme()=="https" && uri.host_str().is_some() && uri.username().is_empty()
        && uri.password().is_none() && uri.path()=="/pair" && uri.fragment().is_none()
        && matches!(query.as_slice(),[(key,value)] if key.as_ref()=="c" && value.as_ref()==begun.code.as_str()))
        .then(|| uri.to_string())
}
