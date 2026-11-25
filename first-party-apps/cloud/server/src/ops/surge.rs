//! The latest Cloud surge as the Machines page shows it (its surge card):
//! how many of its machines are ready, how long the last one took, and
//! whether its queue drained. Computed here from the machine projection, so
//! the page only formats it.
//!
//! A surge (cmux-platform RFD 0025, `cloud.surge.create`) creates one machine
//! per slot with origin `{kind: "person", label: "Surge"}`. The latest burst
//! is the newest surge machine and every surge machine created within
//! [`BURST_GAP_MS`] of the one after it, so two surges a minute apart read
//! as two, and one surge's slots (created in one call) read as one.

use crate::api::models::Machine;
use cmux_cloud_wire::{CloudMachineOriginKind, CloudMachineStatus};
use serde::Serialize;

/// The most time between two machines of one burst, by `created_at`.
pub const BURST_GAP_MS: i64 = 60_000;

/// The origin label a surge slot's create carries (cmux-platform CloudDO
/// `surgePlacement`).
const SURGE_LABEL: &str = "Surge";

/// The latest surge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Surge {
    /// The burst's first `created_at` (ms): when the surge started.
    pub started_at: i64,
    /// Machines in the burst that are still listed.
    pub count: usize,
    /// Machines that came up: running, or pausing or paused after running.
    pub ready: usize,
    /// Machines still provisioning or starting: the surge's queue.
    pub starting: usize,
    /// Machines whose create failed.
    pub failed: usize,
    /// No machine is still provisioning or starting.
    pub drained: bool,
    /// From `started_at` to the last machine's `running_since` (ms), once
    /// the queue drained and every ready machine is running with a start
    /// time (a paused machine no longer has one). Else absent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_ready_ms: Option<i64>,
    /// The burst's machine ids, newest first, so the page can drop the card
    /// once a person deleted all of them.
    pub machines: Vec<String>,
}

/// Whether `machine` is a surge slot.
fn is_surge(machine: &Machine) -> bool {
    let Some(origin) = machine.record.origin.as_ref() else { return false };
    origin.label == SURGE_LABEL
        && matches!(origin.kind, None | Some(CloudMachineOriginKind::Person))
}

