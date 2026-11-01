//! Typed records of the cmux-next Cloud backend (`cmux.wire/1`,
//! plans/cmux-next/cloud-client-contract.md 1.2). Field names are the
//! backend's snake_case. Unknown fields are ignored; a missing optional
//! field is `None`. Timestamps are epoch milliseconds; revisions are
//! decimal strings that only grow per entity.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MachineStatus {
    #[default]
    Provisioning,
    Starting,
    Running,
    Pausing,
    Paused,
    Deleting,
    Failed,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Size {
    #[serde(default)]
    pub cpu: Option<u32>,
    #[serde(default)]
    pub memory_mb: Option<u64>,
    #[serde(default)]
    pub disk_mb: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Image {
    pub id: String,
    #[serde(default)]
    pub daemon_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdlePolicy {
    #[serde(default)]
    pub idle_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineError {
    pub code: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub at: Option<i64>,
}

/// Non-secret host metadata that an owner may attach to a machine record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct MachinePlatform {
    #[serde(default)]
    pub os: Option<String>,
    #[serde(default)]
    pub arch: Option<String>,
}

/// `CloudMachine`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub creator: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub size: Option<Size>,
    #[serde(default)]
    pub status: MachineStatus,
    #[serde(default)]
    pub image: Option<Image>,
    /// The overlay host id; `None` until the machine is bound.
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub classic: bool,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub last_active_at: Option<i64>,
    #[serde(default)]
    pub idle_policy: Option<IdlePolicy>,
    /// Optional idle-pause diagnostics from the cmux REST VM projection.
    /// Keep the object opaque here so this relay preserves new diagnostic
    /// fields without coupling the app server to the cron implementation.
    #[serde(
        rename = "idlePause",
        alias = "idle_pause",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub idle_pause: Option<serde_json::Value>,
    #[serde(default)]
    pub error: Option<MachineError>,
    /// US dollars an hour while running, from the backend's rate table
    /// (display only; the page keeps no rates). A JSON number, kept as one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hourly_rate_usd: Option<serde_json::Number>,
    /// When the machine last started running (epoch ms); `None` unless it
    /// is running. The page shows rate x time running as "about $X so far".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running_since: Option<i64>,
    /// Optional non-secret platform metadata supplied by the machine owner.
    #[serde(default)]
    pub platform: Option<MachinePlatform>,
    /// Stable capability names; credentials, paths and account labels stay in
    /// the session-host operations rather than this record.
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub revision: Revision,
}

impl Machine {
    /// Whether this record advertises one exact capability name.
    pub fn has_capability(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|candidate| candidate == capability)
    }
}

/// `CloudSnapshot`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot {
    pub id: String,
    #[serde(default)]
    pub machine: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub size_mb: Option<u64>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub created_at: Option<i64>,
    pub revision: Revision,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanLimits {
    pub max_active: u32,
    pub max_saved: u32,
    #[serde(default)]
    pub memory_options_mb: Vec<u64>,
    #[serde(default)]
    pub locked_memory_options_mb: Vec<u64>,
    #[serde(default)]
    pub vm_hours_included: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanUsage {
    pub active: u32,
    pub saved: u32,
    #[serde(default)]
    pub vm_hours_used: Option<f64>,
    #[serde(default)]
    pub period_end: Option<i64>,
}

/// `CloudPlan`: limits and usage in one record (`cloud.usage.get` folded in).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub plan_id: String,
    /// The plan that lifts this plan's limits ("See plans"); `None` (null)
    /// when no plan does.
    #[serde(default)]
    pub upgrade_plan: Option<String>,
    pub limits: PlanLimits,
    pub usage: PlanUsage,
}

/// `cloud.machine.list`: one page.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MachinePage {
    pub machines: Vec<Machine>,
    #[serde(default)]
    pub next_cursor: Option<String>,
    /// The team's registry revision when the page was read.
    #[serde(default)]
    pub revision: Option<Revision>,
}

