//! Human and JSON output. JSON mode prints the API response unchanged in
//! shape, one document per command, so it can be piped to `jq`.

use std::io::Write;

use cmux_vm_client::types::{Vm, VmList};
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

    pub fn vm(&mut self, vm: &Vm) -> Result<(), CliError> {
        if self.json {
            return self.json_value(vm);
        }
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

    pub fn vm_list(&mut self, page: &VmList) -> Result<(), CliError> {
        if self.json {
            return self.json_value(page);
        }
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

    pub fn deleted(&mut self, vm_id: &str) -> Result<(), CliError> {
        if self.json {
            return self.json_value(&json!({ "id": vm_id, "deleted": true }));
        }
        self.line(&format!("deleted {vm_id}"))
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
