//! Human and JSON output. JSON mode prints the server's response body itself
//! (pretty-printed, keys in the server's order), so fields newer than this CLI
//! still reach the caller. Human mode decodes the body into the generated types.

use std::io::Write;

use cmux_vm_client::types::{
    ApiKeyList, CreatedApiKey, Snapshot, SnapshotList, Vm, VmImageList, VmList,
};
use serde::Serialize;
use serde_json::json;

use crate::error::CliError;

pub struct Printer<'a> {
    json: bool,
    out: &'a mut dyn Write,
}

impl<'a> Printer<'a> {
    pub fn new(json: bool, out: &'a mut dyn Write) -> Self {
        Self { json, out }
    }

    pub fn overlay_policy(&mut self, body: &[u8]) -> Result<(), CliError> {
        let policy: cmux_vm_client::types::DeviceOverlayPolicy = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        self.line(&format!("device {}", policy.device_id.as_str()))?;
        self.line(&format!("ACL version {}", policy.acl_version))?;
        self.line(&format!("policy {}", policy.policy_digest.as_str()))?;
        if policy.peers.is_empty() {
            return self.line("no permitted device peers");
        }
        for peer in policy.peers {
            for (direction, allowed) in [("inbound", peer.inbound), ("outbound", peer.outbound)] {
                for rule in allowed {
                    let port = rule
                        .port
                        .map(|p| p.to_string())
                        .unwrap_or_else(|| "*".into());
                    self.line(&format!(
                        "{} {direction} {}:{port}",
                        peer.device_id.as_str(),
                        rule.protocol
                    ))?;
                }
            }
        }
        Ok(())
    }

    pub fn overlay_server(&mut self, body: &[u8]) -> Result<(), CliError> {
        let server: cmux_vm_client::types::OverlayServer = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        self.line(&format!(
            "{} {}",
            server.id.as_str(),
            server.name.escape_debug()
        ))
    }

    pub fn overlay_server_code(&mut self, body: &[u8]) -> Result<(), CliError> {
        let grant: cmux_vm_client::types::OverlayServerCode = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        self.line(&format!(
            "{} reserved {} expires {}",
            grant.code.as_str(),
            grant.device_id.as_str(),
            grant.expires_at.escape_debug()
        ))
    }

    pub fn overlay_server_list(&mut self, body: &[u8]) -> Result<(), CliError> {
        let list: cmux_vm_client::types::OverlayServerList = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        for server in list.items {
            self.line(&format!(
                "{} {}",
                server.id.as_str(),
                server.name.escape_debug()
            ))?;
        }
        Ok(())
    }

    /// A command's result: JSON as is; text prints stdout, sends the guest's
    /// stderr to stderr, and fails (exit 1) when the command did not exit 0.
    pub fn exec(&mut self, body: &[u8]) -> Result<(), CliError> {
        let value: serde_json::Value = serde_json::from_slice(body).map_err(|e| {
            CliError::unexpected(format!("the cmux VM API sent a body that is not JSON: {e}"))
        })?;
        let code = value["exitCode"].as_i64();
        if self.json {
            self.json_value(&value)?;
        } else {
            write!(self.out, "{}", value["stdout"].as_str().unwrap_or(""))
                .map_err(|e| CliError::unexpected(format!("write output: {e}")))?;
        }
        if code == Some(0) {
            return Ok(());
        }
        let stderr = value["stderr"].as_str().unwrap_or("").trim_end();
        Err(CliError::unexpected(match code {
            Some(code) => format!("the command exited with status {code}: {stderr}"),
            None => format!("the command was killed by its timeout: {stderr}"),
        }))
    }

    pub fn vm(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let vm: Vm = decode(body)?;
        let idle = match vm.idle_timeout_seconds {
            Some(s) if s < 0.0 => "never".to_owned(),
            Some(s) => format!("{s} s"),
            None => "default".to_owned(),
        };
        let lines = [
            ("id", vm.id.as_str().to_owned()),
            ("state", vm.state.to_string()),
            ("vcpus", vm.resources.vcpus.to_string()),
            ("memory", format!("{} MiB", vm.resources.memory_mib)),
            ("disk", format!("{} MiB", vm.resources.disk_mib)),
            ("idle pause", idle),
            ("created", vm.created_at.clone()),
            ("updated", vm.updated_at.clone()),
        ];
        for (label, value) in lines {
            self.line(&format!("{label:<11}{value}"))?;
        }
        Ok(())
    }

