//! Private networking: `vpc` (the team's meshes, also spelled `mesh`),
//! `tunnel` (WireGuard devices and their tunnels, also `tunnels`),
//! `firewall` (a mesh's ACL, applied as a whole) and `https-proxy`.
//!
//! Signed device requests (`tunnel create`, `tunnel rotate`) are read from a
//! file and pass through the generated request types, so a private key or any
//! other local field in that file is never sent.

use std::io::Read;
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, types};
use serde_json::{Value, json};

use crate::error::CliError;
use crate::output::Printer;
use crate::prompt::Prompt;
use crate::{
    Destroy, call, confirm, fetch_body, new_idempotency_key, parse_key, request_body,
    server_request,
};

#[derive(Subcommand, Debug)]
pub(crate) enum VpcCommand {
    /// Create a private network (mesh) for the team
    Create(VpcCreateArgs),
    /// List the team's private networks
    List,
    /// Show a private network
    Get(MeshArg),
    /// Delete a private network (asks to type the mesh id, or needs --yes without a terminal)
    Delete(MeshDeleteArgs),
    /// Add a VM to a private network
    Attach(MeshVmArgs),
    /// Remove a VM from a private network
    Detach(MeshVmArgs),
    /// List the devices enrolled in a private network
    Devices(MeshArg),
    /// List the WireGuard tunnels of a private network's devices
    Tunnels(MeshArg),
}

