use std::collections::{HashMap, HashSet};

const WIDTH: usize = 6;
const BASE: u64 = 36;
const SPACE: u64 = BASE.pow(WIDTH as u32);

/// Stable six-character per-session IDs derived from the numeric object
/// IDs. Collisions in the six-character space probe forward until a free
/// value is found.
pub fn assign_short_ids(ids: impl IntoIterator<Item = u64>) -> HashMap<u64, String> {
    let mut ids = ids.into_iter().collect::<Vec<_>>();
    ids.sort_unstable();
    ids.dedup();
    let mut out = HashMap::new();
    let mut used = HashSet::new();
    for id in ids {
        let mut n = id % SPACE;
        loop {
            let candidate = encode_base36(n);
            if used.insert(candidate.clone()) {
                out.insert(id, candidate);
                break;
            }
            n = (n + 1) % SPACE;
        }
    }
    out
}

/// The short ID [`assign_short_ids`] gives `id` in any set of IDs, when that does not depend on the
/// other IDs: an ID below the six-character space keeps its own value. IDs are sorted first and every
/// ID below the space takes its own slot, so none of them ever probes and no other ID can take its
/// slot before it. `None` for an ID at or above the space (it may probe: ask the whole set).
pub fn short_id_without_set(id: u64) -> Option<String> {
    (id < SPACE).then(|| encode_base36(id))
}

fn encode_base36(mut n: u64) -> String {
    let mut chars = [b'0'; WIDTH];
    for slot in chars.iter_mut().rev() {
        let digit = (n % BASE) as u8;
        *slot = if digit < 10 { b'0' + digit } else { b'a' + digit - 10 };
        n /= BASE;
    }
    String::from_utf8(chars.to_vec()).expect("base36 output is ascii")
}

#[cfg(test)]
mod tests {
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
}