    pub fn creation_list(
        &mut self,
        body: &[u8],
        pending: bool,
        index_pages: Option<u32>,
    ) -> Result<(), CliError> {
        let _: cmux_vm_client::types::VmCreationList = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        let page: serde_json::Value = decode(body)?;
        let items = page["items"]
            .as_array()
            .ok_or_else(|| CliError::unexpected("invalid creation page"))?;
        let indexing = page["pendingIndex"].as_str();
        if indexing == Some("building") {
            self.line("pending history is being indexed; continue with the cursor below")?;
        } else if indexing == Some("unavailable") {
            self.line("pending history is incomplete; some retained work needs reconciliation")?;
        }
        if items.is_empty() {
            if !pending || indexing == Some("ready") {
                self.line(if pending {
                    "no pending creations on this page"
                } else {
                    "no creations on this page"
                })?;
            }
        } else {
            self.line(&format!("{:<31} {:<12} VM", "CREATION_KEY", "STATE"))?;
            for item in items {
                let key = item["creationKey"]
                    .as_str()
                    .unwrap_or("unknown")
                    .escape_debug();
                let state = item["state"].as_str().unwrap_or("unknown").escape_debug();
                let id = item["id"].as_str().unwrap_or("unresolved").escape_debug();
                self.line(&format!("{key:<31} {state:<12} {id}"))?;
            }
        }
        if let Some(cursor) = page["nextCursor"].as_str() {
            let mode = if pending { " --pending" } else { "" };
            let budget = index_pages
                .map(|value| format!(" --index-pages {value}"))
                .unwrap_or_default();
            self.line(&format!(
                "more: cmux-vm creation list{mode}{budget} --cursor {}",
                cursor.escape_debug()
            ))?;
        }
        Ok(())
    }

    pub fn creation(&mut self, body: &[u8]) -> Result<(), CliError> {
        let _: cmux_vm_client::types::VmCreationStatus = decode(body)?;
        self.creation_body(body)
    }

    pub fn creation_cancellation(&mut self, body: &[u8]) -> Result<(), CliError> {
        let _: cmux_vm_client::types::VmCreationCancellation = decode(body)?;
        self.creation_body(body)
    }

    fn creation_body(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let value: serde_json::Value = decode(body)?;
        for field in ["state", "id", "cancellation"] {
            if field == "cancellation" && value.get(field).is_none() {
                continue;
            }
            let text = value[field]
                .as_str()
                .unwrap_or("unknown")
                .escape_debug()
                .to_string();
            self.line(&format!("{field:<11}{text}"))?;
        }
        Ok(())
    }

    pub fn retired(&mut self, body: &[u8], id: &str) -> Result<(), CliError> {
        if self.json {
            self.raw_json(body)
        } else {
            self.line(&format!(
                "retired {id}; starts and inbound wakes are fenced"
            ))
        }
    }

    pub fn file_stat(&mut self, body: &[u8]) -> Result<(), CliError> {
        let _: cmux_vm_client::types::FileStat = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        let stat: serde_json::Value = decode(body)?;
        for field in ["kind", "size", "mode", "mtime", "owner", "group"] {
            let value = &stat[field];
            let text = if field == "mode" {
                format!(
                    "{:04o}",
                    value
                        .as_u64()
                        .ok_or_else(|| CliError::unexpected("invalid file mode"))?
                )
            } else if value.is_null() {
                "unknown".to_owned()
            } else if let Some(text) = value.as_str() {
                text.escape_debug().to_string()
            } else {
                value.to_string()
            };
            self.line(&format!("{field:<11}{text}"))?;
        }
        Ok(())
    }

    pub fn identity(&mut self, body: &[u8]) -> Result<(), CliError> {
        let _: cmux_vm_client::types::VmInstanceIdentity = decode(body)?;
        if self.json {
            return self.raw_json(body);
        }
        let value: serde_json::Value = decode(body)?;
        for field in ["id", "scheme", "fingerprint"] {
            self.line(&format!(
                "{field:<13}{}",
                value[field].as_str().unwrap_or_default()
            ))?;
        }
        if let Some(presence) = value["presence"].as_str() {
            self.line(&format!("presence     {presence}"))?;
        }
        Ok(())
    }

    pub fn vm_list(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let page: VmList = decode(body)?;
        if page.items.is_empty() {
            self.line("no VMs")?;
        } else {
            self.line(&format!(
                "{:<30} {:<9} {:>5} {:>10}  CREATED",
                "ID", "STATE", "VCPUS", "MEMORY_MIB"
            ))?;
            for vm in &page.items {
                self.line(&format!(
                    "{:<30} {:<9} {:>5} {:>10}  {}",
                    vm.id.as_str(),
                    vm.state.to_string(),
                    vm.resources.vcpus,
                    vm.resources.memory_mib,
                    vm.created_at
                ))?;
            }
        }
        if let Some(cursor) = &page.next_cursor {
            self.line(&format!("more: cmux-vm list --cursor {cursor}"))?;
        }
        Ok(())
    }

    pub fn image_list(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let images: VmImageList = decode(body)?;
        if images.items.is_empty() {
            self.line("no approved images")?;
        } else {
            self.line(&format!("{:<24} {:<20} NAME", "ID", "REVISION"))?;
            for image in &images.items {
                self.line(&format!(
                    "{:<24} {:<20} {}",
                    image.id.as_str(),
                    image.revision.as_str(),
                    image.display_name
                ))?;
            }
        }
        Ok(())
    }

