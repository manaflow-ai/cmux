//! Explicit paired-server inspection: a fresh proof and only the original API.
use std::path::Path;
use std::time::Instant;

use cmux_cloud_wire::ReadResponse;
use cmux_server_core::install_key::SystemRandom;
use cmux_server_core::network_policy::{Expected, HostNetworkPolicy};
use serde_json::{Value, json};

use super::{Transport, confirmation, identity};
use crate::error::{Error, Result};

fn invalid() -> Error {
    Error::verification("server.pair.invalid_network_policy")
}

pub fn network_policy(path: &Path, transport: &dyn Transport) -> Result<Value> {
    let record =
        identity::read(path)?.ok_or_else(|| Error::rejected("server.pair.network_unconfirmed"))?;
    let paired =
        record.paired.as_ref().ok_or_else(|| Error::rejected("server.pair.network_unconfirmed"))?;
    let Some(identity::NativeState::Registered { registration, confirmed_at: Some(_) }) =
        record.native.as_ref()
    else {
        return Err(Error::rejected("server.pair.network_unconfirmed"));
    };
    if !registration.matches_keys(&record.public_jwk, &record.wg_public()?) {
        return Err(invalid());
    }
    let bearer = confirmation::token(&record, transport)?;
    let signer = record.signing_key()?;
    let proof = registration
        .policy_proof(transport.now_ms(), crate::host::random::<16>()?, |message| {
            signer.sign(message, &SystemRandom::new())
        })
        .map_err(|_| invalid())?;
    let started = Instant::now();
    let answer = transport.backend_post(
        &record.api,
        "/v1/read",
        &json!({
            "op":"host.network.policy", "params":{"host":paired.host,"proof":proof}
        }),
        Some(bearer.as_str()),
    )?;
    let answer: ReadResponse<Value> = serde_json::from_value(answer).map_err(|_| invalid())?;
    if answer.op != "host.network.policy"
        || answer.stream != format!("team:{}", paired.team)
        || answer.revision.parse::<u64>().is_err()
    {
        return Err(invalid());
    }
    let parsed = HostNetworkPolicy::parse(
        &answer.value,
        &Expected {
            host: &paired.host,
            user: &paired.user,
            install: &paired.install,
            team: &paired.team,
        },
    )
    .map_err(|_| invalid())?;
    let value = serde_json::to_value(&parsed).map_err(|_| invalid())?;
    if started.elapsed().as_millis() >= u128::from(parsed.lifetime_ms())
        || !registration.matches_policy_identity(&value)
    {
        return Err(invalid());
    }
    // A replacement while HTTP was in flight must not publish the old identity.
    let current = identity::read(path)?.ok_or_else(invalid)?;
    let same = current.api == record.api
        && current.public_jwk == record.public_jwk
        && serde_json::to_value(&current.paired).map_err(|_| invalid())?
            == serde_json::to_value(&record.paired).map_err(|_| invalid())?
        && matches!(current.native.as_ref(), Some(identity::NativeState::Registered { registration: fresh, confirmed_at: Some(_) }) if fresh == registration);
    if !same {
        return Err(invalid());
    }
    Ok(value)
}
