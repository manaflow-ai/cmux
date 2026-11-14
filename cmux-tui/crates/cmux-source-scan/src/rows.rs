//! How a row of a check's tests (or a ratchet's list) is held to what the check found: each
//! finding the row names takes one finding of the check, and none is left over. That is the
//! exact multiset, so a second copy of a named finding fails a row as a missing one does
//! (cmux#42341 review F1: two matching statics on one line passed a row that named one).

/// What a row named that the check did not find (`missing`), and what the check found that the
/// row did not name (`extra`). Both are empty when the row holds.
#[derive(Debug)]
pub struct Unmatched<'n, 'f, N, F> {
    pub missing: Vec<&'n N>,
    pub extra: Vec<&'f F>,
}

impl<N, F> Unmatched<'_, '_, N, F> {
    pub fn is_empty(&self) -> bool {
        self.missing.is_empty() && self.extra.is_empty()
    }
}

/// Pairs each of `named` with one of `found` it `hits`, each found one used once, as many pairs
/// as can be made (a maximum matching, so the order of `named` does not change the answer), and
/// returns what is left on either side.
pub fn unmatched<'n, 'f, N, F>(
    named: &'n [N],
    found: &'f [F],
    hits: impl Fn(&N, &F) -> bool,
) -> Unmatched<'n, 'f, N, F> {
    let mut owner: Vec<Option<usize>> = vec![None; found.len()];
    let mut paired = vec![false; named.len()];
    for (i, pair) in paired.iter_mut().enumerate() {
        let mut seen = vec![false; found.len()];
        *pair = augment(i, named, found, &hits, &mut seen, &mut owner);
    }
    Unmatched {
        missing: named.iter().zip(&paired).filter(|(_, p)| !**p).map(|(n, _)| n).collect(),
        extra: found.iter().zip(&owner).filter(|(_, o)| o.is_none()).map(|(f, _)| f).collect(),
    }
}

/// Kuhn's augmenting path from named `i`: takes a free found one it hits, or one whose owner
/// can move to another.
fn augment<N, F>(
    i: usize,
    named: &[N],
    found: &[F],
    hits: &impl Fn(&N, &F) -> bool,
    seen: &mut [bool],
    owner: &mut [Option<usize>],
) -> bool {
    // Every slot is read with `get`, so an index past the end is "taken" and never a panic.
    let Some(n) = named.get(i) else { return false };
    for (j, f) in found.iter().enumerate() {
        if seen.get(j).copied().unwrap_or(true) || !hits(n, f) {
            continue;
        }
        if let Some(s) = seen.get_mut(j) {
            *s = true;
        }
        let free = match owner.get(j).copied().flatten() {
            None => true,
            Some(k) => augment(k, named, found, hits, seen, owner),
        };
        if free {
            if let Some(o) = owner.get_mut(j) {
                *o = Some(i);
            }
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests;
