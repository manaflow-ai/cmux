use super::*;

fn tab(width: f64, group: Option<&str>) -> Entry {
    Entry { width, group_id: group.map(Into::into), ..Entry::default() }
}

fn chip(width: f64, group: &str, collapsed: bool) -> Entry {
    Entry { width, group_id: Some(group.into()), is_group_chip: true, is_collapsed: collapsed }
}

fn collapsed(width: f64, group: &str) -> Entry {
    Entry { width, group_id: Some(group.into()), is_group_chip: false, is_collapsed: true }
}

const H: f64 = 0.3 * 180.0;

#[test]
fn between_two_members_or_after_a_chip_is_inside_the_group() {
    let entries =
        [tab(180.0, None), chip(40.0, "g", false), tab(180.0, Some("g")), tab(180.0, Some("g"))];
    assert_eq!(
        resolve_tab(&entries, 0.0, 225.0, None, H),
        Resolution { index: 1, group_id: Some("g".into()) }
    );
    assert_eq!(
        resolve_tab(&entries, 0.0, 400.0, None, H),
        Resolution { index: 2, group_id: Some("g".into()) }
    );
    assert_eq!(
        resolve_tab(&entries, 0.0, 10.0, Some("g"), H),
        Resolution { index: 0, group_id: None }
    );
}

#[test]
fn after_the_last_member_membership_holds_until_the_hysteresis() {
    let entries = [chip(40.0, "g", false), tab(180.0, Some("g")), tab(180.0, None)];
    // The edge after the last member is at 220.
    assert_eq!(resolve_tab(&entries, 0.0, 240.0, Some("g"), H).group_id.as_deref(), Some("g"));
    assert_eq!(resolve_tab(&entries, 0.0, 240.0, None, H).group_id, None);
    assert_eq!(resolve_tab(&entries, 0.0, 200.0, None, H).group_id, None);
    assert_eq!(
        resolve_tab(&entries, 0.0, 160.0, None, H).group_id.as_deref(),
        Some("g"),
        "short of the group's edge by more than the hysteresis is inside"
    );
}

#[test]
fn a_collapsed_group_is_never_entered() {
    let entries =
        [chip(40.0, "g", false), collapsed(0.0, "g"), collapsed(0.0, "g"), tab(180.0, None)];
    let resolved = resolve_tab(&entries, 0.0, 41.0, None, H);
    assert_eq!(resolved, Resolution { index: 2, group_id: None });
    assert_eq!(resolve_tab(&entries, 0.0, 0.0, None, H).index, 0);
}

#[test]
fn a_group_moves_as_one_unit() {
    let entries = [
        tab(100.0, None),
        chip(40.0, "g", false),
        tab(100.0, Some("g")),
        tab(100.0, Some("g")),
        tab(100.0, Some("h")),
    ];
    assert_eq!(
        units(&entries),
        [
            Unit { width: 100.0, tab_count: 1 },
            Unit { width: 240.0, tab_count: 2 },
            Unit { width: 100.0, tab_count: 1 },
        ]
    );
    assert_eq!(resolve_group(&entries, 0.0, 0.0), (0, 0));
    assert_eq!(resolve_group(&entries, 0.0, 330.0), (2, 3));
    assert_eq!(resolve_group(&entries, 0.0, 1000.0), (3, 4));
    assert_eq!(resolve_group(&[], 5.0, 1000.0), (0, 0));
}
