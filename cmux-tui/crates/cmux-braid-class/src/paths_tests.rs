use std::time::Duration;

use super::*;

fn path(id: u8, alive: bool, rtt_ms: Option<u64>, capacity: Option<u64>) -> PathView<u8> {
    PathView { id, alive, rtt: rtt_ms.map(Duration::from_millis), capacity }
}

fn ids(pick: Pick<u8>) -> Vec<u8> {
    pick.iter().collect()
}

#[test]
fn input_rides_the_two_shortest_live_paths() {
    // Wi-Fi 30 ms, cell 60 ms, satellite 600 ms, and a dead 5 ms path.
    let paths = [
        path(1, true, Some(600), Some(20_000_000)),
        path(2, false, Some(5), None),
        path(3, true, Some(60), Some(2_000_000)),
        path(4, true, Some(30), Some(10_000_000)),
    ];
    assert_eq!(ids(paths_for(Class::Input, &paths)), [4, 3]);
    assert_eq!(ids(paths_for(Class::State, &paths)), [4]);
    assert_eq!(ids(paths_for(Class::Ordered, &paths)), [4]);
    // Bulk: satellite carries the file, then Wi-Fi, then cell.
    assert_eq!(ids(paths_for(Class::Bulk, &paths)), [1, 4, 3]);
}

#[test]
fn one_live_path_carries_every_class_and_none_carries_nothing() {
    let paths = [path(7, true, None, None), path(8, false, Some(10), Some(1))];
    for class in Class::ALL {
        assert_eq!(ids(paths_for(class, &paths)), [7], "{class}");
    }
    let dead = [path(1, false, Some(1), Some(1))];
    assert!(paths_for(Class::Input, &dead).is_empty());
    assert!(paths_for::<u8>(Class::Bulk, &[]).is_empty());
}

#[test]
fn ties_and_unmeasured_paths_keep_the_callers_order() {
    let paths =
        [path(1, true, None, None), path(2, true, Some(40), None), path(3, true, Some(40), None)];
    assert_eq!(ids(paths_for(Class::Input, &paths)), [2, 3]);
    assert_eq!(ids(paths_for(Class::State, &paths)), [2]);
    assert_eq!(ids(paths_for(Class::Bulk, &paths)), [1, 2, 3]);
}
