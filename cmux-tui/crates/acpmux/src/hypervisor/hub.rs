//! The hub's command lease as a [`CommandSource`] (RFD 0100 step 4, cmux-platform#1896).
//!
//! A joined host leases the slot commands its team's hub booked on it with its own machine
//! credential (`cmm_...`, the one `acpmux machine join` stored), no fleet token:
//!
//! - `POST <hub>/v1/machines/joined/commands/lease` `{"max": N}` answers
//!   `{"commands": [{"id", "slot", "type", "shape": {"vcpu", "memGiB", "diskGiB"}, ...}]}`.
//!   A command not acked within the hub's lease seconds is handed out again, same id.
//! - `POST <hub>/v1/machines/joined/commands/ack` `{"slot", "id", "type", "outcome":
//!   "done|failed", "detail"}`. `pending: true` in the answer means the hub changed its mind
//!   meanwhile; the next pass leases it.
//!
//! The hub's `slot` is the VM name (`cmux-<slot>`); a bare name is taken as the slot itself.
//! Every verb is idempotent by slot name on the driver side, so a command handed out twice
//! (an ack lost on the way) does no harm.

use super::source::{Command, CommandSource, Envelope, Outcome};
use super::{SlotName, SlotSpec};
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

pub const LEASE_PATH: &str = "/v1/machines/joined/commands/lease";
pub const ACK_PATH: &str = "/v1/machines/joined/commands/ack";
/// The hub's cap on one lease's size.
pub const MAX_LEASE: u32 = 32;
/// The hub's cap on an ack's detail, in characters.
const DETAIL_MAX: usize = 1024;

/// A POST to the hub with this machine's credential: the status and the JSON answer (Null when
/// the body is not JSON).
pub trait HubPost {
    fn post(&mut self, path: &str, body: &Value) -> Result<(u16, Value)>;
}

#[derive(Debug, Deserialize)]
struct Leased {
    #[serde(default)]
    commands: Vec<HubCommand>,
}

