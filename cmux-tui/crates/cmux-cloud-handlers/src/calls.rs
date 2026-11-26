//! The Cloud API calls a checked action makes, built from its checked arguments, so the app only
//! sends them. `cloud resize-machine`: [`resize_call`].

use serde::Serialize;
use serde_json::{Value, json};

use crate::Fields;
use crate::args::{self, Args, Checked};

/// One resize: the machine API's arguments and the run's result fields.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ResizeCall {
    /// `{"machine": id, "size": {"cpu"?, "memory_mb"?, "disk_mb"?}}`: only what the run asked to change.
    pub args: Value,
    /// The run's answer fields: `size` (its name) and `disk_gib`, each when given.
    pub fields: Fields,
}

/// `cloud resize-machine` on `machine`: the checked [`args::resize`] as the call the app sends. A
/// disk-only resize sends only `disk_mb`; a size sends its vCPUs and MiB; both go in one call.
pub fn resize_call(given: &Args, machine: &str) -> Checked<ResizeCall> {
    let resize = args::resize(given)?;
    let mut size = serde_json::Map::new();
    if let Some(cpu) = resize.cpu {
        size.insert("cpu".into(), json!(cpu));
    }
    if let Some(memory) = resize.memory_mb {
        size.insert("memory_mb".into(), json!(memory));
    }
    if let Some(storage) = resize.storage_mb {
        size.insert("disk_mb".into(), json!(storage));
    }
    let mut fields = Fields::new();
    if let Some(name) = resize.size {
        fields.insert("size".into(), json!(name));
    }
    if let Some(disk) = resize.disk_gib {
        fields.insert("disk_gib".into(), json!(disk));
    }
    Ok(ResizeCall { args: json!({ "machine": machine, "size": size }), fields })
}

#[cfg(test)]
#[path = "calls_tests.rs"]
mod tests;
