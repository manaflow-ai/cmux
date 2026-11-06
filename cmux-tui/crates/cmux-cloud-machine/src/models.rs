//! The small Cloud API models (a machine's files, exec, SCP route, snapshots, stats, network,
//! firewall, publications and previews), each read from the server's answer into the app's JSON
//! ([`read`], by kind). The readers keep each answer's alternate spellings and defaults; the app
//! decodes their output with no rules of its own.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::json::{self, Strict, present};
use crate::{harness_copy, limits, record};

/// The kinds [`read`] reads.
pub const KINDS: &[&str] = &[
    "machine_classic",
    "machine_next",
    "file_entry",
    "file_entries",
    "file_stat",
    "file_contents",
    "exec_result",
    "scp_endpoint",
    "snapshot",
    "snapshots",
    "harness_login_copy",
    "limits",
];

/// The server's `value` of `kind`, as the app's JSON; an error says what was wrong.
pub fn read(kind: &str, value: &Value) -> Strict<Value> {
    let to = |value: Result<Value, serde_json::Error>| value.map_err(|error| error.to_string());
    match kind {
        "machine_classic" => to(serde_json::to_value(record::from_classic(value)?)),
        "machine_next" => {
            to(serde_json::to_value(record::from_next(value).ok_or("not a machine record")?))
        }
        "file_entry" => file_entry(value),
        "file_entries" => list(value, "entries", file_entry),
        "file_stat" => file_stat(value),
        "file_contents" => file_contents(value),
        "exec_result" => exec_result(value),
        "scp_endpoint" => scp_endpoint(value),
        "snapshot" => snapshot(value),
        "snapshots" => list(value, "snapshots", snapshot),
        "harness_login_copy" => to(serde_json::to_value(harness_copy::read(value)?)),
        "limits" => to(serde_json::to_value(limits::read(value))),
        _ => Err(format!("unknown kind {kind}")),
    }
}

fn list(value: &Value, key: &str, item: fn(&Value) -> Strict<Value>) -> Strict<Value> {
    let object = json::object(value, "answer")?;
    let Some(Value::Array(items)) = object.get(key) else { return Err(format!("{key}: missing")) };
    items.iter().map(item).collect::<Strict<Vec<_>>>().map(Value::Array)
}

/// The size, mode and modification time a directory entry and a stat share.
fn file_facts(object: &Map<String, Value>, into: &mut Map<String, Value>) -> Strict<()> {
    into.insert("size".into(), json!(json::integer(object, "size")?));
    into.insert("mode".into(), json!(json::integer(object, "mode")?));
    into.insert("modifiedAt".into(), json!(json::number(object, "modifiedAt")?));
    Ok(())
}

/// One entry of a machine directory: `kind` defaults to `file`.
fn file_entry(value: &Value) -> Strict<Value> {
    let object = json::object(value, "entry")?;
    let name = json::string(object, "name")?.ok_or("name: missing")?;
    let mut entry = Map::new();
    entry.insert("name".into(), json!(name));
    entry.insert(
        "kind".into(),
        json!(json::string(object, "kind")?.unwrap_or_else(|| "file".into())),
    );
    file_facts(object, &mut entry)?;
    Ok(Value::Object(entry))
}

/// A stat: `kind`, else `isDirectory` as `directory` or `file`.
fn file_stat(value: &Value) -> Strict<Value> {
    let object = json::object(value, "stat")?;
    let kind = match json::string(object, "kind")? {
        Some(kind) => kind,
        None if json::boolean(object, "isDirectory")?.unwrap_or(false) => "directory".into(),
        None => "file".into(),
    };
    let mut stat = Map::new();
    stat.insert("path".into(), json!(json::string(object, "path")?));
    stat.insert("kind".into(), json!(kind));
    file_facts(object, &mut stat)?;
    Ok(Value::Object(stat))
}

/// A file read: the bytes as base64, under `dataBase64` or the older `data`.
fn file_contents(value: &Value) -> Strict<Value> {
    let object = json::object(value, "contents")?;
    let data = match json::string(object, "dataBase64")? {
        Some(data) => data,
        None => json::string(object, "data")?.ok_or("data: missing")?,
    };
    Ok(
        json!({"path": json::string(object, "path")?, "dataBase64": data, "size": json::integer(object, "size")?}),
    )
}

/// A command's result: a missing exit code is -1, missing output empty.
fn exec_result(value: &Value) -> Strict<Value> {
    let object = json::object(value, "exec")?;
    Ok(json!({
        "exitCode": json::integer(object, "exitCode")?.unwrap_or(-1),
        "stdout": json::string(object, "stdout")?.unwrap_or_default(),
        "stderr": json::string(object, "stderr")?.unwrap_or_default(),
    }))
}

/// A short-lived private SCP route, in camel or snake case. The private key stays on the caller.
fn scp_endpoint(value: &Value) -> Strict<Value> {
    let object = json::object(value, "endpoint")?;
    let either = |camel: &str, snake: &str| -> Strict<Option<Value>> {
        Ok(match present(object, camel) {
            Some(value) => Some(value.clone()),
            None => present(object, snake).cloned(),
        })
    };
    let host_key =
        either("hostPublicKey", "host_public_key")?.and_then(|key| key.as_str().map(str::to_owned));
    let expires = either("expiresAtUnix", "expires_at_unix")?.as_ref().and_then(json::int);
    Ok(json!({
        "host": json::string(object, "host")?.ok_or("host: missing")?,
        "port": json::integer(object, "port")?.ok_or("port: missing")?,
        "username": json::string(object, "username")?.ok_or("username: missing")?,
        "hostPublicKey": host_key.ok_or("hostPublicKey: missing")?,
        "expiresAtUnix": expires.ok_or("expiresAtUnix: missing")?,
    }))
}

