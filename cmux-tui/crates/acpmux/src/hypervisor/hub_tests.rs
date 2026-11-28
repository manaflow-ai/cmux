use super::*;
use crate::hypervisor::SlotState;

#[derive(Default)]
struct FakeHub {
    leases: Vec<(u16, Value)>,
    /// The mint's answers in order; then a fresh `cmj_for-<slot>` token.
    mints: Vec<(u16, Value)>,
    sent: Vec<(String, Value)>,
    ack_status: u16,
}

const ORIGIN: &str = "https://hub.test";

fn minted(slot: &str) -> String {
    format!("cmj_for-{slot}")
}

impl HubPost for &mut FakeHub {
    fn origin(&self) -> &str {
        ORIGIN
    }

    fn post(&mut self, path: &str, body: &Value) -> Result<(u16, Value)> {
        self.sent.push((path.to_owned(), body.clone()));
        if path == CHILDREN_PATH {
            if !self.mints.is_empty() {
                return Ok(self.mints.remove(0));
            }
            let slot = body["slot"].as_str().unwrap();
            return Ok((
                200,
                json!({"joinTokenId": "jt1", "token": minted(slot), "teamId": "t",
                       "parentMachineId": "m", "slot": slot, "label": slot}),
            ));
        }
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

/// Slots in memory, each verb idempotent by name as the real drivers are, and each
/// create's join (hub, token) as the driver got it.
#[derive(Default)]
struct MemDriver(
    std::cell::RefCell<std::collections::BTreeMap<SlotName, SlotState>>,
    std::cell::RefCell<Vec<Option<(String, String)>>>,
);

impl crate::hypervisor::HypervisorDriver for MemDriver {
    fn create(&self, slot: &SlotName, spec: &SlotSpec) -> Result<SlotState> {
        let join = spec.join.as_ref().map(|j| (j.hub.clone(), j.token().to_owned()));
        self.1.borrow_mut().push(join);
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
            spec: SlotSpec {
                vcpus: 2,
                memory_mib: 4096,
                disk_gib: 20,
                join: Some(ChildJoin::new(ORIGIN, zeroize::Zeroizing::new(minted("cmux-lane-a")))),
            },
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
    // Only the create minted, for the hub's own slot text.
    assert_eq!(
        hub.sent[1],
        (
            CHILDREN_PATH.to_owned(),
            json!({"slot": "cmux-lane-a", "label": "cmux-lane-a", "ttlSeconds": 600})
        )
    );
    assert_eq!(
        hub.sent[2],
        (
            ACK_PATH.to_owned(),
            json!({"slot": "cmux-lane-a", "id": "c1", "type": "create", "outcome": "done"})
        )
    );
    assert_eq!(hub.sent.iter().filter(|(p, _)| p == CHILDREN_PATH).count(), 1);
    let failed = &hub.sent[3].1;
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
    // A create refused before the mint mints nothing.
    assert!(hub.sent.iter().all(|(p, _)| p != CHILDREN_PATH));
}

#[test]
fn a_minted_join_token_never_shows_in_a_debug_line_or_a_command_file() {
    let mut hub = FakeHub {
        leases: vec![(
            200,
            json!({"commands": [{"id": "c1", "slot": "cmux-s1", "type": "create"}]}),
        )],
        ..Default::default()
    };
    let got = HubSource::new(&mut hub, 8).take().unwrap();
    let secret = minted("cmux-s1");
    let Command::Create { spec, .. } = &got[0].command else { panic!("{:?}", got[0]) };
    assert_eq!(spec.join.as_ref().unwrap().token(), secret);
    assert!(!format!("{:?}", got[0]).contains(&secret));
    assert!(!serde_json::to_string(&got[0]).unwrap().contains(&secret));
    // Nor can a spooled command carry one in: the field is never read.
    let spooled: Command = serde_json::from_value(json!({"verb": "create", "slot": "s1",
        "spec": {"vcpus": 1, "join": {"hub": ORIGIN, "token": "cmj_x"}}}))
    .unwrap();
    let Command::Create { spec, .. } = spooled else { panic!() };
    assert!(spec.join.is_none());
}

#[test]
fn a_refused_mint_fails_the_create_back_to_the_hub_with_the_reason() {
    let mut hub = FakeHub {
        leases: vec![(
            200,
            json!({"commands": [
                {"id": "m1", "slot": "cmux-a", "type": "create"},
                {"id": "m2", "slot": "cmux-b", "type": "create"},
                {"id": "m3", "slot": "cmux-c", "type": "create"},
                {"id": "m4", "slot": "cmux-d", "type": "create"},
                {"id": "m5", "slot": "cmux-e", "type": "create"},
                {"id": "p1", "slot": "cmux-f", "type": "pause"}
            ]}),
        )],
        mints: vec![
            (403, json!({"error": "machine.slot_not_held"})),
            (401, json!({"error": {"code": "machine.revoked"}})),
            (404, Value::Null),
            (200, json!({"token": "not-a-join-token-sekrit"})),
            (200, json!({"joinTokenId": "jt"})),
        ],
        ..Default::default()
    };
    let got = HubSource::new(&mut hub, 8).take().unwrap();
    // Only the pause is handed to the driver; it minted nothing.
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].id, "p1");
    assert_eq!(hub.sent.iter().filter(|(p, _)| p == CHILDREN_PATH).count(), 5);
    let acks: Vec<&Value> =
        hub.sent.iter().filter(|(p, _)| p == ACK_PATH).map(|(_, b)| b).collect();
    assert_eq!(acks.len(), 5);
    assert!(acks.iter().all(|b| b["outcome"] == "failed" && b["type"] == "create"));
    let detail = |i: usize| acks[i]["detail"].as_str().unwrap().to_owned();
    assert!(detail(0).contains("machine.slot_not_held"), "{}", detail(0));
    assert!(detail(1).contains("machine.revoked") && detail(1).contains("machine join"));
    assert!(detail(2).contains("registered machines are off"), "{}", detail(2));
    assert!(detail(3).contains("malformed") && !detail(3).contains("sekrit"), "{}", detail(3));
    assert!(detail(4).contains("no token"), "{}", detail(4));
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
    // The driver got the slot's own minted token and the hub that redeems it.
    assert_eq!(*agent.driver.1.borrow(), vec![Some((ORIGIN.to_owned(), minted("cmux-h1")))]);
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
