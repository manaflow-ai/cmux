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
    let json = serde_json::to_value(PlacementMessage::moved("alpha", full_placement(), Some(4)))
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
