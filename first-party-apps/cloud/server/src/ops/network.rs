//! `cloud.network.list` and `cloud.tunnel.*` over the Cloud API routes
//! `GET /api/vm/network` and `POST /api/vm/tunnel/network/{attach,detach,
//! rotate-key}`; `cloud.firewall.*` is in `network_firewall`.
//!
//! The private network and tunnel records stay with the main web owner in
//! v1 (cloud-app.md DECISION 3). The tunnel of this install belongs to
//! `cmux link` (lane 12): these ops take a device fingerprint and a public
//! key only, never a private key. Attach and rotate_key give a device a path
//! into the network, so only origin `user` runs them (ops/mod.rs).

use super::network_args as check;
use super::network_models::{NetworkList, TunnelChange, TunnelKey};
use crate::api::{CloudError, ControlPlane, Ctx, args, codes, decode_answer};
use serde_json::{Map, Value, json};

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.network.list" => {
            args::object(raw, &[])?;
            let path = "/api/vm/network";
            let list: NetworkList = decode_answer(path, ctx.call("GET", path.into(), None)?)?;
            Ok(json!(list))
        }
        "cloud.tunnel.attach" => tunnel_network(ctx, raw, "attach"),
        "cloud.tunnel.detach" => tunnel_network(ctx, raw, "detach"),
        "cloud.tunnel.rotate_key" => rotate_key(ctx, raw),
        _ if name.starts_with("cloud.firewall.") => super::network_firewall::run(ctx, name, raw),
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

/// The fields both tunnel bodies share: the device and the tunnel purpose
/// (`browser` when absent, as the Cloud API defaults).
fn device_body(map: &Map<String, Value>) -> Result<Map<String, Value>, CloudError> {
    let mut body = Map::new();
    body.insert("deviceFingerprint".into(), json!(check::token(map, "deviceFingerprint")?));
    if let Some(purpose) = check::one_of(map, "tunnelPurpose", &["browser", "terminal"])? {
        body.insert("tunnelPurpose".into(), json!(purpose));
    }
    Ok(body)
}

fn tunnel_network<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    raw: &Value,
    verb: &str,
) -> Result<Value, CloudError> {
    let map = args::object(raw, &["deviceFingerprint", "network", "tunnelPurpose"])?;
    let mut body = device_body(map)?;
    body.insert("networkId".into(), json!(check::token(map, "network")?));
    let path = format!("/api/vm/tunnel/network/{verb}");
    let change: TunnelChange =
        decode_answer(&path, ctx.call("POST", path.clone(), Some(Value::Object(body)))?)?;
    Ok(json!(change))
}

fn rotate_key<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    let map = args::object(raw, &["deviceFingerprint", "clientPublicKey", "tunnelPurpose"])?;
    let mut body = device_body(map)?;
    let key = map.get("clientPublicKey").and_then(Value::as_str).unwrap_or_default();
    if !check::is_wireguard_public_key(key) {
        // The value is never echoed: it may be key material.
        return Err(CloudError::invalid(
            "clientPublicKey must be a WireGuard public key (base64 of 32 bytes)",
        ));
    }
    body.insert("clientPublicKey".into(), json!(key));
    let path = "/api/vm/tunnel/network/rotate-key";
    let answer = ctx.call("POST", path.into(), Some(Value::Object(body)))?;
    // Not decode_answer: its message quotes values, and this answer holds keys.
    let rotated: TunnelKey = serde_json::from_value(answer).map_err(|_| {
        CloudError::new(codes::BAD_RESPONSE, format!("{path}: the answer is not a tunnel key"))
    })?;
    if rotated.client_config.as_deref().is_some_and(check::config_has_private_key) {
        return Err(CloudError::new(
            codes::BAD_RESPONSE,
            "the rotate-key answer carries a private key; cmux refuses it",
        ));
    }
    Ok(json!(rotated))
}
