//! Opt-in, local-only provider contract rehearsal. Never constructs a control-plane client.
//! A fresh fake per invocation bounds memory and makes retries reproducible without resources.
use crate::api::{CloudError, codes};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Create,
    Connect,
    Stop,
    Start,
    Snapshot,
    Delete,
    CostEstimate,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Absent,
    Running,
    Connected,
    Stopped,
    Deleted,
    Orphaned,
}

/// Only public resource identity and lifecycle facts belong in a receipt; never credentials.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Receipt {
    pub provider: String,
    pub project: String,
    pub machine: String,
    pub generation: u64,
    pub operation: Operation,
    pub state: State,
    pub replayed: bool,
    pub outcome: &'static str,
}

/// First contract slice. Real adapters must preserve key reconciliation and receipt binding.
pub trait MachineProvider {
    fn execute(
        &mut self,
        operation: Operation,
        idempotency_key: &str,
    ) -> Result<Receipt, &'static str>;
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Scenario {
    Lifecycle,
    EnrollmentFailure,
    CleanupFailure,
}

pub struct FakeProvider {
    scenario: Scenario,
    state: State,
    generation: u64,
    ledger: BTreeMap<String, Receipt>,
}

impl FakeProvider {
    pub fn new(scenario: Scenario) -> Self {
        Self { scenario, state: State::Absent, generation: 0, ledger: BTreeMap::new() }
    }
}

impl MachineProvider for FakeProvider {
    fn execute(&mut self, operation: Operation, key: &str) -> Result<Receipt, &'static str> {
        if key.is_empty() || key.len() > 128 {
            return Err("invalid_key");
        }
        if let Some(receipt) = self.ledger.get(key) {
            if receipt.operation != operation {
                return Err("idempotency_conflict");
            }
            return Ok(Receipt { replayed: true, ..receipt.clone() });
        }
        let mut outcome = "simulated";
        self.state = match (operation, self.state) {
            (Operation::Create, State::Absent) => {
                self.generation += 1;
                State::Running
            }
            // A real adapter must verify daemon hello; a VM running alone is never connected.
            (Operation::Connect, State::Running) => {
                if self.scenario == Scenario::Lifecycle {
                    State::Connected
                } else {
                    outcome = "enrollment_failed";
                    State::Running
                }
            }
            (Operation::Stop, State::Running | State::Connected) => State::Stopped,
            (Operation::Start, State::Stopped) => {
                self.generation += 1;
                State::Running
            }
            (Operation::Snapshot, State::Stopped | State::Running | State::Connected) => self.state,
            (
                Operation::Delete,
                State::Running | State::Connected | State::Stopped | State::Orphaned,
            ) => {
                if self.scenario == Scenario::CleanupFailure {
                    outcome = "cleanup_failed_orphan";
                    State::Orphaned
                } else {
                    State::Deleted
                }
            }
            (Operation::CostEstimate, _) => {
                outcome = "cost_unavailable";
                self.state
            }
            _ => return Err("invalid_transition"),
        };
        let receipt = Receipt {
            provider: "fake".into(),
            project: "rehearsal-project".into(),
            machine: "rehearsal-machine".into(),
            generation: self.generation,
            operation,
            state: self.state,
            replayed: false,
            outcome,
        };
        self.ledger.insert(key.to_owned(), receipt.clone());
        Ok(receipt)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    enabled: bool,
    scenario: Scenario,
}

#[derive(Debug, Serialize)]
pub struct Rehearsal {
    pub simulated: bool,
    pub scenario: Scenario,
    /// The design's proposed grace, not a changed production setting or a running timer.
    pub proposed_idle_stop_minutes: u32,
    pub receipts: Vec<Receipt>,
}

pub fn run(args: &Value) -> Result<Value, CloudError> {
    let input: Input = serde_json::from_value(args.clone()).map_err(|_| {
        CloudError::new(codes::INVALID_ARGS, "Expected enabled and a rehearsal scenario")
    })?;
    if !input.enabled {
        return Err(CloudError::new(codes::INVALID_ARGS, "Provider rehearsal is disabled"));
    }
    let mut provider = FakeProvider::new(input.scenario);
    let mut receipts = Vec::new();
    let sequence = if input.scenario == Scenario::Lifecycle {
        vec![
            (Operation::Create, "create"),
            (Operation::Create, "create"),
            (Operation::Connect, "hello"),
            (Operation::Stop, "stop"),
            (Operation::Start, "start"),
            (Operation::Connect, "hello-after-start"),
            (Operation::Snapshot, "snapshot"),
            (Operation::CostEstimate, "cost"),
            (Operation::Delete, "delete"),
            (Operation::Delete, "delete"),
        ]
    } else {
        vec![
            (Operation::Create, "create"),
            (Operation::Connect, "hello"),
            (Operation::Delete, "cleanup"),
            (Operation::Delete, "cleanup"),
        ]
    };
    for (operation, key) in sequence {
        receipts.push(
            provider
                .execute(operation, key)
                .map_err(|message| CloudError::new(codes::INVALID_ARGS, message))?,
        );
    }
    serde_json::to_value(Rehearsal {
        simulated: true,
        scenario: input.scenario,
        proposed_idle_stop_minutes: 30,
        receipts,
    })
    .map_err(|_| CloudError::new(codes::INVALID_ARGS, "Could not encode rehearsal"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn explicit_opt_in_and_closed_input() {
        for args in [
            json!({}),
            json!({"enabled":false,"scenario":"lifecycle"}),
            json!({"enabled":true,"scenario":"unknown"}),
            json!({"enabled":true,"scenario":"lifecycle","credentials":"never"}),
        ] {
            assert!(run(&args).is_err());
        }
    }

    #[test]
    fn lifecycle_and_retries_are_bound_to_generation() {
        let result = run(&json!({"enabled":true,"scenario":"lifecycle"})).unwrap();
        let receipts = result["receipts"].as_array().unwrap();
        assert_eq!(receipts.len(), 10);
        assert_eq!(receipts[0]["state"], "running");
        assert_eq!(receipts[1]["replayed"], true);
        assert_eq!(receipts[1]["generation"], 1);
        assert_eq!(receipts[4]["state"], "running");
        assert_eq!(receipts[4]["generation"], 2);
        assert_eq!(receipts[5]["state"], "connected");
        assert_eq!(receipts[9]["state"], "deleted");
        assert_eq!(receipts[9]["replayed"], true);
        assert!(receipts.iter().all(|r| r["provider"] == "fake"
            && r["project"] == "rehearsal-project"
            && r["machine"] == "rehearsal-machine"));
        assert_eq!(result, run(&json!({"enabled":true,"scenario":"lifecycle"})).unwrap());
    }

    #[test]
    fn enrollment_failure_never_claims_connected_and_reports_cleanup() {
        for (scenario, state) in
            [("enrollment_failure", "deleted"), ("cleanup_failure", "orphaned")]
        {
            let result = run(&json!({"enabled":true,"scenario":scenario})).unwrap();
            let receipts = result["receipts"].as_array().unwrap();
            assert!(receipts.iter().all(|r| r["state"] != "connected"));
            assert_eq!(receipts[1]["outcome"], "enrollment_failed");
            assert_eq!(receipts[3]["state"], state);
            assert_eq!(receipts[3]["replayed"], true);
        }
    }

    #[test]
    fn conflicts_and_invalid_transitions_do_not_mutate() {
        let mut p = FakeProvider::new(Scenario::Lifecycle);
        assert_eq!(p.execute(Operation::Connect, "hello").unwrap_err(), "invalid_transition");
        p.execute(Operation::Create, "create").unwrap();
        assert_eq!(p.execute(Operation::Delete, "create").unwrap_err(), "idempotency_conflict");
        assert_eq!(p.state, State::Running);
        p.execute(Operation::Stop, "stop").unwrap();
        let replay = p.execute(Operation::Create, "create").unwrap();
        assert_eq!(replay.state, State::Running);
        assert_eq!(p.state, State::Stopped);
    }
}
