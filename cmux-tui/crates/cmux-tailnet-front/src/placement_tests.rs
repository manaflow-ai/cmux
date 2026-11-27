use super::*;

fn ssh(addr: &str) -> Placement {
    Placement { ssh: Some(Backend::new(addr)), previews: BTreeMap::new() }
}

#[test]
fn set_get_and_generations_increase() {
    let table = PlacementTable::new();
    let g1 = table.set("alpha", ssh("10.0.0.1:22"));
    let g2 = table.set("beta", ssh("10.0.0.2:22"));
    assert!(g2 > g1);
    assert_eq!(table.ssh_target("alpha"), Some((Backend::new("10.0.0.1:22"), g1)));
    assert_eq!(table.workspaces(), vec!["alpha", "beta"]);
    assert_eq!(table.ssh_target("gamma"), None);
}

#[test]
fn move_swaps_but_held_arc_keeps_old_target() {
    let table = PlacementTable::new();
    table.set("alpha", ssh("a:22"));
    let held = table.get("alpha").map(|e| e.placement);
    let g = table.move_to("alpha", ssh("b:22"), None);
    assert!(g.is_some());
    assert_eq!(
        held.and_then(|p| p.ssh.clone()),
        Some(Backend::new("a:22")),
        "an accepted connection keeps the target it resolved"
    );
    assert_eq!(table.ssh_target("alpha").map(|t| t.0), Some(Backend::new("b:22")));
}

#[test]
fn stale_move_is_dropped() {
    let table = PlacementTable::new();
    let g1 = table.set("alpha", ssh("a:22"));
    let g2 = table.move_to("alpha", ssh("b:22"), Some(g1));
    assert!(g2.is_some());
    assert_eq!(table.move_to("alpha", ssh("c:22"), Some(g1)), None);
    assert_eq!(table.ssh_target("alpha").map(|t| t.0), Some(Backend::new("b:22")));
    assert_eq!(table.move_to("nobody", ssh("c:22"), Some(1)), None);
}

#[test]
fn preview_targets_and_remove() {
    let table = PlacementTable::new();
    let mut placement = ssh("a:22");
    placement.previews.insert(3000, Backend::new("a:3000"));
    table.set("alpha", placement);
    assert_eq!(table.preview_target("alpha", 3000).map(|t| t.0), Some(Backend::new("a:3000")));
    assert_eq!(table.preview_target("alpha", 8080), None);
    assert!(table.remove("alpha"));
    assert!(!table.remove("alpha"));
    assert_eq!(table.preview_target("alpha", 3000), None);
}

#[test]
fn apply_messages() {
    let table = PlacementTable::new();
    let set = PlacementMessage::set("alpha", ssh("a:22"));
    let Applied::Placed { generation } = table.apply(&set) else {
        panic!("set should place");
    };
    let stale = PlacementMessage::moved("alpha", ssh("x:22"), Some(generation + 7));
    assert_eq!(table.apply(&stale), Applied::Ignored);
    let moved = PlacementMessage::moved("alpha", ssh("b:22"), Some(generation));
    assert!(matches!(table.apply(&moved), Applied::Placed { .. }));
    assert_eq!(table.ssh_target("alpha").map(|t| t.0), Some(Backend::new("b:22")));
    assert_eq!(table.apply(&PlacementMessage::Unknown), Applied::Ignored);
    assert_eq!(table.apply(&PlacementMessage::removed("alpha")), Applied::Removed);
    assert_eq!(table.apply(&PlacementMessage::removed("alpha")), Applied::Ignored);
}