#[derive(Clone, Debug, Deserialize)]
struct HubCommand {
    id: String,
    slot: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    shape: Option<Shape>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Shape {
    vcpu: Option<u32>,
    mem_gi_b: Option<f64>,
    disk_gi_b: Option<u64>,
}

/// What an ack needs back: the hub's own slot text and type, which the envelope does not keep.
#[derive(Clone, Debug)]
struct Handed {
    slot: String,
    kind: String,
}

pub struct HubSource<P> {
    post: P,
    max: u32,
    handed: HashMap<String, Handed>,
}

impl<P: HubPost> HubSource<P> {
    pub fn new(post: P, max: u32) -> Self {
        Self { post, max: max.clamp(1, MAX_LEASE), handed: HashMap::new() }
    }
}

fn slot_of(text: &str) -> Result<SlotName> {
    SlotName::from_domain(text)
        .map_or_else(|| SlotName::parse(text), Ok)
        .with_context(|| format!("the hub's slot {text:?}"))
}

fn spec_of(shape: Option<&Shape>) -> SlotSpec {
    let mut spec = SlotSpec::default();
    if let Some(shape) = shape {
        if let Some(v) = shape.vcpu.filter(|v| *v > 0) {
            spec.vcpus = v;
        }
        if let Some(m) = shape.mem_gi_b.filter(|m| *m > 0.0) {
            spec.memory_mib = (m * 1024.0).round() as u64;
        }
        if let Some(d) = shape.disk_gi_b {
            spec.disk_gib = d;
        }
    }
    spec
}

/// The host agent's command for a hub command; `Err` names why it cannot be done.
fn command_of(c: &HubCommand) -> Result<Command> {
    let slot = slot_of(&c.slot)?;
    Ok(match c.kind.as_str() {
        // The hub keeps no lease clocks for a joined slot yet: none fire on the host, and the
        // hub's own destroy ends the slot.
        "create" => {
            Command::Create { slot, spec: spec_of(c.shape.as_ref()), lease: Default::default() }
        }
        "pause" => Command::Pause { slot, mode: Default::default() },
        "resume" => Command::Resume { slot },
        "destroy" => Command::Destroy { slot },
        other => bail!("command type {other:?} is not one this host agent does"),
    })
}

/// The hub's error code (`machine.unauthorized`), else the status.
fn refusal(status: u16, answer: &Value) -> String {
    let code = answer.get("error").and_then(|e| e.as_str().or_else(|| e.get("code")?.as_str()));
    match (status, code) {
        (401, _) => format!(
            "the hub refused this machine's credential (401{}): rejoin with `acpmux machine join`",
            code.map(|c| format!(" {c}")).unwrap_or_default()
        ),
        (404, _) => "the hub serves no command lease (404): registered machines are off for \
                     this team"
            .to_owned(),
        (s, Some(c)) => format!("the hub answered {s} {c}"),
        (s, None) => format!("the hub answered {s}"),
    }
}

fn detail_of(outcome: &Outcome) -> Option<String> {
    let text = outcome.error.as_deref()?;
    Some(text.chars().take(DETAIL_MAX).collect())
}

impl<P: HubPost> HubSource<P> {
    fn ack_hub(
        &mut self,
        id: &str,
        handed: &Handed,
        ok: bool,
        detail: Option<String>,
    ) -> Result<()> {
        let mut body = json!({
            "slot": handed.slot,
            "id": id,
            "type": handed.kind,
            "outcome": if ok { "done" } else { "failed" },
        });
        if let Some(d) = detail {
            body["detail"] = Value::String(d);
        }
        let (status, answer) = self.post.post(ACK_PATH, &body)?;
        if !(200..300).contains(&status) {
            bail!("ack {id}: {}", refusal(status, &answer));
        }
        Ok(())
    }
}

impl<P: HubPost> CommandSource for HubSource<P> {
    fn take(&mut self) -> Result<Vec<Envelope>> {
        let (status, answer) = self.post.post(LEASE_PATH, &json!({ "max": self.max }))?;
        if !(200..300).contains(&status) {
            bail!("lease: {}", refusal(status, &answer));
        }
        let leased: Leased =
            serde_json::from_value(answer).context("the hub's lease answer does not parse")?;
        let mut out = Vec::new();
        for c in leased.commands {
            let handed = Handed { slot: c.slot.clone(), kind: c.kind.clone() };
            match command_of(&c) {
                Ok(command) => {
                    self.handed.insert(c.id.clone(), handed);
                    out.push(Envelope { id: c.id, command });
                }
                // One this host cannot do is failed back at once with the reason, so the hub's
                // backoff and give-up apply instead of a silent re-lease every lease period.
                Err(e) => {
                    if let Err(ack) = self.ack_hub(&c.id, &handed, false, Some(format!("{e:#}"))) {
                        eprintln!("hypervisor: {ack:#}");
                    }
                }
            }
        }
        Ok(out)
    }

    fn ack(&mut self, envelope: &Envelope, outcome: &Outcome) -> Result<()> {
        let Some(handed) = self.handed.remove(&envelope.id) else {
            bail!("ack {}: this source did not hand it out", envelope.id);
        };
        self.ack_hub(&envelope.id, &handed, outcome.ok, detail_of(outcome))
    }
}

/// [`HubPost`] over HTTPS with this machine's join: its hub origin and its live `cmm_`
/// credential, read again for each request so a rotation or revocation is seen at once.
pub struct JoinedHub {
    origin: String,
    client: reqwest::Client,
    runtime: tokio::runtime::Handle,
}

impl JoinedHub {
    /// This machine's join; an error says why there is none usable (never joined, revoked,
    /// copied from another box). Call from inside the tokio runtime (serve's blocking thread).
    pub fn open() -> Result<Self> {
        let Some(record) = crate::machine_record::load()? else {
            bail!("this machine is not joined to a hub: run `acpmux machine join` first");
        };
        let origin = crate::cli::cloud_join::hub_origin(&record.hub_origin)?;
        crate::cli::cloud_join::read_join_credential(&origin)?;
        Ok(Self {
            origin,
            client: crate::cli::cloud_join::http_client()?,
            runtime: tokio::runtime::Handle::current(),
        })
    }

