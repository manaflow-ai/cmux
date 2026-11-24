use super::*;

#[test]
fn short_ids_are_stable_and_six_chars() {
    let ids = assign_short_ids([1, 2, 35, 36]);
    assert_eq!(ids[&1], "000001");
    assert_eq!(ids[&35], "00000z");
    assert_eq!(ids[&36], "000010");
    assert!(ids.values().all(|id| id.len() == 6));
    assert_eq!(ids, assign_short_ids([1, 2, 35, 36]));
}

#[test]
fn an_id_below_the_space_has_its_short_id_without_the_set() {
    let set = [3, 9, SPACE + 3, SPACE + 4, 2 * SPACE + 9, 40, SPACE - 1];
    let assigned = assign_short_ids(set);
    for id in set {
        if let Some(own) = short_id_without_set(id) {
            assert_eq!(assigned[&id], own, "{id}");
        }
    }
    assert_eq!(short_id_without_set(SPACE), None);
}

#[test]
fn short_ids_probe_on_collision() {
    let ids = assign_short_ids([1, SPACE + 1]);
    assert_eq!(ids[&1], "000001");
    assert_eq!(ids[&(SPACE + 1)], "000002");
}

#[test]
fn short_ids_collision_probe_is_input_order_independent() {
    assert_eq!(assign_short_ids([1, SPACE + 1]), assign_short_ids([SPACE + 1, 1]));
}
