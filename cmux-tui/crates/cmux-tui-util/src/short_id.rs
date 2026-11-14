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
mod tests;