/// `cloud.machine.connect_info` (contract 1.7): how `cmux link` reaches a
/// machine. Peer data comes in every bound state, paused included. It
/// carries no credential: the dial token is `cloud.machine.link_token`,
/// which only `cmux link` calls.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectInfo {
    pub machine: String,
    pub host: String,
    /// A restore or re-bind raises it; the link refuses a lower one.
    pub epoch: u64,
    pub state: MachineStatus,
    pub peer: Peer,
    /// This install's own tunnel into the VM's VPC; null = no tunnel path.
    #[serde(default)]
    pub gateway: Option<serde_json::Value>,
    /// What this caller may dial: `daemon`, `ssh`.
    pub services: Vec<String>,
    pub daemon: DaemonInfo,
    /// The caller's kind on this machine (`owner` | `team`, cmux-platform#89);
    /// absent from a Worker that predates it. Any value that is not a string
    /// reads as absent, so a bad value fails closed instead of failing the
    /// whole record.
    #[serde(default, deserialize_with = "string_or_none")]
    pub vm_kind: Option<String>,
    pub revision: Revision,
}

/// A string, or `None` for any other JSON value (`ConnectInfo::vm_kind`).
fn string_or_none<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(match serde_json::Value::deserialize(d)? {
        serde_json::Value::String(s) => Some(s),
        _ => None,
    })
}

impl ConnectInfo {
    /// The Worker said the signed-in caller owns this machine: only the
    /// exact value `owner`; missing or any other value is not the owner.
    pub fn caller_owns_vm(&self) -> bool {
        self.vm_kind.as_deref() == Some("owner")
    }

