use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode};

fn viewport() -> RegistryViewport {
    let pane = |n: u128| PanePublicId::parse(format!("pane_{n:032x}")).unwrap();
    let split = |n: u128| SplitPublicId::parse(format!("split_{n:032x}")).unwrap();
    let docked = ColumnDock::new(DockEdge::Left, DockMode::Docked);
    RegistryViewport {
        base_width: None,
        columns: vec![
            RegistryViewportColumn::new(
                split(1),
                0.3,
                RegistryLayoutNode::Leaf { pane: pane(1) },
                None,
                Some(docked),
            ),
            RegistryViewportColumn::new(
                split(2),
                0.7,
                RegistryLayoutNode::Leaf { pane: pane(2) },
                None,
                None,
            ),
        ],
    }
}

/// R87 DOCK-WIRE: since the release pin serves dock-columns-v1
/// (b7d4c52e4c67) the stored key is `dock`. Records written before that
/// name it `sticky`; both keys load for one release.
#[test]
fn a_registry_viewport_writes_dock_and_reads_dock_or_sticky() {
    let viewport = viewport();
    let written = serde_json::to_string(&viewport).unwrap();
    assert!(written.contains("\"dock\":") && !written.contains("\"sticky\""), "{written}");
    let loaded: RegistryViewport = serde_json::from_str(&written).unwrap();
    assert_eq!(loaded, viewport);
    let sticky_named = written.replace("\"dock\":", "\"sticky\":");
    let loaded: RegistryViewport = serde_json::from_str(&sticky_named).unwrap();
    assert_eq!(loaded, viewport);
}

/// `dock-column-role-v1`: the role is stored in the dock record, so the
/// agent chat column comes back after a restart. A record without it (an
/// older build's) has none, and a role this build does not know reads as
/// none instead of making the screen unreadable.
#[test]
fn a_registry_viewport_keeps_the_dock_role() {
    let mut record = serde_json::to_value(viewport()).unwrap();
    let dock = &record["columns"][0]["dock"];
    assert!(dock.get("role").is_none(), "no role while unset: {record}");
    record["columns"][0]["dock"]["role"] = serde_json::json!("agent_chat");
    let loaded: RegistryViewport = serde_json::from_value(record.clone()).unwrap();
    let written = serde_json::to_value(&loaded).unwrap();
    assert_eq!(written["columns"][0]["dock"]["role"], "agent_chat", "{written}");

    record["columns"][0]["dock"]["role"] = serde_json::json!("notes");
    let loaded: RegistryViewport = serde_json::from_value(record).unwrap();
    let written = serde_json::to_value(&loaded).unwrap();
    let plain = serde_json::json!({"edge": "left", "mode": "docked"});
    assert_eq!(written["columns"][0]["dock"], plain);
}
