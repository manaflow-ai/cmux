//! The session host's relay carrier route: the machine's slot on the
//! platform's relay (pure). cmux design/cloud-carrier.md, "One carrier"
//! item 1 and slice 4.
//!
//! The platform puts the route in the bind request file
//! `/var/lib/cmux/bind.json` as its `carrier` section:
//!
//! ```json
//! {"carrier": {"relay": "relay+do://relay.example", "machine": "vm_…", "slot": "…"}}
//! ```
//!
//! At the bind commit the Cloud role keeps it in [`CARRIER_FILE`] (root,
//! 0600), with the team, the grant issuer and the bind's keyset that the
//! session host's carrier grant verifier needs:
//!
//! ```json
//! {"relay": "relay+do://…", "machine": "vm_…", "slot": "…",
//!  "team": "team_…", "issuer": "cmux:cloud:production",
//!  "keyset": {"version": "…", "keys": {"<kid>": "…"}}}
//! ```
//!
//! cmux-host copies the public part (issuer, machine, team, keyset) to
//! [`GRANT_CONFIG_FILE`] (0644), which the session host, running as the work
//! user, loads with `--carrier-grant-config` (cmux-remote `GrantConfig`).
//!
//! A machine without the file has no carrier. With it, the session host also
//! registers on the machine's relay slot: `--relay <relay> --relay-slot
//! <slot>`, with a ticket command that runs the host entry's `cloud
//! carrier-ticket` (`<current>/bin/cmux host cloud carrier-ticket`, the
//! command cmux-host itself runs as) for each Register. The session host's
//! own binary (`cmux-tui`) has no `host` verbs. That verb asks the Cloud agent, which
//! holds the install key, for a Register ticket (`POST
//! /v1/cloud/machines/{machine}/carrier`, `cloud/carrier_ticket.rs`). The
//! slot comes from the platform because it derives it with a key the
//! machine does not hold. cmux-host respawns the session host when the file
//! appears or changes.
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

/// The machine's carrier, kept by the Cloud role at the bind commit.
pub const CARRIER_FILE: &str = "/var/lib/cmux/carrier.json";

/// The agent display's `cmux.rd/1` socket (#37218): an owner's carrier
/// session reaches it through cmux-remote's `local-socket` service.
pub const DESKTOP_SOCKET: &str = "/run/cmux-rd/desktop.sock";

/// The session host's carrier grant config, written by cmux-host.
pub const GRANT_CONFIG_FILE: &str = "/run/cmux/carrier-grant.json";

/// [`CARRIER_FILE`]'s name in its directory.
pub const CARRIER_FILE_NAME: &str = "carrier.json";

/// The session host's flags that carry the route.
const ROUTE_FLAGS: [&str; 6] = [
    "--relay",
    "--relay-slot",
    "--relay-ticket-command",
    "--relay-ticket-command-arg",
    "--carrier-grant-config",
    "--remote-local-socket",
];

/// [`CARRIER_FILE`]: the route, plus the team, the carrier grant issuer
/// (`cmux:cloud:<environment>`) and the keyset (`{version, keys}`) of the
/// bind.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CarrierFile {
    pub route: CarrierRoute,
    pub team: String,
    pub issuer: String,
    pub keyset: Value,
}

impl CarrierFile {
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "relay": self.route.relay,
            "machine": self.route.machine,
            "slot": self.route.slot,
            "team": self.team,
            "issuer": self.issuer,
            "keyset": self.keyset,
        })
    }

    /// [`GRANT_CONFIG_FILE`]'s text: only public fields.
    pub fn grant_config(&self) -> Value {
        serde_json::json!({
            "issuer": self.issuer,
            "machine": self.route.machine,
            "team": self.team,
            "keyset": self.keyset,
        })
    }
}

/// The verb the ticket command runs, after the host entry
/// ([`CarrierRoute::args`]).
pub const TICKET_VERB: [&str; 2] = ["cloud", "carrier-ticket"];

impl CarrierRoute {
    /// The session host's extra arguments. `host` is the command that runs
    /// cmux-host's verbs, the program first: `[<current>/bin/cmux, host]`
    /// as the units run it, or `[cmux-host]` for the standalone binary
    /// (`linux::host_entry`). It is never the session host's own binary:
    /// `cmux-tui host …` is not a verb (it answers `unknown resource scope
    /// "host"`), so a ticket command naming it fails every Register.
    pub fn args(&self, host: &[String], grant_config: &Path) -> Vec<String> {
        let (program, host_args) = host.split_first().map_or(("", &[][..]), |(p, a)| (p, a));
        let mut args = vec![
            "--relay".to_owned(),
            self.relay.clone(),
            "--relay-slot".to_owned(),
            self.slot.clone(),
            "--relay-ticket-command".to_owned(),
            program.to_owned(),
        ];
        for arg in host_args.iter().map(String::as_str).chain(TICKET_VERB) {
            args.push("--relay-ticket-command-arg".to_owned());
            args.push(arg.to_owned());
        }
        args.push("--carrier-grant-config".to_owned());
        args.push(grant_config.display().to_string());
        args.push("--remote-local-socket".to_owned());
        args.push(DESKTOP_SOCKET.to_owned());
        args
    }
}

