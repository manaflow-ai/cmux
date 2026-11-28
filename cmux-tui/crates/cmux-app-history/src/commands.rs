//! Terminal command history's sync (`CommandHistory.swift`): what each
//! connected daemon is sent so its switch and retention match the settings,
//! and when to offer deleting what was recorded.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// What a daemon was last sent: its boot generation, the switch and the retention.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sent {
    pub generation: String,
    pub enabled: bool,
    pub retention_days: i64,
}

/// The settings, the connected machines that serve the capability (by boot generation), and the app's memory.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sync {
    pub enabled: bool,
    pub retention_days: i64,
    #[serde(default)]
    pub machines: BTreeMap<String, String>,
    #[serde(default)]
    pub sent: BTreeMap<String, Sent>,
    #[serde(default)]
    pub last_enabled: Option<bool>,
    /// Machines with a daemon to send to.
    #[serde(default)]
    pub daemons: BTreeSet<String>,
}

/// The plan: ask to delete what was recorded, the machines to send `set-terminal-command-history`, and the new memory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub offer_deletion: bool,
    pub send: Vec<String>,
    pub sent: BTreeMap<String, Sent>,
    pub last_enabled: bool,
}

/// One sync: turning recording off offers deletion; each machine not told this
/// generation, switch and retention is told (off too: the retention reaches it);
/// machines that left are forgotten.
pub fn sync(state: &Sync) -> Plan {
    let mut sent = state.sent.clone();
    let mut send = Vec::new();
    for (machine, generation) in &state.machines {
        let next = Sent {
            generation: generation.clone(),
            enabled: state.enabled,
            retention_days: state.retention_days,
        };
        if sent.get(machine) == Some(&next) || !state.daemons.contains(machine) {
            continue;
        }
        sent.insert(machine.clone(), next);
        send.push(machine.clone());
    }
    sent.retain(|machine, _| state.machines.contains_key(machine));
    Plan {
        offer_deletion: state.last_enabled == Some(true) && !state.enabled,
        send,
        sent,
        last_enabled: state.enabled,
    }
}

/// After a failed send: forget it (sent again on the next sync) unless a newer one replaced it.
pub fn failed(sent: &mut BTreeMap<String, Sent>, machine: &str, attempted: &Sent) {
    if sent.get(machine) == Some(attempted) {
        sent.remove(machine);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sent(generation: &str, enabled: bool, days: i64) -> Sent {
        Sent { generation: generation.into(), enabled, retention_days: days }
    }

    fn state(enabled: bool, machines: &[(&str, &str)]) -> Sync {
        Sync {
            enabled,
            retention_days: 30,
            machines: machines.iter().map(|(m, g)| (m.to_string(), g.to_string())).collect(),
            daemons: machines.iter().map(|(m, _)| m.to_string()).collect(),
            ..Sync::default()
        }
    }

    #[test]
    fn each_new_machine_is_told_off_too() {
        let plan = sync(&state(false, &[("local", "g1"), ("box", "g2")]));
        assert_eq!(plan.send, vec!["box", "local"]);
        assert_eq!(plan.sent["local"], sent("g1", false, 30));
        assert!(!plan.offer_deletion);
        assert!(!plan.last_enabled);
    }

    #[test]
    fn an_unchanged_machine_is_not_told_again_and_a_restart_is() {
        let mut s = state(true, &[("local", "g1"), ("box", "g3")]);
        s.sent = [
            ("local".to_string(), sent("g1", true, 30)),
            ("box".to_string(), sent("g2", true, 30)),
        ]
        .into();
        assert_eq!(sync(&s).send, vec!["box"]);
        s.retention_days = 7;
        assert_eq!(sync(&s).send, vec!["box", "local"]);
    }

    #[test]
    fn machines_that_left_are_forgotten_and_one_without_a_daemon_waits() {
        let mut s = state(true, &[("local", "g1"), ("box", "g2")]);
        s.daemons.remove("box");
        s.sent = [("gone".to_string(), sent("g9", true, 30))].into();
        let plan = sync(&s);
        assert_eq!(plan.send, vec!["local"]);
        assert_eq!(plan.sent.keys().cloned().collect::<Vec<_>>(), vec!["local"]);
    }

    #[test]
    fn turning_recording_off_offers_deletion_once() {
        let mut s = state(false, &[]);
        s.last_enabled = Some(true);
        assert!(sync(&s).offer_deletion);
        s.last_enabled = Some(false);
        assert!(!sync(&s).offer_deletion);
        s.last_enabled = None;
        assert!(!sync(&s).offer_deletion);
        let mut on = state(true, &[]);
        on.last_enabled = Some(true);
        assert!(!sync(&on).offer_deletion);
    }

    #[test]
    fn a_failed_send_is_forgotten_unless_replaced() {
        let attempted = sent("g1", true, 30);
        let mut memory: BTreeMap<String, Sent> = [("m".to_string(), attempted.clone())].into();
        failed(&mut memory, "m", &sent("g1", false, 30));
        assert!(memory.contains_key("m"));
        failed(&mut memory, "m", &attempted);
        assert!(memory.is_empty());
    }
}
