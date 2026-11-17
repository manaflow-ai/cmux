//! An in-memory provider for tests, the bench and the CLI's `--fake` mode,
//! with the faults the ledger must survive.

use crate::contract::{
    CostEstimate, CreateSpec, IdempotencyKey, MachineProvider, MachineState, Op, ProviderError,
    Request,
};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
pub struct FakeProvider {
    machines: RefCell<BTreeMap<String, MachineState>>,
    snapshots: RefCell<BTreeSet<String>>,
    /// Apply the next call, then answer as if the reply was lost.
    pub lose_next_answer: Cell<bool>,
    /// Refuse the next call without applying it.
    pub refuse_next: Cell<bool>,
    /// Provider calls that changed something (`apply` only).
    pub applied: Cell<u64>,
}

impl FakeProvider {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state(&self, machine: &str) -> Option<MachineState> {
        self.machines.borrow().get(machine).copied()
    }

    pub fn snapshots(&self) -> Vec<String> {
        self.snapshots.borrow().iter().cloned().collect()
    }
}

impl MachineProvider for FakeProvider {
    fn provider(&self) -> &str {
        "fake"
    }

    fn project(&self) -> &str {
        "fake-project"
    }

    fn machine_for(&self, key: &IdempotencyKey) -> String {
        format!("cmux-{}", &key.digest("machine")[..16])
    }

    fn apply(
        &self,
        key: &IdempotencyKey,
        request: &Request,
    ) -> Result<(MachineState, Option<String>), ProviderError> {
        if self.refuse_next.replace(false) {
            return Err(ProviderError::Refused("permission denied (fault)".into()));
        }
        let machine = match request.op {
            Op::Create => self.machine_for(key),
            _ => request.machine.clone().unwrap_or_default(),
        };
        let mut machines = self.machines.borrow_mut();
        let current = machines.get(&machine).copied();
        let (state, artifact) = match (request.op, current) {
            (Op::Create, None) => (MachineState::Running, None),
            (Op::Create, Some(state)) => (state, None),
            (Op::Delete, _) => (MachineState::Deleted, None),
            (_, None) => return Err(ProviderError::NotFound(machine)),
            (Op::Start, Some(_)) => (MachineState::Running, None),
            (Op::Stop, Some(_)) => (MachineState::Stopped, None),
            (Op::Snapshot, Some(state)) => {
                let name = format!("{machine}-{}", &key.digest("snapshot")[..12]);
                self.snapshots.borrow_mut().insert(name.clone());
                (state, Some(name))
            }
        };
        if state == MachineState::Deleted {
            machines.remove(&machine);
        } else {
            machines.insert(machine, state);
        }
        self.applied.set(self.applied.get() + 1);
        if self.lose_next_answer.replace(false) {
            return Err(ProviderError::Indeterminate("reply lost (fault)".into()));
        }
        Ok((state, artifact))
    }

    fn observe(&self, machine: &str) -> Result<Option<MachineState>, ProviderError> {
        Ok(self.state(machine))
    }

    fn cost_estimate(&self, spec: &CreateSpec) -> CostEstimate {
        CostEstimate {
            machine_type: spec.machine_type.clone(),
            zone: spec.zone.clone(),
            running_per_hour: 0.0,
            stopped_disk_per_month: 0.0,
            egress_per_gb: 0.0,
            currency: "USD".into(),
            source: "fake provider".into(),
        }
    }
}