/// One snapshot: its id under `snapshotId` or `id`.
fn snapshot(value: &Value) -> Strict<Value> {
    let object = json::object(value, "snapshot")?;
    let id = match json::string(object, "snapshotId")? {
        Some(id) => id,
        None => json::string(object, "id")?.ok_or("id: missing")?,
    };
    Ok(json!({"id": id, "name": json::string(object, "name")?}))
}

/// A machine port published under a generated hostname, with its new key: the fields its
/// provision action answers CLI, MCP and agent callers. Optional publication fields are left out
/// when the server did not supply them.
pub fn provisioned_api_fields(api: &ProvisionedApi) -> BTreeMap<&'static str, String> {
    let mut fields = BTreeMap::from([
        ("url", api.url.clone()),
        ("api_key_id", api.api_key.id.clone()),
        ("key", api.token.clone()),
        ("cookie", api.cookie.clone()),
    ]);
    if let Some(id) = &api.publication.id {
        fields.insert("publication_id", id.clone());
    }
    if let Some(access) = &api.publication.access_mode {
        fields.insert("access", access.clone());
    }
    fields
}

/// `POST /api/vm/apis`'s answer. `token` is in this answer only.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProvisionedApi {
    pub url: String,
    pub publication: Publication,
    pub api_key: PublicationApiKey,
    pub token: String,
    pub cookie_name: String,
    pub cookie: String,
}

/// A Cloud VM publication, the redacted view the UI receives.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Publication {
    pub id: Option<String>,
    pub hostname: Option<String>,
    pub url: Option<String>,
    pub domain_kind: Option<String>,
    pub vm_id: Option<String>,
    pub port: Option<i64>,
    pub public_port: Option<i64>,
    pub target_port: Option<i64>,
    #[serde(rename = "protocol")]
    pub protocol_name: Option<String>,
    pub access_mode: Option<String>,
    pub team_id: Option<String>,
    pub state: Option<String>,
    pub routing_revision: Option<i64>,
    pub verification: Option<PublicationVerification>,
}

/// A publication's verification, kept to its state (DNS records stay server-side).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PublicationVerification {
    pub verification_id: Option<String>,
    pub domain: Option<String>,
    pub state: Option<String>,
}

/// One API key of a protected publication; the server answers only its last characters.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicationApiKey {
    pub id: String,
    #[serde(default)]
    pub publication_id: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub hint: Option<String>,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub expires_at: Option<String>,
    #[serde(default)]
    pub revoked_at: Option<String>,
}

/// A custom domain of the signed-in account.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Domain {
    pub id: Option<String>,
    pub hostname: Option<String>,
    pub verification_state: Option<String>,
    pub certificate_state: Option<String>,
    pub created_at: Option<String>,
    pub publications: Option<Vec<DomainPublication>>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DomainPublication {
    pub id: Option<String>,
    pub hostname: Option<String>,
    pub state: Option<String>,
}

/// One end of a firewall rule.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FirewallEndpoint {
    pub vm_id: Option<String>,
    pub vpc_id: Option<String>,
    pub tunnel_id: Option<String>,
    pub cidr: Option<String>,
    #[serde(rename = "public")]
    pub is_public: Option<bool>,
    pub port: Option<i64>,
    #[serde(rename = "protocol")]
    pub protocol_name: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FirewallRule {
    pub id: String,
    pub action: String,
    pub source: FirewallEndpoint,
    pub destination: FirewallEndpoint,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Network {
    pub id: String,
    #[serde(default)]
    pub cidr: Option<String>,
    #[serde(default)]
    pub cidr_v6: Option<String>,
    pub scope: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelNetworkMutation {
    pub tunnel_id: String,
    pub network_id: String,
    #[serde(default)]
    pub address_v4: Option<String>,
    #[serde(default)]
    pub address_v6: Option<String>,
    #[serde(default)]
    pub client_public_key: Option<String>,
    #[serde(default)]
    pub server_public_key: Option<String>,
    #[serde(default)]
    pub client_config: Option<String>,
}

/// `GET /api/vm/{id}/stats`; reading never wakes a sleeping machine.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineStats {
    pub state: String,
    #[serde(default)]
    pub cpus: Option<i64>,
    #[serde(default)]
    pub cpu_percent: Option<f64>,
    #[serde(default)]
    pub memory_total_mb: Option<f64>,
    #[serde(default)]
    pub memory_used_mb: Option<f64>,
    #[serde(default)]
    pub disk_total_mb: Option<f64>,
    #[serde(default)]
    pub disk_used_mb: Option<f64>,
}

/// The platform's detected TCP listeners and their authenticated browser previews.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachinePreviews {
    pub machine: String,
    pub previews: Vec<MachinePreview>,
    pub listening: Vec<i64>,
    pub unavailable: Vec<PreviewUnavailable>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachinePreview {
    pub port: i64,
    /// A short-lived authentication bootstrap URL; open this rather than the bare origin.
    pub url: String,
    pub origin: String,
    /// Unix milliseconds.
    pub expires_at: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewUnavailable {
    pub port: i64,
    pub code: String,
}

/// One anonymous, expiring link to a live preview; lists carry no secret URL.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewShareLink {
    pub link_id: String,
    pub creator: String,
    pub team: String,
    pub machine: String,
    pub port: i64,
    pub hostname: String,
    pub rule_id: String,
    pub created_at: i64,
    pub expires_at: i64,
    #[serde(default)]
    pub max_uses: Option<i64>,
    pub redemptions: i64,
    #[serde(default)]
    pub revoked_at: Option<i64>,
}

#[cfg(test)]
mod tests;
