//! The versioned wire messages that update a [`crate::PlacementTable`]: "placement set",
//! "placement moved" and "placement removed".
//!
//! Lockstep rule: an old reader and a new reader both take each other's messages. So
//! - every message carries `v` (the version its writer speaks); a reader takes any `v`;
//! - unknown fields are ignored (no `deny_unknown_fields`), and every field added after v1 is
//!   `#[serde(default)]`;
//! - an unknown `kind` reads as [`PlacementMessage::Unknown`], which the table ignores, instead
//!   of failing the whole stream.
//!
//! The tests below hold an old reader's shape and a newer writer's shape and check both ways.

use serde::{Deserialize, Serialize};

use crate::placement::{Applied, Placement};

/// The acpmux request that carries one [`PlacementMessage`] (its params) from cmux to the daemon
/// that hosts the front; the answer is a [`PlacementReply`].
pub const PLACEMENT_METHOD: &str = "_acpmux/tailnet/placement";

/// The version this build writes.
pub const PLACEMENT_MESSAGE_VERSION: u32 = 1;

fn version() -> u32 {
    PLACEMENT_MESSAGE_VERSION
}

/// One placement update, as JSON: `{"kind":"moved","v":1,"workspace":"alpha","placement":{...}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PlacementMessage {
    /// A workspace now runs at `placement` (first placement, or a full replace).
    Set {
        #[serde(default = "version")]
        v: u32,
        workspace: String,
        placement: Placement,
    },
    /// A workspace moved to `placement`. Open connections keep their old target; new ones go to
    /// the new one. With `from_generation`, the move applies only over that generation.
    Moved {
        #[serde(default = "version")]
        v: u32,
        workspace: String,
        placement: Placement,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from_generation: Option<u64>,
    },
    /// A workspace has no placement any more (stopped or deleted).
    Removed {
        #[serde(default = "version")]
        v: u32,
        workspace: String,
    },
    /// A kind this build does not know (a newer writer's). Ignored.
    #[serde(other)]
    Unknown,
}

impl PlacementMessage {
    pub fn set(workspace: impl Into<String>, placement: Placement) -> Self {
        Self::Set { v: PLACEMENT_MESSAGE_VERSION, workspace: workspace.into(), placement }
    }

    pub fn moved(
        workspace: impl Into<String>,
        placement: Placement,
        from_generation: Option<u64>,
    ) -> Self {
        Self::Moved {
            v: PLACEMENT_MESSAGE_VERSION,
            workspace: workspace.into(),
            placement,
            from_generation,
        }
    }

    pub fn removed(workspace: impl Into<String>) -> Self {
        Self::Removed { v: PLACEMENT_MESSAGE_VERSION, workspace: workspace.into() }
    }

    /// The workspace the message is about (none for [`PlacementMessage::Unknown`]).
    pub fn workspace(&self) -> Option<&str> {
        match self {
            Self::Set { workspace, .. }
            | Self::Moved { workspace, .. }
            | Self::Removed { workspace, .. } => Some(workspace),
            Self::Unknown => None,
        }
    }
}

/// What applying one [`PlacementMessage`] did, as the daemon answers it. Same lockstep rules:
/// `v`, unknown fields ignored, every later field defaulted, an unknown `result` read as
/// [`PlacementResult::Unknown`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlacementReply {
    #[serde(default = "version")]
    pub v: u32,
    pub result: PlacementResult,
    /// The workspace's generation after a set or move.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlacementResult {
    Placed,
    Removed,
    Ignored,
    #[serde(other)]
    Unknown,
}