    pub fn deleted(&mut self, id: &str) -> Result<(), CliError> {
        if self.json {
            return self.json_value(&json!({ "id": id, "deleted": true }));
        }
        self.line(&format!("deleted {id}"))
    }

    pub fn revoked(&mut self, id: &str) -> Result<(), CliError> {
        if self.json {
            return self.json_value(&json!({ "id": id, "revoked": true }));
        }
        self.line(&format!("revoked {id}"))
    }

    pub fn snapshot(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let snapshot: Snapshot = decode(body)?;
        let seconds = |s: Option<f64>| s.map_or_else(|| "none".to_owned(), |s| format!("{s} s"));
        let lines = [
            ("id", snapshot.id.as_str().to_owned()),
            ("name", snapshot.display_name.clone().unwrap_or_default()),
            (
                "source vm",
                snapshot
                    .source_vm_id
                    .as_ref()
                    .map_or_else(|| "deleted".to_owned(), |id| id.as_str().to_owned()),
            ),
            ("ttl", seconds(snapshot.ttl_seconds)),
            ("auto delete", seconds(snapshot.auto_delete_seconds)),
            ("created", snapshot.created_at.clone()),
            (
                "last used",
                snapshot
                    .last_used_at
                    .clone()
                    .unwrap_or_else(|| "never".to_owned()),
            ),
        ];
        for (label, value) in lines {
            self.line(&format!("{label:<12}{value}"))?;
        }
        Ok(())
    }

    pub fn snapshot_list(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let page: SnapshotList = decode(body)?;
        if page.items.is_empty() {
            self.line("no snapshots")?;
        } else {
            self.line(&format!("{:<32} {:<30} CREATED", "ID", "SOURCE_VM"))?;
            for snapshot in &page.items {
                let source = snapshot.source_vm_id.as_ref().map_or("-", |id| id.as_str());
                self.line(&format!(
                    "{:<32} {:<30} {}",
                    snapshot.id.as_str(),
                    source,
                    snapshot.created_at
                ))?;
            }
        }
        if let Some(cursor) = &page.next_cursor {
            self.line(&format!("more: cmux-vm snapshot list --cursor {cursor}"))?;
        }
        Ok(())
    }

    /// The new key's secret goes to stdout once; the server never shows it again.
    pub fn created_api_key(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let key: CreatedApiKey = decode(body)?;
        let scopes: Vec<String> = key.scopes.iter().map(ToString::to_string).collect();
        let lines = [
            ("id", key.id.as_str().to_owned()),
            ("name", key.name.clone()),
            ("scopes", scopes.join(",")),
            (
                "resources",
                key.resource_allowlist
                    .as_ref()
                    .map_or_else(|| "all".to_owned(), |r| r.join(",")),
            ),
            (
                "expires",
                key.expires_at.clone().unwrap_or_else(|| "never".to_owned()),
            ),
            ("key", key.key.clone()),
        ];
        for (label, value) in lines {
            self.line(&format!("{label:<10}{value}"))?;
        }
        self.line("The key is shown only once. Store it now.")
    }

    pub fn api_key_list(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.json {
            return self.raw_json(body);
        }
        let page: ApiKeyList = decode(body)?;
        if page.items.is_empty() {
            return self.line("no API keys");
        }
        self.line(&format!(
            "{:<31} {:<24} {:<24} NAME",
            "ID", "EXPIRES", "REVOKED"
        ))?;
        for key in &page.items {
            self.line(&format!(
                "{:<31} {:<24} {:<24} {}",
                key.id.as_str(),
                key.expires_at.as_deref().unwrap_or("never"),
                key.revoked_at.as_deref().unwrap_or("-"),
                key.name
            ))?;
        }
        Ok(())
    }

    /// Pretty-prints a response body without decoding it into the generated
    /// types, so unknown fields survive.
    fn raw_json(&mut self, body: &[u8]) -> Result<(), CliError> {
        let value: serde_json::Value = serde_json::from_slice(body).map_err(|e| {
            CliError::unexpected(format!("the cmux VM API sent a body that is not JSON: {e}"))
        })?;
        self.json_value(&value)
    }

    fn json_value(&mut self, value: &impl Serialize) -> Result<(), CliError> {
        let text = serde_json::to_string_pretty(value)
            .map_err(|e| CliError::unexpected(format!("encode JSON output: {e}")))?;
        self.line(&text)
    }

    fn line(&mut self, text: &str) -> Result<(), CliError> {
        writeln!(self.out, "{text}").map_err(|e| CliError::unexpected(format!("write output: {e}")))
    }
}

fn decode<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, CliError> {
    serde_json::from_slice(body).map_err(|e| {
        CliError::unexpected(format!(
            "the cmux VM API sent a response this CLI cannot read: {e}"
        ))
    })
}