/// The latest surge among `machines`, or `None` when none is listed.
pub fn latest<'a>(machines: impl IntoIterator<Item = &'a Machine>) -> Option<Surge> {
    let mut surge: Vec<&Machine> = machines.into_iter().filter(|m| is_surge(m)).collect();
    // Newest first; ids break ties so the order never depends on the map.
    surge.sort_by(|a, b| b.record.created_at.cmp(&a.record.created_at).then(a.id().cmp(b.id())));
    let mut burst: Vec<&Machine> = Vec::new();
    for machine in surge {
        if let Some(last) = burst.last()
            && last.record.created_at - machine.record.created_at > BURST_GAP_MS
        {
            break;
        }
        burst.push(machine);
    }
    let started_at = burst.last()?.record.created_at;
    let (mut ready, mut starting, mut failed) = (0, 0, 0);
    let mut last_running: Option<i64> = Some(started_at);
    for machine in &burst {
        match machine.record.status {
            CloudMachineStatus::Running => {
                ready += 1;
                let since = machine.record.running_since.flatten();
                last_running = last_running.zip(since).map(|(a, b)| a.max(b));
            }
            CloudMachineStatus::Pausing | CloudMachineStatus::Paused => {
                ready += 1;
                last_running = None;
            }
            CloudMachineStatus::Provisioning | CloudMachineStatus::Starting => starting += 1,
            CloudMachineStatus::Failed => failed += 1,
            CloudMachineStatus::Deleting | CloudMachineStatus::Unknown(_) => {}
        }
    }
    let drained = starting == 0;
    let last_ready_ms =
        last_running.filter(|_| drained && ready > 0).map(|at| (at - started_at).max(0));
    Some(Surge {
        started_at,
        count: burst.len(),
        ready,
        starting,
        failed,
        drained,
        last_ready_ms,
        machines: burst.iter().map(|m| m.id().to_owned()).collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const T0: i64 = 1_790_000_000_000;

    fn machine(
        id: &str,
        created: i64,
        status: &str,
        running_since: Option<i64>,
        origin: Value,
    ) -> Machine {
        let mut record = json!({
            "id": id, "team": "team_t0000000000000000001", "creator": "user_u0000000000000000001",
            "name": null, "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 },
            "status": status, "image": { "id": "img_i0000000000000000001", "daemon_version": null },
            "host": null, "classic": false, "created_at": created,
            "last_active_at": null, "idle_policy": { "idle_seconds": 1800 },
            "error": null, "running_since": running_since, "revision": "1",
        });
        if !origin.is_null() {
            record["origin"] = origin;
        }
        serde_json::from_value(record).expect("machine decodes")
    }

    fn slot(id: &str, created: i64, status: &str, running_since: Option<i64>) -> Machine {
        machine(id, created, status, running_since, json!({ "kind": "person", "label": "Surge" }))
    }

    #[test]
    fn no_surge_machine_means_no_card() {
        let plain = machine("vm-a", T0, "running", Some(T0 + 5_000), Value::Null);
        let workflow =
            machine("vm-b", T0, "running", None, json!({ "kind": "workflow", "label": "Surge" }));
        assert_eq!(latest([&plain, &workflow]), None);
    }

    #[test]
    fn a_surge_past_8_reports_ready_last_ready_and_drained() {
        // 25 slots created over 2 s, ready between 20 s and 33 s after the first.
        let slots: Vec<Machine> = (0..25)
            .map(|i| {
                slot(&format!("vm-{i:02}"), T0 + i * 80, "running", Some(T0 + 20_000 + i * 520))
            })
            .collect();
        let surge = latest(&slots).expect("a surge");
        assert_eq!(surge.count, 25);
        assert_eq!(surge.ready, 25);
        assert_eq!((surge.starting, surge.failed), (0, 0));
        assert!(surge.drained);
        assert_eq!(surge.started_at, T0);
        assert_eq!(surge.last_ready_ms, Some(20_000 + 24 * 520));
        assert_eq!(surge.machines.first().map(String::as_str), Some("vm-24"));
    }

    #[test]
    fn a_queue_still_starting_is_not_drained_and_has_no_last_ready() {
        let slots = [
            slot("vm-1", T0, "running", Some(T0 + 30_000)),
            slot("vm-2", T0 + 10, "provisioning", None),
            slot("vm-3", T0 + 20, "starting", None),
            slot("vm-4", T0 + 30, "failed", None),
        ];
        let surge = latest(&slots).expect("a surge");
        assert_eq!((surge.count, surge.ready, surge.starting, surge.failed), (4, 1, 2, 1));
        assert!(!surge.drained);
        assert_eq!(surge.last_ready_ms, None);
    }

    #[test]
    fn a_paused_slot_is_ready_but_hides_the_last_ready_time() {
        let slots =
            [slot("vm-1", T0, "running", Some(T0 + 9_000)), slot("vm-2", T0 + 5, "paused", None)];
        let surge = latest(&slots).expect("a surge");
        assert_eq!(surge.ready, 2);
        assert!(surge.drained);
        assert_eq!(surge.last_ready_ms, None);
    }

    #[test]
    fn only_the_latest_burst_counts() {
        let older = slot("vm-old", T0, "running", Some(T0 + 10_000));
        let newer: Vec<Machine> = (0..3)
            .map(|i| {
                slot(
                    &format!("vm-new-{i}"),
                    T0 + 600_000 + i * 1_000,
                    "running",
                    Some(T0 + 640_000),
                )
            })
            .collect();
        let mut all: Vec<&Machine> = newer.iter().collect();
        all.push(&older);
        let surge = latest(all).expect("a surge");
        assert_eq!(surge.count, 3);
        assert_eq!(surge.started_at, T0 + 600_000);
        assert_eq!(surge.last_ready_ms, Some(40_000));
        assert!(!surge.machines.contains(&"vm-old".to_owned()));
    }
}