    /// Whether the Cloud policy permits this server to dial one service.
    /// Service names are opaque wire values; callers must not infer access
    /// from machine state or display fields.
    pub fn has_service(&self, service: &str) -> bool {
        self.services.iter().any(|candidate| candidate == service)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Peer {
    pub wg_public_key: String,
    pub overlay_address: String,
    #[serde(default)]
    pub vpc_endpoint: Option<String>,
    #[serde(default)]
    pub public_ipv6: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonInfo {
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

impl DaemonInfo {
    /// Whether the connected daemon advertised a capability for this control
    /// generation. Missing or unknown names fail closed at call sites.
    pub fn has_capability(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|candidate| candidate == capability)
    }
}

/// A `cmux.wire/1` revision: a decimal string (`^[0-9]+$`), compared as a
/// number of any length.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Revision(String);

impl Revision {
    pub fn zero() -> Self {
        Self("0".into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Revision {
    type Error = String;

    fn try_from(s: String) -> Result<Self, String> {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            return Err(format!("{s:?} is not a decimal revision"));
        }
        // Leading zeros carry nothing; strip them so length orders first.
        let digits = s.trim_start_matches('0');
        Ok(Self(if digits.is_empty() { "0".into() } else { digits.to_owned() }))
    }
}

impl From<Revision> for String {
    fn from(r: Revision) -> String {
        r.0
    }
}

impl Ord for Revision {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.len().cmp(&other.0.len()).then_with(|| self.0.cmp(&other.0))
    }
}

impl PartialOrd for Revision {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests {
    use super::{ConnectInfo, DaemonInfo, Machine, MachineStatus, Peer, Revision};
    use serde_json::json;

    fn info() -> ConnectInfo {
        ConnectInfo {
            machine: "vm-1".into(),
            host: "host-1".into(),
            epoch: 1,
            state: MachineStatus::Running,
            peer: Peer {
                wg_public_key: "wg".into(),
                overlay_address: "10.0.0.2".into(),
                vpc_endpoint: None,
                public_ipv6: None,
            },
            gateway: None,
            services: vec!["daemon".into(), "ssh".into()],
            daemon: DaemonInfo {
                version: Some("0.1.0".into()),
                capabilities: vec!["fs-v1".into()],
            },
            vm_kind: None,
            revision: Revision::zero(),
        }
    }

    #[test]
    fn only_the_exact_owner_value_owns_the_vm() {
        let mut info = info();
        assert!(!info.caller_owns_vm());
        for (value, owns) in
            [("owner", true), ("team", false), ("Owner", false), (" owner", false), ("", false)]
        {
            info.vm_kind = Some(value.into());
            assert_eq!(info.caller_owns_vm(), owns, "{value:?}");
        }
    }

    #[test]
    fn a_vm_kind_that_is_not_a_string_reads_as_not_the_owner() {
        let mut wire = serde_json::to_value(info()).expect("encode");
        for bad in
            [json!(true), json!(1), json!(["owner"]), json!({ "kind": "owner" }), json!(null)]
        {
            wire["vm_kind"] = bad.clone();
            let decoded: ConnectInfo = serde_json::from_value(wire.clone()).expect("decodes");
            assert!(!decoded.caller_owns_vm(), "{bad}");
        }
        wire.as_object_mut().expect("object").remove("vm_kind");
        let decoded: ConnectInfo = serde_json::from_value(wire).expect("decodes");
        assert!(!decoded.caller_owns_vm());
    }

    #[test]
    fn capability_and_service_checks_are_exact_and_fail_closed() {
        let info = info();
        assert!(info.has_service("daemon"));
        assert!(info.daemon.has_capability("fs-v1"));
        assert!(!info.has_service("http"));
        assert!(!info.daemon.has_capability("fs-v2"));
    }

    #[test]
    fn machine_metadata_is_optional_and_preserves_non_secret_capabilities() {
        let machine: Machine = serde_json::from_str(
            r#"{"id":"vm-1","revision":"2","platform":{"os":"linux","arch":"x86_64"},"capabilities":["terminal","agent_session"]}"#,
        )
        .expect("machine metadata decodes");
        assert_eq!(
            machine.platform.as_ref().and_then(|platform| platform.os.as_deref()),
            Some("linux")
        );
        assert!(machine.has_capability("agent_session"));
        assert!(!machine.has_capability("provider_secret"));

        let older: Machine = serde_json::from_str(r#"{"id":"vm-old","revision":"3"}"#)
            .expect("older machine decodes");
        assert!(older.platform.is_none());
        assert!(older.capabilities.is_empty());
    }

    #[test]
    fn machine_cost_fields_relay_to_the_page() {
        let source = serde_json::json!({
            "id": "vm-cost",
            "revision": "7",
            "hourly_rate_usd": 0.2645,
            "running_since": 1_700_000_000_000i64
        });
        let machine: Machine = serde_json::from_value(source.clone()).expect("cost fields decode");
        let encoded = serde_json::to_value(&machine).expect("cost fields encode");
        assert_eq!(encoded["hourly_rate_usd"], source["hourly_rate_usd"]);
        assert_eq!(encoded["running_since"], source["running_since"]);

        let paused: Machine = serde_json::from_value(
            serde_json::json!({ "id": "vm-paused", "revision": "8", "hourly_rate_usd": 0.2645, "running_since": null }),
        )
        .expect("paused machine decodes");
        let encoded = serde_json::to_value(&paused).expect("paused machine encodes");
        assert!(encoded.get("running_since").is_none());
        let older: Machine =
            serde_json::from_value(serde_json::json!({ "id": "vm-old", "revision": "9" }))
                .expect("older machine decodes");
        assert!(
            serde_json::to_value(older)
                .expect("older machine encodes")
                .get("hourly_rate_usd")
                .is_none()
        );
    }

    #[test]
    fn machine_idle_pause_diagnostics_round_trip_without_changing_older_shape() {
        let source = serde_json::json!({
            "id": "vm-idle",
            "revision": "4",
            "idlePause": {
                "minutes": 30,
                "lastCheckedAt": 1_700_000_000_000i64,
                "idleSince": 1_699_998_000_000i64,
                "lastApiActivityAt": 1_699_999_000_000i64,
                "privateAddressKnown": true,
                "lastDecision": {
                    "at": 1_700_000_000_000i64,
                    "outcome": "idle",
                    "reason": "idle",
                    "run": { "checked": 8, "elapsedMs": 120 }
                }
            }
        });
        let machine: Machine =
            serde_json::from_value(source.clone()).expect("idle diagnostics decode");
        assert_eq!(
            machine.idle_pause.as_ref().expect("idle diagnostics")["minutes"],
            source["idlePause"]["minutes"]
        );
        let encoded = serde_json::to_value(&machine).expect("idle diagnostics encode");
        assert_eq!(encoded["idlePause"], source["idlePause"]);

        let snake = serde_json::json!({ "id": "vm-snake", "revision": "5", "idle_pause": { "minutes": 0 } });
        let snake_machine: Machine = serde_json::from_value(snake).expect("snake alias decode");
        assert_eq!(
            snake_machine.idle_pause.as_ref().expect("snake idle diagnostics")["minutes"],
            0
        );
        let older: Machine =
            serde_json::from_value(serde_json::json!({ "id": "vm-old", "revision": "6" }))
                .expect("older machine decode");
        assert!(older.idle_pause.is_none());
        assert!(
            serde_json::to_value(older).expect("older machine encode").get("idlePause").is_none()
        );
    }
}
