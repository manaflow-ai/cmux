//! Classic cmux.com's `/api/vm` routes the NEXT app still calls (tunnel, firewall, SCP, domains
//! and publications): none has a NEXT route yet, so each is sent as it was, with the same body,
//! deadline and answer. A machine's resize, snapshots, restore and fork are the Cloud app server's
//! `cloud.machine.resize` and `cloud.snapshot.*` ops, on cmux-platform; `vm.networks` is
//! cmux-platform's network target (network.rs).

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_json::JsonSet as _;
use reqwest::Method;
use serde_json::{Map, Value, json};

use super::http::Http;
use super::{Failure, optional_text, pick, text};

const DEFAULT: Duration = Duration::from_secs(20);

pub(crate) async fn run(
    http: &Http,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    let secs = Duration::from_secs;
    match call {
        "vm.scp_endpoint" => {
            let id = text(args, "id")?;
            let body = json!({ "publicKey": text(args, "publicKey")? });
            let endpoint = http
                .classic(
                    Method::POST,
                    &["api", "vm", id, "scp-endpoint"],
                    &[],
                    Some(body),
                    None,
                    secs(100),
                )
                .await?;
            if safe_scp_endpoint(&endpoint, now_secs()) {
                Ok(endpoint)
            } else {
                Err(Failure::Decoding(format!(
                    "/api/vm/{id}/scp-endpoint returned an unsafe endpoint"
                )))
            }
        }
        "vm.tunnel_enroll" => {
            let body = args.get("body").cloned().unwrap_or_else(|| json!({}));
            http.classic(Method::POST, &["api", "vm", "tunnel"], &[], Some(body), None, secs(60))
                .await
        }
        "vm.tunnel_revoke" => {
            let query = [("deviceId", text(args, "deviceId")?.to_owned())];
            http.classic(Method::DELETE, &["api", "vm", "tunnel"], &query, None, None, DEFAULT)
                .await
                .map(|_| Value::Null)
        }
        "vm.tunnel_attach" | "vm.tunnel_detach" | "vm.tunnel_rotate_key" => {
            let action = match call {
                "vm.tunnel_attach" => "attach",
                "vm.tunnel_detach" => "detach",
                _ => "rotate-key",
            };
            let mut body =
                pick(args, &["deviceFingerprint", "networkId", "clientPublicKey", "tunnelPurpose"]);
            if body.get("tunnelPurpose").is_none() {
                body.set("tunnelPurpose", json!("browser"));
            }
            http.classic(
                Method::POST,
                &["api", "vm", "tunnel", "network", action],
                &[],
                Some(body),
                None,
                secs(60),
            )
            .await
        }
        "vm.firewall_list" => {
            let query: Vec<(&str, String)> = ["vpcId", "vmId", "tunnelId"]
                .into_iter()
                .filter_map(|name| optional_text(args, name).map(|v| (name, v.to_owned())))
                .collect();
            let list = http
                .classic(Method::GET, &["api", "vm", "firewall"], &query, None, None, DEFAULT)
                .await?;
            field(list, "rules", "/api/vm/firewall")
        }
        "vm.firewall_get" => {
            let query = [("ruleId", text(args, "ruleId")?.to_owned())];
            http.classic(Method::GET, &["api", "vm", "firewall"], &query, None, None, DEFAULT).await
        }
        "vm.firewall_create" => {
            let mut body = Map::new();
            for side in ["source", "destination"] {
                let endpoint =
                    args.get(side).and_then(Value::as_object).cloned().unwrap_or_default();
                body.insert(side.to_owned(), Value::Object(endpoint));
            }
            if let Some(description) = optional_text(args, "description") {
                body.insert("description".into(), json!(description));
            }
            http.classic(
                Method::POST,
                &["api", "vm", "firewall"],
                &[],
                Some(Value::Object(body)),
                None,
                secs(60),
            )
            .await
        }
        "vm.firewall_delete" => {
            let query = [("ruleId", text(args, "ruleId")?.to_owned())];
            http.classic(Method::DELETE, &["api", "vm", "firewall"], &query, None, None, secs(60))
                .await
                .map(|_| Value::Null)
        }
        "vm.domains" => {
            let list = http
                .classic(Method::GET, &["api", "vm", "domains"], &[], None, None, DEFAULT)
                .await?;
            field(list, "domains", "/api/vm/domains")
        }
        "vm.publications" => {
            let list = http
                .classic(Method::GET, &["api", "vm", "publications"], &[], None, None, DEFAULT)
                .await?;
            field(list, "publications", "/api/vm/publications")
        }
        "vm.provision_api" => {
            let mut body = pick(args, &["vmId", "port", "accessMode"]);
            if let Some(name) = optional_text(args, "keyName") {
                body.set("name", json!(name));
            }
            http.classic(Method::POST, &["api", "vm", "apis"], &[], Some(body), None, secs(120))
                .await
        }
        "vm.publication_api_keys" => {
            let publication = text(args, "publication")?;
            let list = http
                .classic(
                    Method::GET,
                    &["api", "vm", "publications", publication, "api-keys"],
                    &[],
                    None,
                    None,
                    DEFAULT,
                )
                .await?;
            field(list, "apiKeys", "/api/vm/publications/api-keys")
        }
        "vm.revoke_publication_api_key" => {
            let (publication, key_id) = (text(args, "publication")?, text(args, "keyId")?);
            let segments = ["api", "vm", "publications", publication, "api-keys", key_id];
            let revoked = http.classic(Method::DELETE, &segments, &[], None, None, DEFAULT).await?;
            field(revoked, "apiKey", "/api/vm/publications/api-keys")
        }
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

/// `value[name]`, or a decoding failure naming `path`.
pub(crate) fn field(mut value: Value, name: &str, path: &str) -> Result<Value, Failure> {
    value
        .get_mut(name)
        .map(Value::take)
        .filter(|v| !v.is_null())
        .ok_or_else(|| Failure::Decoding(format!("{path}: no {name}")))
}

/// A private SCP route the app may hand to `scp`: port 22, user `cmux`, an ed25519 host key,
/// and not expired.
pub(crate) fn safe_scp_endpoint(endpoint: &Value, now: i64) -> bool {
    let either = |a: &str, b: &str| endpoint.get(a).or_else(|| endpoint.get(b));
    endpoint.get("port").and_then(Value::as_i64) == Some(22)
        && endpoint.get("username").and_then(Value::as_str) == Some("cmux")
        && either("hostPublicKey", "host_public_key")
            .and_then(Value::as_str)
            .is_some_and(|k| k.starts_with("ssh-ed25519 "))
        && either("expiresAtUnix", "expires_at_unix")
            .and_then(Value::as_i64)
            .is_some_and(|t| t > now)
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}
