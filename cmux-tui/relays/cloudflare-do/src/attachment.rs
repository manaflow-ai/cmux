use cmux_remote_protocol::{CircuitId, RelaySocketAttachment};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum SlotPhase {
    Pending,
    Registered,
    ClientControl,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct SlotAttachment {
    pub relay: RelaySocketAttachment,
    pub phase: SlotPhase,
    pub generation: u64,
    pub expires_at: u64,
    pub idle_deadline_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum CircuitPhase {
    Pending,
    Joined,
    Ready,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct CircuitAttachment {
    pub circuit: CircuitId,
    pub relay: Option<RelaySocketAttachment>,
    pub phase: CircuitPhase,
    pub generation: u64,
    pub expires_at: u64,
    pub idle_deadline_ms: u64,
}

impl CircuitAttachment {
    pub fn pending(circuit: CircuitId, idle_deadline_ms: u64) -> Self {
        Self {
            circuit,
            relay: None,
            phase: CircuitPhase::Pending,
            generation: 0,
            expires_at: 0,
            idle_deadline_ms,
        }
    }
}

#[cfg(test)]
mod tests {
    use cmux_remote_protocol::{LaneToken, RelayRole};

    use super::*;

    #[test]
    fn circuit_attachment_round_trips_for_hibernation() {
        let attachment = CircuitAttachment {
            circuit: CircuitId("circuit".into()),
            relay: Some(RelaySocketAttachment::circuit(
                RelayRole::Client,
                "slot".into(),
                CircuitId("circuit".into()),
                LaneToken("opaque-lane".into()),
            )),
            phase: CircuitPhase::Ready,
            generation: 7,
            expires_at: 1_000,
            idle_deadline_ms: 2_000,
        };

        let encoded = serde_json::to_vec(&attachment).unwrap();
        let decoded: CircuitAttachment = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded, attachment);
        assert!(encoded.len() < 16_384);
    }

    #[test]
    fn reusable_client_control_round_trips_without_one_lane_binding() {
        let attachment = SlotAttachment {
            relay: RelaySocketAttachment {
                role: RelayRole::Client,
                slot: "slot".into(),
                circuit: None,
                lane: None,
            },
            phase: SlotPhase::ClientControl,
            generation: 9,
            expires_at: 1_000,
            idle_deadline_ms: 2_000,
        };

        let encoded = serde_json::to_vec(&attachment).unwrap();
        let decoded: SlotAttachment = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded, attachment);
        assert!(decoded.relay.circuit.is_none());
        assert!(decoded.relay.lane.is_none());
    }
}
