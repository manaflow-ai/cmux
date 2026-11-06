//! The session host's relay carrier route: the machine's slot on the
//! platform's relay, from the host config `/etc/cmux/host.json` (pure).
//! cmux design/cloud-carrier.md, "One carrier" item 1 and slice 4.
//!
//! Off unless the config has a `carrier` section:
//!
//! ```json
//! {"carrier": {"relay": "relay+do://relay.example", "machine": "vm_…", "slot": "…"}}
//! ```
//!
//! With it, the session host also registers on the machine's relay slot:
//! `--relay <relay> --relay-slot <slot>`, with a ticket command that runs
//! this binary's `host cloud carrier-ticket` for each Register. That verb
//! asks the Cloud agent, which holds the install key, for a Register ticket
//! (`POST /v1/cloud/machines/{machine}/carrier`, `cloud/carrier_ticket.rs`).
//! The slot comes from the config because the platform derives it with a
//! key the machine does not hold.
//!
//! A ticket only lets the daemon take its slot. The session on the slot is
//! still cmux-remote's Noise session, with the daemon key the Mac pins.

use std::path::Path;

use serde_json::{Map, Value};

/// The only relay scheme a Cloud carrier uses: the Durable Object relay.
pub const RELAY_SCHEME: &str = "relay+do://";

/// The machine's carrier slot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CarrierRoute {
    /// `relay+do://<host>`.
    pub relay: String,
    /// `vm_` and 20 lowercase letters or digits.
    pub machine: String,
    /// The relay slot: 22 to 128 base64url characters.
    pub slot: String,
}

/// The verb the ticket command runs (after the binary and its `host` verb).
pub const TICKET_VERB: [&str; 3] = ["host", "cloud", "carrier-ticket"];

impl CarrierRoute {
    /// The session host's extra arguments. `bin` is the session host's own
    /// binary, which serves the `host` verbs too.
    pub fn args(&self, bin: &Path) -> Vec<String> {
        let mut args = vec![
            "--relay".to_owned(),
            self.relay.clone(),
            "--relay-slot".to_owned(),
            self.slot.clone(),
            "--relay-ticket-command".to_owned(),
            bin.display().to_string(),
        ];
        for arg in TICKET_VERB {
            args.push("--relay-ticket-command-arg".to_owned());
            args.push(arg.to_owned());
        }
        args
    }
}

/// The carrier route of `text` (the host config, `None` when absent):
/// `Ok(None)` when it has no `carrier` section, or why it is refused.
pub fn parse(text: Option<&str>) -> Result<Option<CarrierRoute>, String> {
    let Some(text) = text else { return Ok(None) };
    let root: Value =
        serde_json::from_str(text).map_err(|e| format!("host.json is not JSON: {e}"))?;
    let Value::Object(root) = root else { return Err("host.json is not an object".to_owned()) };
    let section = match root.get("carrier") {
        None => return Ok(None),
        Some(Value::Object(section)) => section,
        Some(_) => return Err("`carrier` is not an object".to_owned()),
    };
    if let Some(key) = section.keys().find(|k| !matches!(k.as_str(), "relay" | "machine" | "slot"))
    {
        return Err(format!("`carrier` has an unknown key {key:?}"));
    }
    let relay = field(section, "relay")?;
    let host = relay
        .strip_prefix(RELAY_SCHEME)
        .ok_or_else(|| format!("`carrier.relay` {relay:?} is not a {RELAY_SCHEME} route"))?;
    if !valid_host(host) {
        return Err(format!("`carrier.relay` {relay:?} has no valid host"));
    }
    let machine = field(section, "machine")?;
    if !valid_machine(&machine) {
        return Err(format!("`carrier.machine` {machine:?} is not a machine id"));
    }
    let slot = field(section, "slot")?;
    if !valid_slot(&slot) {
        return Err("`carrier.slot` is not 22 to 128 base64url characters".to_owned());
    }
    Ok(Some(CarrierRoute { relay, machine, slot }))
}

fn field(section: &Map<String, Value>, name: &str) -> Result<String, String> {
    match section.get(name) {
        Some(Value::String(value)) => Ok(value.clone()),
        Some(other) => Err(format!("`carrier.{name}` {other} is not a string")),
        None => Err(format!("`carrier.{name}` is missing")),
    }
}

/// A host name with an optional port, no path, query or credentials.
fn valid_host(host: &str) -> bool {
    (1..=253).contains(&host.len())
        && host.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b".-:".contains(&b))
        && !host.starts_with(['.', '-', ':'])
}

/// `vm_` and 20 lowercase letters or digits (cmux-platform's machine id).
pub fn valid_machine(machine: &str) -> bool {
    machine.strip_prefix("vm_").is_some_and(|id| {
        id.len() == 20 && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// A relay slot: 22 (128 bits) to 128 base64url characters.
pub fn valid_slot(slot: &str) -> bool {
    (22..=128).contains(&slot.len())
        && slot.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
#[path = "carrier_entry_tests.rs"]
mod tests;
