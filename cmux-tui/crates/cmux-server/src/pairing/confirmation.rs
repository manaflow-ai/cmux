//! Confirm a saved Native identity using only this daemon's install grant.
//! Tokens and proofs are transient; a failed reply leaves the checkpoint pending.

use cmux_server_core::install_key::SystemRandom;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Transport, identity};
use crate::error::{Error, Result};

fn invalid() -> Error {
    Error::verification("server.pair.invalid_backend_confirmation")
}

fn token(record: &identity::Identity, transport: &dyn Transport) -> Result<Zeroizing<String>> {
    let paired = record.paired.as_ref().ok_or_else(invalid)?;
    let health = transport.health(&record.api)?;
    let environment = health["environment"]
        .as_str()
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 32
                && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        })
        .ok_or_else(invalid)?;
    let ids = json!({"user": paired.user, "install": paired.install});
    let challenge = transport.backend_post(&record.api, "/v1/auth/challenge", &ids, None)?;
    let expected = format!("cmux-auth-v1\n{environment}\n{}\n", paired.install);
    let nonce = challenge["nonce"]
        .as_str()
        .filter(|s| {
            s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
        .ok_or_else(invalid)?;
    if challenge["install"] != paired.install
        || challenge["message_prefix"] != expected
        || challenge["expires_at"].as_u64().is_none_or(|at| at <= transport.now_ms())
    {
        return Err(invalid());
    }
    let signature = record
        .signing_key()?
        .sign(format!("{expected}{nonce}").as_bytes(), &SystemRandom::new())
        .map_err(|_| invalid())?;
    let answer = transport.backend_post(
        &record.api,
        "/v1/auth/token",
        &json!({
            "user": paired.user, "install": paired.install, "nonce": nonce, "signature": signature
        }),
        None,
    )?;
    if answer["token_type"] != "Bearer"
        || answer["user"] != paired.user
        || answer["install"] != paired.install
        || answer["team"] != paired.team
        || answer["expires_at"].as_u64().is_none_or(|at| at <= transport.now_ms())
    {
        return Err(invalid());
    }
    let access = answer["access_token"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 16_384 && s.bytes().all(|b| b.is_ascii_graphic()))
        .ok_or_else(invalid)?;
    Ok(Zeroizing::new(access.to_owned()))
}

pub(super) fn finish(
    record: &mut identity::Identity,
    store: &identity::Store,
    transport: &dyn Transport,
) -> Result<Value> {
    let Some(identity::NativeState::Registered { registration, confirmed_at }) = &record.native
    else {
        return super::native::public_result(record);
    };
    if confirmed_at.is_some() {
        return super::native::public_result(record);
    }
    let registration = registration.clone();
    let paired = record.paired.as_ref().ok_or_else(invalid)?;
    let bearer = token(record, transport)?;
    // Never reuse a proof already sent to Native: its nonce has been consumed.
    let key = record.signing_key()?;
    let proof = registration
        .policy_proof(transport.now_ms(), crate::host::random::<16>()?, |message| {
            key.sign(message, &SystemRandom::new())
        })
        .map_err(|_| invalid())?;
    let operation_key = format!("server-network:{}:{}", paired.host, registration.device);
    let answer = transport.backend_post(&record.api, "/v1/ops", &json!({
        "op": "server.network.confirm", "idempotency_key": operation_key,
        "params": {"host": paired.host, "mesh": registration.mesh, "device": registration.device, "proof": proof}
    }), Some(bearer.as_str()))?;
    if answer["ok"] == false {
        return Err(if answer["error"]["retryable"] == true {
            Error::unreachable("server.pair.backend_confirmation_pending")
        } else {
            Error::rejected("server.pair.backend_confirmation_refused")
        });
    }
    let value = &answer["value"];
    let network = &value["network"];
    let at = network["confirmed_at"]
        .as_u64()
        .filter(|at| {
            *at > 0
                && *at <= 9_007_199_254_740_991
                && *at <= transport.now_ms().saturating_add(120_000)
        })
        .ok_or_else(invalid)?;
    if answer["ok"] != true
        || answer["op"] != "server.network.confirm"
        || answer["idempotency_key"] != operation_key
        || value["host"] != paired.host
        || network["state"] != "confirmed"
        || network["tenant"] != registration.tenant
        || network["mesh"] != registration.mesh
        || network["device"] != registration.device
    {
        return Err(invalid());
    }
    record.schema = 3;
    record.native =
        Some(identity::NativeState::Registered { registration, confirmed_at: Some(at) });
    store.save(record)?;
    super::native::public_result(record)
}