    pub fn origin(&self) -> &str {
        &self.origin
    }
}

impl HubPost for JoinedHub {
    fn post(&mut self, path: &str, body: &Value) -> Result<(u16, Value)> {
        let token =
            zeroize::Zeroizing::new(crate::cli::cloud_join::read_join_credential(&self.origin)?);
        let request = self
            .client
            .post(format!("{}{path}", self.origin))
            .bearer_auth(token.as_str())
            .timeout(std::time::Duration::from_secs(30))
            .json(body);
        self.runtime.block_on(async move {
            let response = request
                .send()
                .await
                .map_err(|e| anyhow::anyhow!("the hub: {}", e.without_url()))?;
            let status = response.status().as_u16();
            let bytes = response.bytes().await.unwrap_or_default();
            Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hypervisor::SlotState;

    #[derive(Default)]
    struct FakeHub {
        leases: Vec<(u16, Value)>,
        sent: Vec<(String, Value)>,
        ack_status: u16,
    }

    impl HubPost for &mut FakeHub {
        fn post(&mut self, path: &str, body: &Value) -> Result<(u16, Value)> {
            self.sent.push((path.to_owned(), body.clone()));
            if path == ACK_PATH {
                return Ok((
                    if self.ack_status == 0 { 200 } else { self.ack_status },
                    json!({"acked": true, "pending": false}),
                ));
            }
            Ok(if self.leases.is_empty() {
                (200, json!({"commands": []}))
            } else {
                self.leases.remove(0)
            })
        }
    }

    /// Slots in memory, each verb idempotent by name as the real drivers are.
    #[derive(Default)]
    struct MemDriver(std::cell::RefCell<std::collections::BTreeMap<SlotName, SlotState>>);

    impl crate::hypervisor::HypervisorDriver for MemDriver {
        fn create(&self, slot: &SlotName, _: &SlotSpec) -> Result<SlotState> {
            Ok(*self.0.borrow_mut().entry(slot.clone()).or_insert(SlotState::Running))
        }
        fn pause(&self, slot: &SlotName, _: crate::hypervisor::PauseMode) -> Result<SlotState> {
            let mut m = self.0.borrow_mut();
            let s = m.get_mut(slot).context("no such slot")?;
            *s = SlotState::Paused;
            Ok(*s)
        }
        fn resume(&self, slot: &SlotName) -> Result<SlotState> {
            let mut m = self.0.borrow_mut();
            let s = m.get_mut(slot).context("no such slot")?;
            *s = SlotState::Running;
            Ok(*s)
        }
        fn destroy(&self, slot: &SlotName) -> Result<()> {
            self.0.borrow_mut().remove(slot);
            Ok(())
        }
        fn list(&self) -> Result<Vec<crate::hypervisor::Slot>> {
            Ok(self
                .0
                .borrow()
                .iter()
                .map(|(n, s)| crate::hypervisor::Slot { name: n.clone(), state: *s })
                .collect())
        }
    }

    fn done(state: Option<SlotState>) -> Outcome {
        Outcome { ok: true, state, error: None }
    }

    #[test]
    fn a_hub_lease_becomes_host_agent_commands_and_acks_go_back_with_the_hubs_slot_and_type() {
        let mut hub = FakeHub {
            leases: vec![(
                200,
                json!({"commands": [
                {"id": "c1", "slot": "cmux-lane-a", "slot_id": "registered:1", "type": "create",
                 "region": "own", "shape": {"vcpu": 2, "memGiB": 4, "diskGiB": 20},
                 "labels": {}, "desired": "running", "attempt": 1},
                {"id": "c2", "slot": "cmux-lane-b", "type": "pause", "desired": "paused", "attempt": 1},
                {"id": "c3", "slot": "lane-c", "type": "destroy", "desired": "destroyed", "attempt": 2}
            ], "lease_seconds": 60}),
            )],
            ..Default::default()
        };
        let mut source = HubSource::new(&mut hub, 8);
        let got = source.take().unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(
            got[0].command,
            Command::Create {
                slot: SlotName::parse("lane-a").unwrap(),
                spec: SlotSpec { vcpus: 2, memory_mib: 4096, disk_gib: 20 },
                lease: Default::default(),
            }
        );
        assert_eq!(
            got[1].command,
            Command::Pause { slot: SlotName::parse("lane-b").unwrap(), mode: Default::default() }
        );
        assert_eq!(got[2].command, Command::Destroy { slot: SlotName::parse("lane-c").unwrap() });

        source.ack(&got[0], &done(Some(SlotState::Running))).unwrap();
        source
            .ack(&got[2], &Outcome { ok: false, state: None, error: Some("x".repeat(3000)) })
            .unwrap();
        // An id acked once is not acked again.
        assert!(source.ack(&got[0], &done(None)).is_err());
        drop(source);

        assert_eq!(hub.sent[0], (LEASE_PATH.to_owned(), json!({"max": 8})));
        assert_eq!(
            hub.sent[1],
            (
                ACK_PATH.to_owned(),
                json!({"slot": "cmux-lane-a", "id": "c1", "type": "create", "outcome": "done"})
            )
        );
        let failed = &hub.sent[2].1;
        assert_eq!(failed["slot"], "lane-c");
        assert_eq!(failed["outcome"], "failed");
        assert_eq!(failed["detail"].as_str().unwrap().chars().count(), DETAIL_MAX);
    }

    #[test]
    fn a_command_this_host_cannot_do_is_failed_back_at_once_with_the_reason() {
        let mut hub = FakeHub {
            leases: vec![(
                200,
                json!({"commands": [
                    {"id": "u1", "slot": "cmux-ok", "type": "snapshot"},
                    {"id": "u2", "slot": "cmux-Bad_Name", "type": "create"}
                ]}),
            )],
            ..Default::default()
        };
        let got = HubSource::new(&mut hub, 8).take().unwrap();
        assert!(got.is_empty());
        let acks: Vec<&Value> =
            hub.sent.iter().filter(|(p, _)| p == ACK_PATH).map(|(_, b)| b).collect();
        assert_eq!(acks.len(), 2);
        assert!(acks.iter().all(|b| b["outcome"] == "failed"));
        assert!(acks[0]["detail"].as_str().unwrap().contains("snapshot"), "{}", acks[0]);
        assert!(acks[1]["detail"].as_str().unwrap().contains("Bad_Name"), "{}", acks[1]);
    }

    #[test]
    fn a_refused_lease_names_the_fix() {
        let mut hub = FakeHub {
            leases: vec![(401, json!({"error": "machine.unauthorized"})), (404, Value::Null)],
            ..Default::default()
        };
        let mut source = HubSource::new(&mut hub, 99);
        let e = format!("{:#}", source.take().unwrap_err());
        assert!(e.contains("machine.unauthorized") && e.contains("acpmux machine join"), "{e}");
        let e = format!("{:#}", source.take().unwrap_err());
        assert!(e.contains("registered machines are off"), "{e}");
        drop(source);
        // The size asked for is the hub's cap at most.
        assert_eq!(hub.sent[0].1, json!({"max": MAX_LEASE}));
    }

    #[test]
    fn a_hub_lease_drives_the_host_agent_end_to_end() {
        use crate::hypervisor::serve::HostAgent;
        let mut hub = FakeHub {
            leases: vec![
                (
                    200,
                    json!({"commands": [{"id": "c1", "slot": "cmux-h1", "type": "create",
                                           "shape": {"vcpu": 1, "memGiB": 0.5}}]}),
                ),
                (200, json!({"commands": [{"id": "c2", "slot": "cmux-h1", "type": "destroy"}]})),
            ],
            ..Default::default()
        };
        let dir = tempfile::tempdir().unwrap();
        let mut agent =
            HostAgent::open(MemDriver::default(), HubSource::new(&mut hub, 8), dir.path().into())
                .unwrap();
        let tick = agent.tick(1_000).unwrap();
        assert_eq!(tick.applied.len(), 1);
        assert!(tick.applied[0].outcome.ok, "{:?}", tick.applied[0]);
        assert_eq!(tick.slots.len(), 1);
        let tick = agent.tick(2_000).unwrap();
        assert!(tick.applied[0].outcome.ok, "{:?}", tick.applied[0]);
        assert!(tick.slots.is_empty());
        drop(agent);
        let acks: Vec<(String, String)> = hub
            .sent
            .iter()
            .filter(|(p, _)| p == ACK_PATH)
            .map(|(_, b)| {
                (b["id"].as_str().unwrap().to_owned(), b["outcome"].as_str().unwrap().to_owned())
            })
            .collect();
        assert_eq!(acks, vec![("c1".into(), "done".into()), ("c2".into(), "done".into())]);
    }
}