impl From<&Applied> for PlacementReply {
    fn from(applied: &Applied) -> Self {
        let (result, generation) = match applied {
            Applied::Placed { generation } => (PlacementResult::Placed, Some(*generation)),
            Applied::Removed => (PlacementResult::Removed, None),
            Applied::Ignored => (PlacementResult::Ignored, None),
        };
        Self { v: PLACEMENT_MESSAGE_VERSION, result, generation }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::placement::Backend;
    use std::collections::BTreeMap;

    /// The oldest reader this crate promises to stay compatible with: the minimal v1 shape (an
    /// SSH target only, no previews, no generations).
    mod old {
        use serde::{Deserialize, Serialize};

        #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
        pub struct Placement {
            #[serde(default)]
            pub ssh: Option<String>,
        }

        #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(tag = "kind", rename_all = "snake_case")]
        pub enum Message {
            Set {
                workspace: String,
                placement: Placement,
            },
            Moved {
                workspace: String,
                placement: Placement,
            },
            Removed {
                workspace: String,
            },
            #[serde(other)]
            Unknown,
        }
    }

    fn full_placement() -> Placement {
        let mut previews = BTreeMap::new();
        previews.insert(3000, Backend::new("10.1.2.3:3000"));
        Placement { ssh: Some(Backend::new("10.1.2.3:22")), previews }
    }

    #[test]
    fn round_trip_every_kind() {
        for message in [
            PlacementMessage::set("alpha", full_placement()),
            PlacementMessage::moved("alpha", full_placement(), Some(4)),
            PlacementMessage::moved("alpha", Placement::default(), None),
            PlacementMessage::removed("alpha"),
        ] {
            let json = serde_json::to_string(&message).expect("serialize");
            let back: PlacementMessage = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(back, message, "{json}");
        }
    }

    #[test]
    fn wire_shape_is_stable() {
        let json =
            serde_json::to_value(PlacementMessage::moved("alpha", full_placement(), Some(4)))
                .expect("serialize");
        assert_eq!(
            json,
            serde_json::json!({
                "kind": "moved",
                "v": 1,
                "workspace": "alpha",
                "placement": {"ssh": "10.1.2.3:22", "previews": {"3000": "10.1.2.3:3000"}},
                "from_generation": 4,
            })
        );
    }

    #[test]
    fn old_reader_takes_new_messages() {
        let new = PlacementMessage::moved("alpha", full_placement(), Some(9));
        let json = serde_json::to_string(&new).expect("serialize");
        let old: old::Message = serde_json::from_str(&json).expect("old reads new");
        assert_eq!(
            old,
            old::Message::Moved {
                workspace: "alpha".into(),
                placement: old::Placement { ssh: Some("10.1.2.3:22".into()) },
            }
        );
        let removed = serde_json::to_string(&PlacementMessage::removed("alpha")).expect("ser");
        assert_eq!(
            serde_json::from_str::<old::Message>(&removed).expect("old reads removed"),
            old::Message::Removed { workspace: "alpha".into() }
        );
    }

    #[test]
    fn new_reader_takes_old_messages() {
        let old = old::Message::Set {
            workspace: "alpha".into(),
            placement: old::Placement { ssh: Some("h:22".into()) },
        };
        let json = serde_json::to_string(&old).expect("serialize");
        let new: PlacementMessage = serde_json::from_str(&json).expect("new reads old");
        assert_eq!(
            new,
            PlacementMessage::set(
                "alpha",
                Placement { ssh: Some(Backend::new("h:22")), previews: BTreeMap::new() }
            )
        );
        let moved = serde_json::to_string(&old::Message::Moved {
            workspace: "alpha".into(),
            placement: old::Placement { ssh: None },
        })
        .expect("serialize");
        assert_eq!(
            serde_json::from_str::<PlacementMessage>(&moved).expect("new reads old moved"),
            PlacementMessage::moved("alpha", Placement::default(), None)
        );
    }

    #[test]
    fn unknown_fields_and_kinds_are_tolerated() {
        let json = r#"{"kind":"moved","v":7,"workspace":"alpha","future":true,
            "placement":{"ssh":"h:22","future_field":[1,2],"previews":{}},"from_generation":2}"#;
        let message: PlacementMessage = serde_json::from_str(json).expect("tolerate unknown");
        assert_eq!(message.workspace(), Some("alpha"));
        let unknown: PlacementMessage =
            serde_json::from_str(r#"{"kind":"drained","v":2,"workspace":"alpha"}"#)
                .expect("unknown kind");
        assert_eq!(unknown, PlacementMessage::Unknown);
        let old_unknown: old::Message =
            serde_json::from_str(r#"{"kind":"drained","workspace":"alpha"}"#).expect("old");
        assert_eq!(old_unknown, old::Message::Unknown);
    }

    #[test]
    fn replies_read_both_ways() {
        let new = PlacementReply::from(&Applied::Placed { generation: 3 });
        let json = serde_json::to_value(&new).expect("serialize");
        assert_eq!(json, serde_json::json!({"v": 1, "result": "placed", "generation": 3}));
        // An old reader that knows only `result` reads the new reply.
        #[derive(Deserialize)]
        struct OldReply {
            result: String,
        }
        let old: OldReply = serde_json::from_value(json).expect("old reads new reply");
        assert_eq!(old.result, "placed");
        // A new reader reads an old reply (no `v`, no generation) and a newer one (unknown
        // result, unknown fields).
        let from_old: PlacementReply =
            serde_json::from_str(r#"{"result":"removed"}"#).expect("new reads old reply");
        assert_eq!(from_old, PlacementReply::from(&Applied::Removed));
        let from_newer: PlacementReply =
            serde_json::from_str(r#"{"v":4,"result":"queued","eta_ms":5}"#).expect("newer");
        assert_eq!(from_newer.result, PlacementResult::Unknown);
    }
}
