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
