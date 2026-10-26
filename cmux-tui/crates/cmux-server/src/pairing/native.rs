//! Finish Native registration using this record's own signer. Backend
//! confirmation precedes link export; current policy and serving roles stay separate.
use super::{Transport, identity};
use crate::error::{Error, Result};
use cmux_server_core::install_key::SystemRandom;
use cmux_server_core::pairing::native::{Grant, Registration};
use serde_json::{Value, json};

pub(super) fn status(record: &identity::Identity) -> Result<Option<Value>> {
    match &record.native {
        Some(identity::NativeState::Pending { .. }) => {
            Ok(Some(record.native_grant()?.ok_or_else(invalid)?.public_pending()))
        }
        Some(identity::NativeState::Registered { registration, confirmed_at }) => {
            let mut status = registration.public_status();
            if let Some(at) = confirmed_at {
                status["state"] = json!("confirmed");
                status["confirmed_at"] = json!(at);
            } else {
                status["state"] = json!("confirmation_pending");
            }
            Ok(Some(status))
        }
        None => Ok(None),
    }
}
pub(super) fn validate(record: &identity::Identity) -> Result<()> {
    match &record.native {
        None => Ok(()),
        Some(identity::NativeState::Registered { registration, confirmed_at }) => {
            if super::api_origin(&registration.origin)? != registration.origin
                || !registration.matches_keys(&record.public_jwk, &record.wg_public()?)
                || confirmed_at.is_some_and(|at| at == 0 || at > 9_007_199_254_740_991)
            {
                return Err(invalid());
            }
            Ok(())
        }
        Some(identity::NativeState::Pending { received_at, .. }) => {
            let grant = record.native_grant()?.ok_or_else(invalid)?;
            if *received_at == 0
                || grant.expires_ms() > received_at.saturating_add(720_000)
                || super::api_origin(grant.origin())? != grant.origin()
                || !grant.matches_keys(&record.public_jwk, &record.wg_public()?)
            {
                return Err(invalid());
            }
            Ok(())
        }
    }
}
fn invalid() -> Error {
    Error::verification("server.pair.invalid_network_identity")
}

fn request(
    record: &identity::Identity,
    grant: &Grant,
    enroll: bool,
    transport: &dyn Transport,
) -> Result<Value> {
    let key = record.signing_key()?;
    grant
        .request(enroll, transport.now_ms(), crate::host::random::<16>()?, |message| {
            key.sign(message, &SystemRandom::new())
        })
        .map_err(|_| invalid())
}
fn policy(
    record: &identity::Identity,
    grant: &Grant,
    transport: &dyn Transport,
) -> Result<Option<Registration>> {
    let response = transport.native_post(
        grant.origin(),
        &grant.policy_path(),
        &request(record, grant, false, transport)?,
    )?;
    response.map(|value| grant.registration(&value).map_err(|_| invalid())).transpose()
}

pub(super) fn finish(
    record: &mut identity::Identity,
    store: &identity::Store,
    transport: &dyn Transport,
) -> Result<Value> {
    validate(record)?;
    let Some(grant) = record.native_grant()? else {
        return super::confirmation::finish(record, store, transport);
    };
    // A reserved locator survives both lost HTTP responses and expired codes.
    // The signed policy read proves the tenant and both key pins independently.
    let registered = match policy(record, &grant, transport)? {
        Some(registration) => registration,
        None => {
            if grant.expires_ms() <= transport.now_ms() {
                return Err(Error::rejected("server.pair.network_code_expired"));
            }
            let body = request(record, &grant, true, transport)?;
            let response = transport
                .native_post(grant.origin(), &grant.enrollment_path(), &body)?
                .ok_or_else(|| Error::rejected("server.pair.network_refused"))?;
            if !grant.accepts_enrollment(&response) {
                return Err(invalid());
            }
            policy(record, &grant, transport)?.ok_or_else(invalid)?
        }
    };
    record.schema = 3;
    record.native =
        Some(identity::NativeState::Registered { registration: registered, confirmed_at: None });
    store.save(record)?; // Drop the spent invitation before backend I/O.
    super::confirmation::finish(record, store, transport)
}

pub(super) fn public_result(record: &identity::Identity) -> Result<Value> {
    let paired = record.paired.as_ref().ok_or_else(invalid)?;
    let mut value = serde_json::to_value(
        cmux_server_core::pairing::enrollment::EnrollmentStatus::Paired(paired.clone()),
    )
    .map_err(|_| invalid())?;
    if let Some(network) = status(record)? {
        if network["state"] == "pending" || network["state"] == "confirmation_pending" {
            value["state"] = json!("network_pending");
        }
        value["network"] = network;
    }
    Ok(value)
}

/// Used by transport consumers: a requested network enrollment must finish
/// before this identity can be exported to a link. Basic legacy pairing works.
pub(super) fn registration_for_link(record: &identity::Identity) -> Result<Option<Registration>> {
    match &record.native {
        Some(
            identity::NativeState::Pending { .. }
            | identity::NativeState::Registered { confirmed_at: None, .. },
        ) => Err(Error::rejected("server.pair.network_pending")),
        Some(identity::NativeState::Registered { registration, confirmed_at: Some(_) }) => {
            Ok(Some(registration.clone()))
        }
        None => Ok(None),
    }
}
