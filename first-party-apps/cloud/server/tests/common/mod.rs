//! The fake control plane of the attach, files and ports tests: wire ops
//! come from the vectors fake (`wire_common`, `backend/catalog/cloud-vectors.json`)
//! plus the link-test names below. It never touches a network.
//!
//! The link tests name their machines `vm-alpha01` and `vm-beta02`, which no
//! vector holds. Three names in [`FakeControlPlane::with`] serve them:
//! `vm-get` (every `cloud.machine.get` answers a running machine of that id),
//! `vm-list` (`cloud.machine.list {}` answers `vm-alpha01` running and
//! `vm-beta02` paused) and `vm-resume` (every `cloud.machine.start` answers
//! the machine running).

#![allow(dead_code)]

#[path = "../wire_common/mod.rs"]
pub mod wire_common;

#[allow(unused_imports)]
pub use wire_common::{WireFake, host, snap, vm};

use cmux_cloud::{
    ControlPlane, RelayError, SessionStatus, WireCall, WireError, WireReply, WireResult,
};
use serde_json::{Value, json};

pub struct FakeControlPlane {
    /// The vectors backend; its `calls` are the wire calls.
    pub wire: WireFake,
    get_any: bool,
    list_two: bool,
    start_any: bool,
    /// `vm-get-unbound`: every `cloud.machine.get` answers a provisioning
    /// machine with no host yet.
    get_unbound: bool,
    /// `connect-info-nofs` / `connect-info-fs`: `cloud.machine.connect_info`
    /// answers a bound machine whose daemon lacks / has `fs-v1`.
    connect_info: Option<bool>,
    /// Machines `vm-resume` started.
    started: Vec<String>,
}

/// A link-test machine record (contract 1.2 shape).
pub fn link_machine(id: &str, status: &str) -> Value {
    json!({ "id": id, "team": "team_t0000000000000000001", "name": id, "status": status,
        "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 },
        "host": if status == "running" { json!(format!("host-{id}")) } else { Value::Null },
        "classic": false, "revision": "1" })
}

/// A `cloud.machine.connect_info` answer (contract 1.7) for a bound,
/// running link-test machine with these daemon capabilities.
pub fn connect_info(id: &str, capabilities: &Value) -> Value {
    json!({ "machine": id, "host": format!("host-{id}"), "epoch": 1, "state": "running",
        "peer": { "wg_public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "overlay_address": "fd7c:6d78::1", "vpc_endpoint": null, "public_ipv6": null },
        "gateway": null, "services": ["daemon", "ssh"],
        "daemon": { "version": "0.1.0", "capabilities": capabilities }, "revision": "1" })
}

impl FakeControlPlane {
    /// The vectors plus the link-test names `vm-get`, `vm-list`,
    /// `vm-resume`, `vm-get-unbound`, `connect-info-nofs`, `connect-info-fs`.
    pub fn with(names: &[&str]) -> Self {
        let mut fake = Self {
            wire: WireFake::load(),
            get_any: false,
            list_two: false,
            start_any: false,
            get_unbound: false,
            connect_info: None,
            started: Vec::new(),
        };
        for name in names {
            match *name {
                "vm-get" => fake.get_any = true,
                "vm-list" => fake.list_two = true,
                "vm-resume" => fake.start_any = true,
                "vm-get-unbound" => fake.get_unbound = true,
                "connect-info-nofs" => fake.connect_info = Some(false),
                "connect-info-fs" => fake.connect_info = Some(true),
                other => panic!("no link-test name {other}"),
            }
        }
        fake
    }

    /// True when nothing reached the backend.
    pub fn no_calls(&self) -> bool {
        self.wire.calls.is_empty()
    }

    /// The wire ops called, in order.
    pub fn ops(&self) -> Vec<String> {
        self.wire.calls.iter().map(|c| c.op.clone()).collect()
    }

    /// The link-test answer for a call no vector holds. `connect_info`
    /// answers every link-test machine (bound, no capabilities) unless a
    /// `connect-info-*` name sets its capabilities; `vm-get-unbound` makes it
    /// `cloud.machine.not_bound`; `vm-beta02` of `vm-list` is paused until a
    /// start.
    fn link_answer(&mut self, call: &WireCall) -> Option<WireReply> {
        let machine = call.params.get("machine").and_then(Value::as_str);
        let link_names = self.get_any || self.list_two || self.get_unbound;
        let value = match (call.op.as_str(), machine) {
            ("cloud.machine.get", Some(id)) if self.get_unbound => link_machine(id, "provisioning"),
            ("cloud.machine.connect_info", Some(_)) if self.get_unbound => {
                return Some(WireReply::Error(WireError {
                    code: "cloud.machine.not_bound".into(),
                    message: "the machine is still provisioning".into(),
                    details: None,
                    retryable: true,
                }));
            }
            ("cloud.machine.connect_info", Some(id))
                if self.connect_info.is_some() || link_names =>
            {
                let capabilities =
                    if self.connect_info == Some(true) { json!(["fs-v1"]) } else { json!([]) };
                let mut info = connect_info(id, &capabilities);
                if self.list_two && id == "vm-beta02" && !self.started.iter().any(|s| s == id) {
                    info["state"] = json!("paused");
                }
                info
            }
            ("cloud.machine.get", Some(id)) if self.get_any => link_machine(id, "running"),
            ("cloud.machine.start", Some(id)) if self.start_any => {
                self.started.push(id.to_owned());
                let mut running = link_machine(id, "running");
                running["revision"] = json!("2");
                json!({ "machine": running })
            }
            ("cloud.machine.list", None) if self.list_two && call.params == json!({}) => {
                json!({ "machines": [link_machine("vm-alpha01", "running"),
                    link_machine("vm-beta02", "paused")], "next_cursor": null, "revision": "1" })
            }
            _ => return None,
        };
        Some(WireReply::Result(WireResult { value, revision: Some("1".into()), replayed: false }))
    }
}

impl ControlPlane for FakeControlPlane {
    fn call(&mut self, call: &WireCall) -> Result<WireReply, RelayError> {
        // The link-test names answer first: `vm-list` replaces the vectors'
        // `list {}` for the tests that name it.
        if self.wire.signed_in
            && let Some(reply) = self.link_answer(call)
        {
            self.wire.calls.push(call.clone());
            return Ok(reply);
        }
        self.wire.reply(call)
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        self.wire.session_status()
    }
}