#[derive(Args, Debug)]
pub(crate) struct VpcCreateArgs {
    /// Display name
    #[arg(long)]
    name: Option<String>,
    /// Reuse this key when retrying, so the network is created only once [default: a new random key]
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct MeshArg {
    /// Mesh id (mesh_...)
    mesh_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct MeshDeleteArgs {
    /// Mesh id (mesh_...)
    mesh_id: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
pub(crate) struct MeshVmArgs {
    /// Mesh id (mesh_...)
    mesh_id: String,
    /// VM id (vm_...)
    vm_id: String,
}

#[derive(Subcommand, Debug)]
pub(crate) enum TunnelCommand {
    /// Enroll a device with its own signed WireGuard public key; prints its tunnel config
    Create(SignedMeshArgs),
    /// List the devices and tunnels of a private network
    List(MeshArg),
    /// Show a tunnel config (tun_...) or a device (dev_...)
    Get(TunnelGetArgs),
    /// Show what a device may reach
    Peers(DeviceArg),
    /// Rotate a device's WireGuard key with a signed request
    #[command(alias = "rotate-key")]
    Rotate(SignedDeviceArgs),
    /// Remove a device and its tunnel (asks to type the device id, or needs --yes without a terminal)
    Delete(DeviceDeleteArgs),
    /// Create a one-time enrollment code for a headless machine; shown once
    EnrollmentCode(EnrollmentCodeArgs),
}

#[derive(Args, Debug)]
pub(crate) struct SignedMeshArgs {
    /// Mesh id (mesh_...)
    mesh_id: String,
    /// Signed enrollment request JSON (name, wgPublicKey, installPublicKey, signedAt, nonce, signature)
    #[arg(long, value_name = "FILE")]
    request: PathBuf,
    /// Reuse this key when retrying, so the device is enrolled only once [default: a new random key]
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct TunnelGetArgs {
    /// Tunnel id (tun_...) or device id (dev_...)
    id: String,
}

#[derive(Args, Debug)]
pub(crate) struct DeviceArg {
    /// Device id (dev_...)
    device_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct SignedDeviceArgs {
    /// Device id (dev_...)
    device_id: String,
    /// Signed rotation request JSON (newPublicKey, signedAt, nonce, signature)
    #[arg(long, value_name = "FILE")]
    request: PathBuf,
}

#[derive(Args, Debug)]
pub(crate) struct DeviceDeleteArgs {
    /// Device id (dev_...)
    device_id: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
pub(crate) struct EnrollmentCodeArgs {
    /// Mesh id (mesh_...)
    mesh_id: String,
    /// Reuse this key when retrying, so only one code is issued [default: a new random key]
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Subcommand, Debug)]
pub(crate) enum FirewallCommand {
    /// Show a private network's rules (default deny: only what they allow is reachable)
    #[command(alias = "list")]
    Get(MeshArg),
    /// Replace a private network's rules from a JSON file and apply them
    Set(FirewallSetArgs),
}

#[derive(Args, Debug)]
pub(crate) struct FirewallSetArgs {
    /// Mesh id (mesh_...)
    mesh_id: String,
    /// JSON file: the output of `firewall get --json` with edited rules, an object with
    /// "rules" (and optionally "expectedVersion"), or an array of rules
    #[arg(long, value_name = "FILE")]
    file: PathBuf,
    /// Apply only if the rules are still at this version [default: the file's version, else the current one]
    #[arg(long, value_name = "VERSION")]
    expected_version: Option<u64>,
}

#[derive(Subcommand, Debug)]
pub(crate) enum HttpsProxyCommand {
    /// Replace an existing HTTPS proxy of a VM; omitted headers clear the previous set
    Set(HttpsProxySetArgs),
}

#[derive(Args, Debug)]
pub(crate) struct HttpsProxySetArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// The proxied hostname
    hostname: String,
    /// Bare HTTPS origin approved by the deployment, such as https://api.example.com
    #[arg(long, value_name = "ORIGIN")]
    destination: String,
    /// Header to add, NAME=VALUE; repeat for several (prefer --headers-file for secrets)
    #[arg(long = "header", value_name = "NAME=VALUE")]
    headers: Vec<String>,
    /// JSON object of header names to values, kept off the command line
    #[arg(long, value_name = "FILE")]
    headers_file: Option<PathBuf>,
    /// Reuse this key when retrying the same replacement
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

fn mesh_id(text: &str) -> Result<types::MeshId, CliError> {
    text.parse::<types::MeshId>()
        .map_err(|_| CliError::usage("invalid mesh id"))
}

fn device_id(text: &str) -> Result<types::DeviceId, CliError> {
    text.parse::<types::DeviceId>()
        .map_err(|_| CliError::usage("invalid device id"))
}

pub(crate) async fn vpc(
    client: &Client,
    command: VpcCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        VpcCommand::Create(args) => {
            let body: types::CreateMeshRequest = request_body(json!({ "displayName": args.name }))?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::MeshCreateMeshIdempotencyKey>(&key_text)?;
            let mesh = fetch_body(client.mesh_create_mesh(Some(&key), None, &body))
                .await
                .map_err(|e| e.with_idempotency_hint(&key_text))?;
            out.mesh(&mesh)
        }
        VpcCommand::List => {
            let body = fetch_body(client.mesh_list_meshes(None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let items = items(&body, "items")?;
            if items.is_empty() {
                return out.line("no private networks");
            }
            out.line(&format!("{:<32} {:<18} NAME", "ID", "IPV4"))?;
            for mesh in items {
                out.line(&format!(
                    "{:<32} {:<18} {}",
                    text(&mesh, "/id"),
                    text(&mesh, "/ipv4Cidr"),
                    text(&mesh, "/displayName").escape_debug()
                ))?;
            }
            Ok(())
        }
        VpcCommand::Get(MeshArg { mesh_id: id }) => {
            let id = mesh_id(&id)?;
            out.mesh(&fetch_body(client.mesh_get_mesh(id.as_str(), None)).await?)
        }
        VpcCommand::Delete(args) => {
            let id = mesh_id(&args.mesh_id)?;
            if !args.yes {
                confirm(prompt, Destroy::DeleteMesh, id.as_str())?;
            }
            call(client.mesh_delete_mesh(id.as_str(), None)).await?;
            out.deleted(id.as_str())
        }
        VpcCommand::Attach(args) => {
            let mesh = mesh_id(&args.mesh_id)?;
            let vm = crate::files::vm_id(&args.vm_id)?;
            let body =
                fetch_body(client.mesh_attach_mesh_vm(mesh.as_str(), vm.as_str(), None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let member: Value = decode(&body)?;
            out.line(&format!(
                "attached {} to {} at {}",
                text(&member, "/vmId"),
                text(&member, "/meshId"),
                text(&member, "/ipv4")
            ))
        }
        VpcCommand::Detach(args) => {
            let mesh = mesh_id(&args.mesh_id)?;
            let vm = crate::files::vm_id(&args.vm_id)?;
            call(client.mesh_detach_mesh_vm(mesh.as_str(), vm.as_str(), None)).await?;
            if out.is_json() {
                return out.json_value(
                    &json!({ "meshId": mesh.as_str(), "vmId": vm.as_str(), "detached": true }),
                );
            }
            out.line(&format!("detached {} from {}", vm.as_str(), mesh.as_str()))
        }
        VpcCommand::Devices(MeshArg { mesh_id: id })
        | VpcCommand::Tunnels(MeshArg { mesh_id: id }) => {
            let id = mesh_id(&id)?;
            let body = fetch_body(client.mesh_list_devices(id.as_str(), None)).await?;
            out.device_list(&body)
        }
    }
}

pub(crate) async fn tunnel(
    client: &Client,
    command: TunnelCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        TunnelCommand::Create(args) => {
            let id = mesh_id(&args.mesh_id)?;
            let request: types::EnrollDeviceRequest = server_request(&args.request)?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::MeshEnrollDeviceIdempotencyKey>(&key_text)?;
            let body =
                fetch_body(client.mesh_enroll_device(id.as_str(), Some(&key), None, &request))
                    .await
                    .map_err(|e| e.with_idempotency_hint(&key_text))?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let enrollment: Value = decode(&body)?;
            out.line(&format!(
                "enrolled {} in {} with tunnel {}",
                text(&enrollment, "/device/id"),
                text(&enrollment, "/device/meshId"),
                text(&enrollment, "/tunnel/id")
            ))?;
            out.tunnel_lines(&enrollment["tunnel"])
        }
        TunnelCommand::List(MeshArg { mesh_id: id }) => {
            let id = mesh_id(&id)?;
            out.device_list(&fetch_body(client.mesh_list_devices(id.as_str(), None)).await?)
        }
        TunnelCommand::Get(TunnelGetArgs { id }) => {
            if let Some(suffix) = id.strip_prefix("tun_") {
                if suffix.len() != 26 || !suffix.bytes().all(|b| b.is_ascii_alphanumeric()) {
                    return Err(CliError::usage("invalid tunnel id"));
                }
                let body = fetch_body(client.mesh_get_tunnel(&id, None)).await?;
                if out.is_json() {
                    return out.raw_json(&body);
                }
                out.tunnel_lines(&decode(&body)?)
            } else {
                let device = device_id(&id).map_err(|_| {
                    CliError::usage("expected a tunnel id (tun_...) or a device id (dev_...)")
                })?;
                let body = fetch_body(client.mesh_get_device(device.as_str(), None)).await?;
                if out.is_json() {
                    return out.raw_json(&body);
                }
                let device: Value = decode(&body)?;
                for (label, pointer) in [
                    ("id", "/id"),
                    ("name", "/name"),
                    ("mesh", "/meshId"),
                    ("tunnel", "/tunnelId"),
                    ("wg key", "/wgPublicKey"),
                    ("created", "/createdAt"),
                ] {
                    out.line(&format!(
                        "{label:<10}{}",
                        text(&device, pointer).escape_debug()
                    ))?;
                }
                Ok(())
            }
        }
        TunnelCommand::Peers(DeviceArg { device_id: id }) => {
            let id = device_id(&id)?;
            let body = fetch_body(client.mesh_get_device_peers(id.as_str(), None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let map: Value = decode(&body)?;
            out.line(&format!(
                "device {} ACL version {}",
                text(&map, "/deviceId"),
                map["aclVersion"]
            ))?;
            let peers = map["peers"].as_array().cloned().unwrap_or_default();
            if peers.is_empty() {
                return out.line("no reachable peers");
            }
            for peer in peers {
                out.line(&serde_json::to_string(&peer).unwrap_or_default())?;
            }
            Ok(())
        }
        TunnelCommand::Rotate(args) => {
            let id = device_id(&args.device_id)?;
            let request: types::RotateKeyRequest = server_request(&args.request)?;
            let body =
                fetch_body(client.mesh_rotate_device_key(id.as_str(), None, &request)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            out.tunnel_lines(&decode(&body)?)
        }
        TunnelCommand::Delete(args) => {
            let id = device_id(&args.device_id)?;
            if !args.yes {
                confirm(prompt, Destroy::DeleteDevice, id.as_str())?;
            }
            call(client.mesh_delete_device(id.as_str(), None)).await?;
            out.deleted(id.as_str())
        }
        TunnelCommand::EnrollmentCode(args) => {
            let id = mesh_id(&args.mesh_id)?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::MeshCreateEnrollmentCodeIdempotencyKey>(&key_text)?;
            let request = types::CreateEnrollmentCodeRequest::Object(serde_json::Map::new());
            let body = fetch_body(client.mesh_create_enrollment_code(
                id.as_str(),
                Some(&key),
                None,
                &request,
            ))
            .await
            .map_err(|e| e.with_idempotency_hint(&key_text))?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let code: Value = decode(&body)?;
            out.line(&format!("code      {}", text(&code, "/code")))?;
            out.line(&format!("mesh      {}", text(&code, "/meshId")))?;
            out.line(&format!("expires   {}", text(&code, "/expiresAt")))?;
            out.line("The code is shown only once and works once.")
        }
    }
}

pub(crate) async fn firewall(
    client: &Client,
    command: FirewallCommand,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        FirewallCommand::Get(MeshArg { mesh_id: id }) => {
            let id = mesh_id(&id)?;
            let body = fetch_body(client.mesh_get_mesh_acl(id.as_str(), None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let acl: Value = decode(&body)?;
            out.line(&format!(
                "mesh {} version {}",
                text(&acl, "/meshId"),
                acl["version"]
            ))?;
            let rules = acl["rules"].as_array().cloned().unwrap_or_default();
            if rules.is_empty() {
                return out.line("no rules: nothing is reachable");
            }
            for rule in rules {
                out.line(&serde_json::to_string(&rule).unwrap_or_default())?;
            }
            Ok(())
        }
        FirewallCommand::Set(args) => {
            let id = mesh_id(&args.mesh_id)?;
            let file = read_json_file(&args.file, "rules file")?;
            let (rules, file_version) = acl_from_file(file)?;
            let version = match args.expected_version.or(file_version) {
                Some(version) => version,
                None => {
                    let current = fetch_body(client.mesh_get_mesh_acl(id.as_str(), None)).await?;
                    decode(&current)?["version"]
                        .as_u64()
                        .ok_or_else(|| CliError::unexpected("the current rules have no version"))?
                }
            };
            let body: types::PutAclRequest =
                request_body(json!({ "expectedVersion": version, "rules": rules }))?;
            let applied = fetch_body(client.mesh_put_mesh_acl(id.as_str(), None, &body)).await?;
            if out.is_json() {
                return out.raw_json(&applied);
            }
            let applied: Value = decode(&applied)?;
            out.line(&format!(
                "applied version {} to {}: {} rules ({} created, {} deleted) in {} ms",
                applied["version"],
                text(&applied, "/meshId"),
                applied["ruleCount"],
                applied["rulesCreated"],
                applied["rulesDeleted"],
                applied["applyMs"]
            ))
        }
    }
}

/// The rules and the version a firewall file is based on.
pub(crate) fn acl_from_file(file: Value) -> Result<(Value, Option<u64>), CliError> {
    match file {
        Value::Array(_) => Ok((file, None)),
        Value::Object(mut fields) => {
            let rules = fields
                .remove("rules")
                .filter(Value::is_array)
                .ok_or_else(|| CliError::usage("the rules file needs a \"rules\" array"))?;
            let version = fields
                .get("expectedVersion")
                .or_else(|| fields.get("version"))
                .and_then(Value::as_u64);
            Ok((rules, version))
        }
        _ => Err(CliError::usage(
            "the rules file must be a JSON object with \"rules\" or an array of rules",
        )),
    }
}

pub(crate) async fn https_proxy(
    client: &Client,
    command: HttpsProxyCommand,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    let HttpsProxyCommand::Set(args) = command;
    let id = crate::files::vm_id(&args.vm_id)?;
    let headers = proxy_headers(&args.headers, args.headers_file.as_deref())?;
    let body: types::ReplaceVmHttpsProxyRequest =
        request_body(json!({ "destination": args.destination, "headers": headers }))?;
    let key = args
        .idempotency_key
        .as_deref()
        .map(parse_key::<types::VmsReplaceVmHttpsProxyIdempotencyKey>)
        .transpose()?;
    let receipt = fetch_body(client.vms_replace_vm_https_proxy(
        id.as_str(),
        &args.hostname,
        key.as_ref(),
        None,
        &body,
    ))
    .await?;
    if out.is_json() {
        return out.raw_json(&receipt);
    }
    let receipt: Value = decode(&receipt)?;
    out.line(&format!(
        "replaced HTTPS proxy {} on {}",
        text(&receipt, "/hostname").escape_debug(),
        text(&receipt, "/id")
    ))
}

/// Header flags and file merged into one object; `None` when there are none,
/// which the server reads as "clear the headers".
pub(crate) fn proxy_headers(
    flags: &[String],
    file: Option<&Path>,
) -> Result<Option<Value>, CliError> {
    let mut headers = serde_json::Map::new();
    if let Some(file) = file {
        match read_json_file(file, "headers file")? {
            Value::Object(fields) => {
                for (name, value) in fields {
                    let Value::String(value) = value else {
                        return Err(CliError::usage(
                            "header values in the headers file must be strings",
                        ));
                    };
                    headers.insert(name, Value::String(value));
                }
            }
            _ => return Err(CliError::usage("the headers file must be a JSON object")),
        }
    }
    for flag in flags {
        let Some((name, value)) = flag.split_once('=') else {
            return Err(CliError::usage("--header takes NAME=VALUE"));
        };
        if name.is_empty() {
            return Err(CliError::usage("--header takes NAME=VALUE"));
        }
        headers.insert(name.to_owned(), Value::String(value.to_owned()));
    }
    Ok((!headers.is_empty()).then_some(Value::Object(headers)))
}

/// A JSON file of at most 1 MiB. Its content is never echoed in errors.
fn read_json_file(path: &Path, what: &str) -> Result<Value, CliError> {
    let file = std::fs::File::open(path)
        .map_err(|_| CliError::usage(format!("could not read the {what}")))?;
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| CliError::usage(format!("could not read the {what}")))?;
    if bytes.len() > 1024 * 1024 {
        return Err(CliError::usage(format!("the {what} exceeds 1 MiB")));
    }
    serde_json::from_slice(&bytes)
        .map_err(|_| CliError::usage(format!("the {what} is not valid JSON")))
}

fn items(body: &[u8], field: &str) -> Result<Vec<Value>, CliError> {
    Ok(decode(body)?[field].as_array().cloned().unwrap_or_default())
}

fn text(value: &Value, pointer: &str) -> String {
    match value.pointer(pointer) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => "-".to_owned(),
        Some(other) => other.to_string(),
    }
}

fn decode(body: &[u8]) -> Result<Value, CliError> {
    serde_json::from_slice(body).map_err(|e| {
        CliError::unexpected(format!(
            "the cmux VM API sent a response this CLI cannot read: {e}"
        ))
    })
}

impl Printer<'_> {
    fn mesh(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let mesh: Value = decode(body)?;
        for (label, pointer) in [
            ("id", "/id"),
            ("name", "/displayName"),
            ("ipv4", "/ipv4Cidr"),
            ("created", "/createdAt"),
        ] {
            self.line(&format!(
                "{label:<9}{}",
                text(&mesh, pointer).escape_debug()
            ))?;
        }
        Ok(())
    }

    fn device_list(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let devices = items(body, "items")?;
        if devices.is_empty() {
            return self.line("no devices");
        }
        self.line(&format!("{:<31} {:<31} NAME", "DEVICE", "TUNNEL"))?;
        for device in devices {
            self.line(&format!(
                "{:<31} {:<31} {}",
                text(&device, "/id"),
                text(&device, "/tunnelId"),
                text(&device, "/name").escape_debug()
            ))?;
        }
        Ok(())
    }

    fn tunnel_lines(&mut self, tunnel: &Value) -> Result<(), CliError> {
        let endpoint = format!(
            "{}:{}",
            text(tunnel, "/endpointHost"),
            text(tunnel, "/endpointPort")
        );
        for (label, value) in [
            ("tunnel", text(tunnel, "/id")),
            ("device", text(tunnel, "/deviceId")),
            ("endpoint", endpoint),
            ("address", text(tunnel, "/interfaceAddress")),
            ("mesh addr", text(tunnel, "/meshAddress")),
            ("allowed", text(tunnel, "/allowedIps")),
        ] {
            self.line(&format!("{label:<10}{}", value.escape_debug()))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_firewall_file_may_be_get_output_an_object_or_an_array() {
        let rule = json!({"src": ["a"], "dst": ["b"], "allow": ["tcp:22"]});
        let (rules, version) =
            acl_from_file(json!({"meshId": "m", "version": 3, "rules": [rule.clone()]})).unwrap();
        assert_eq!((rules, version), (json!([rule.clone()]), Some(3)));
        let (_, version) =
            acl_from_file(json!({"expectedVersion": 5, "version": 3, "rules": []})).unwrap();
        assert_eq!(version, Some(5));
        assert_eq!(acl_from_file(json!([rule])).unwrap().1, None);
        assert!(acl_from_file(json!({"rules": "nope"})).is_err());
        assert!(acl_from_file(json!(7)).is_err());
    }

    #[test]
    fn proxy_headers_take_name_value_pairs_and_none_clears_them() {
        assert_eq!(proxy_headers(&[], None).unwrap(), None);
        assert_eq!(
            proxy_headers(&["x-a=1".to_owned(), "x-b=c=d".to_owned()], None).unwrap(),
            Some(json!({"x-a": "1", "x-b": "c=d"}))
        );
        assert!(proxy_headers(&["novalue".to_owned()], None).is_err());
        assert!(proxy_headers(&["=v".to_owned()], None).is_err());
    }
}