/// The `carrier` section of `bind.json`, refused unless it has exactly
/// `relay`, `machine` and `slot`, each in its shape.
pub fn parse_section(section: &Value) -> Result<CarrierRoute, String> {
    let Value::Object(section) = section else {
        return Err("`carrier` is not an object".to_owned());
    };
    if let Some(key) = section.keys().find(|k| !matches!(k.as_str(), "relay" | "machine" | "slot"))
    {
        return Err(format!("`carrier` has an unknown key {key:?}"));
    }
    route(section)
}

/// [`CARRIER_FILE`]'s text (`None` when absent): `Ok(None)` without a file,
/// or why it is refused.
pub fn parse_file(text: Option<&str>) -> Result<Option<CarrierFile>, String> {
    let Some(text) = text else { return Ok(None) };
    let root: Value =
        serde_json::from_str(text).map_err(|e| format!("carrier.json is not JSON: {e}"))?;
    let Value::Object(root) = root else {
        return Err("carrier.json is not an object".to_owned());
    };
    if let Some(key) = root.keys().find(|k| {
        !matches!(k.as_str(), "relay" | "machine" | "slot" | "team" | "issuer" | "keyset")
    }) {
        return Err(format!("`carrier` has an unknown key {key:?}"));
    }
    let route = route(&root)?;
    let team = field(&root, "team")?;
    let issuer = field(&root, "issuer")?;
    if !team.starts_with("team_") || !issuer.starts_with("cmux:cloud:") {
        return Err("`carrier` has no valid team or issuer".to_owned());
    }
    let keyset = root.get("keyset").cloned().unwrap_or(Value::Null);
    cmux_link::keyset::read_keyset(&keyset)
        .map_err(|refused| format!("`carrier.keyset` refused: {}", refused.as_str()))?;
    Ok(Some(CarrierFile { route, team, issuer, keyset }))
}

/// [`CARRIER_FILE`]'s new text when a keyset fetch (`cloud/carrier_keyset.rs`)
/// brought a keyset for the same issuer that differs from the kept one; `None` when
/// there is no valid file, the keyset is not valid, or nothing changed.
/// The Cloud role writes it (temp file, then rename); the supervisor's
/// watch then rewrites [`GRANT_CONFIG_FILE`] from it, and the session
/// host's verifier re-reads that at the rotated key's first grant. The
/// route is unchanged, so the session host keeps running.
pub fn with_keyset(text: Option<&str>, issuer: &str, keyset: &Value) -> Option<String> {
    let mut file = parse_file(text).ok().flatten()?;
    if file.issuer != issuer || file.keyset == *keyset {
        return None;
    }
    cmux_link::keyset::read_keyset(keyset).ok()?;
    file.keyset = keyset.clone();
    Some(format!("{}\n", file.to_json()))
}

/// The route flags in a session host's `argv` (`/proc/<pid>/cmdline`), in
/// order: what [`CarrierRoute::args`] gave the running host, or nothing.
pub fn args_in(argv: &[String]) -> Vec<String> {
    let mut found = Vec::new();
    let mut rest = argv.iter();
    while let Some(arg) = rest.next() {
        if ROUTE_FLAGS.contains(&arg.as_str())
            && let Some(value) = rest.next()
        {
            found.push(arg.clone());
            found.push(value.clone());
        }
    }
    found
}

fn route(section: &Map<String, Value>) -> Result<CarrierRoute, String> {
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
    Ok(CarrierRoute { relay, machine, slot })
}

fn field(section: &Map<String, Value>, name: &str) -> Result<String, String> {
    match section.get(name) {
        Some(Value::String(value)) => Ok(value.clone()),
        Some(other) => Err(format!("`carrier.{name}` {other} is not a string")),
        None => Err(format!("`carrier.{name}` is missing")),
    }
}

/// A host name (dot-separated labels of lowercase letters, digits and
/// inner hyphens) with an optional port 1-65535; no path, query or
/// credentials.
fn valid_host(authority: &str) -> bool {
    let (host, port) = match authority.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    let port_ok = port.is_none_or(|port| {
        (1..=5).contains(&port.len())
            && port.bytes().all(|b| b.is_ascii_digit())
            && port.parse::<u16>().is_ok_and(|port| port > 0)
    });
    let label_ok = |label: &str| {
        (1..=63).contains(&label.len())
            && label.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    };
    port_ok && (1..=253).contains(&host.len()) && host.split('.').all(label_ok)
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
