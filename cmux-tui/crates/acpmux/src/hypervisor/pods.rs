//! The plain-pod driver: each slot is a pod on this host (`cmux_pool_pod::slots`), a
//! systemd slice whose init runs in `bwrap`, instead of a KVM guest. For a host that
//! cannot run VMs, or many small lanes on one VM. Pods have no RAM image to save, so
//! a disk pause stops the init and keeps the root: it reports `Stopped`, never `Saved`.

use super::{HypervisorDriver, PauseMode, Slot, SlotName, SlotSpec, SlotState};
use anyhow::{Result, anyhow};
use cmux_pool_pod::slots::{self, HostRunner, PodSlots};

pub struct PodsDriver<X> {
    pods: PodSlots<X>,
}

impl<X: HostRunner> PodsDriver<X> {
    pub fn new(pods: PodSlots<X>) -> Self {
        Self { pods }
    }
}

fn slot(name: &SlotName) -> Result<slots::Slot> {
    slots::Slot::parse(name.as_str()).map_err(|e| anyhow!(e))
}

fn state(s: slots::SlotState) -> SlotState {
    match s {
        slots::SlotState::Running => SlotState::Running,
        slots::SlotState::Paused => SlotState::Paused,
        slots::SlotState::Stopped => SlotState::Stopped,
    }
}

impl<X: HostRunner> HypervisorDriver for PodsDriver<X> {
    fn create(&self, name: &SlotName, spec: &SlotSpec) -> Result<SlotState> {
        // A pod's disk is the host's; `disk_gib` has nothing to size.
        let size = slots::SlotSize { vcpus: spec.vcpus, memory_mib: spec.memory_mib };
        // A hub-minted join token goes to the init's environment by name, never an argv: the
        // init redeems it (`acpmux machine join` on stdin) and the pod joins as its own machine.
        let join = spec.join.as_ref().map(|j| j.env());
        let env: &[(&str, &str)] = match &join {
            Some(pairs) => pairs,
            None => &[],
        };
        self.pods.create_with_env(&slot(name)?, size, env).map(state).map_err(|e| anyhow!(e))
    }

    fn pause(&self, name: &SlotName, mode: PauseMode) -> Result<SlotState> {
        let mode = match mode {
            PauseMode::Memory => slots::PauseMode::Memory,
            PauseMode::Disk => slots::PauseMode::Disk,
        };
        self.pods.pause(&slot(name)?, mode).map(state).map_err(|e| anyhow!(e))
    }

    fn resume(&self, name: &SlotName) -> Result<SlotState> {
        self.pods.resume(&slot(name)?).map(state).map_err(|e| anyhow!(e))
    }

    fn destroy(&self, name: &SlotName) -> Result<()> {
        self.pods.destroy(&slot(name)?).map_err(|e| anyhow!(e))
    }

    fn list(&self) -> Result<Vec<Slot>> {
        let found = self.pods.list().map_err(|e| anyhow!(e))?;
        Ok(found
            .into_iter()
            // A pod name the host agent cannot address is not one of its slots.
            .filter_map(|(s, st)| {
                SlotName::parse(s.as_str()).ok().map(|name| Slot { name, state: state(st) })
            })
            .collect())
    }
}

#[cfg(test)]
#[path = "pods_tests.rs"]
mod tests;
