//! Human and JSON output. JSON mode prints the server's response body itself
//! (pretty-printed, keys in the server's order), so fields newer than this CLI
//! still reach the caller. Human mode decodes the body into the generated types.

use std::io::Write;

use cmux_vm_client::types::{ApiKeyList, CreatedApiKey, Snapshot, SnapshotList, Vm, VmList};
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
