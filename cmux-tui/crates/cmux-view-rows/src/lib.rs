//! Revisioned keyed row windows and their minimal edits.
//!
//! One contract by which Rust tells a view what changed in a list it shows: the macOS app's lists
//! (sidebar rows, a pane's tab strip, badges) read rows that Rust computed, and a remote window's
//! client (acpmux's chat window, the daemon's history windows) reads the same shape over its socket
//! (handoff/rewrites/R-SWIFT-MIRRORS/DESIGN.md section 4.2). A view never holds a copy of the state
//! the rows come from, and never diffs two lists itself.
//!
//! - [`Rows`]: a list of keyed rows in view order; each key once (the constructor refuses a key
//!   twice).
//! - [`Window`] (the producer side): give it the whole current list each time it may have changed
//!   (level-triggered: a missed or coalesced change can never leave a receiver behind); it answers
//!   nothing when the list is the one it sent last, else one [`Diff`] from the list it sent last.
//! - [`Diff`]: the first message, or the one after [`Window::invalidate`], is a [`Diff::Reset`]
//!   with every row; every later one is a [`Diff::Edit`] from revision `base` to `revision`.
//! - [`Edit`]: the rows that left (by their base index), the rows that changed places (base index
//!   to new index), the new rows (by their new index) and the kept rows whose value changed.
//!   Minimal: no edit with fewer removed, inserted, moved or changed rows gives the same list. The
//!   moves are the kept rows outside one longest increasing subsequence of their new indices, so a
//!   row that moved is named and the others keep their places (a view moves one row view, never all
//!   of them).
//! - [`Applied`] (the receiver side): the reference apply. A receiver applies an edit only to the
//!   revision it starts from, and refuses a gap or an edit that does not fit its rows (the receiver
//!   asks its producer for a reset); a refused edit leaves its rows as they were.
//!
//! Indices: removed rows and move sources are base indices; inserted rows and move targets are new
//! indices, as in a batch update (NSCollectionView, UICollectionView). Changed rows are new indices
//! and apply after the structure: unlike a batch update's reloads, which name base indices, so a
//! view that hands an edit to a collection view reconfigures the changed rows after the batch. To
//! apply: put the moved and inserted rows at their new indices, fill every other new index with the
//! base rows that neither left nor moved, in base order, then replace the changed values. A move's
//! base and new index can be equal: the row still changes places against the rows around it
//! (`[a, b, c]` to `[c, b, a]` moves `a` and `b`, and `b` stays at index 1). A view that animates
//! knows each moved row's old and new place from the edit itself. An edit with no removed, moved or
//! inserted row only replaces values: O(changed rows).
//!
//! Revisions compare by equality only (a receiver applies an edit whose `base` equals the revision
//! it holds), never by order: they count up by one per message with wrapping arithmetic.

use std::collections::HashMap;
use std::fmt;
use std::hash::Hash;

/// A list of keyed rows in view order, each key once.
#[derive(Clone, Debug)]
pub struct Rows<K, R> {
    keys: Vec<K>,
    rows: Vec<R>,
    /// Each key's index in `keys`: kept with them, so a diff finds a key in O(1).
    index: HashMap<K, usize>,
}

/// [`Rows::new`] got the same key twice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DuplicateKey<K>(pub K);

impl<K: fmt::Debug> fmt::Display for DuplicateKey<K> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "the key {:?} is in the rows twice", self.0)
    }
}

impl<K: fmt::Debug> std::error::Error for DuplicateKey<K> {}

impl<K: Eq + Hash + Clone, R> Rows<K, R> {
    /// The rows in view order, or the first key that comes twice.
    pub fn new(rows: impl IntoIterator<Item = (K, R)>) -> Result<Self, DuplicateKey<K>> {
        let rows = rows.into_iter();
        let (expected, _) = rows.size_hint();
        let mut keys = Vec::with_capacity(expected);
        let mut values = Vec::with_capacity(expected);
        for (key, row) in rows {
            keys.push(key);
            values.push(row);
        }
        Self::from_parts(keys, values)
    }

    fn from_parts(keys: Vec<K>, rows: Vec<R>) -> Result<Self, DuplicateKey<K>> {
        let mut index = HashMap::with_capacity(keys.len());
        for (at, key) in keys.iter().enumerate() {
            if index.insert(key.clone(), at).is_some() {
                return Err(DuplicateKey(key.clone()));
            }
        }
        Ok(Self { keys, rows, index })
    }

    /// No rows.
    pub fn empty() -> Self {
        Self { keys: Vec::new(), rows: Vec::new(), index: HashMap::new() }
    }

    /// The index of `key`, if the rows have it.
    pub fn position(&self, key: &K) -> Option<usize> {
        self.index.get(key).copied()
    }

    /// The row of `key`, if the rows have it.
    pub fn get(&self, key: &K) -> Option<&R> {
        self.position(key).and_then(|at| self.rows.get(at))
    }
}

impl<K, R> Rows<K, R> {
    /// The number of rows.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// Whether there are no rows.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The keys in view order.
    pub fn keys(&self) -> &[K] {
        &self.keys
    }

    /// The rows in view order (the row of `keys()[i]` is `rows()[i]`).
    pub fn rows(&self) -> &[R] {
        &self.rows
    }

    /// The keys and rows in view order.
    pub fn iter(&self) -> impl Iterator<Item = (&K, &R)> {
        self.keys.iter().zip(&self.rows)
    }
}

/// Two lists are equal when they hold the same keys with the same rows in the same order.
impl<K: PartialEq, R: PartialEq> PartialEq for Rows<K, R> {
    fn eq(&self, other: &Self) -> bool {
        self.keys == other.keys && self.rows == other.rows
    }
}

impl<K: Eq, R: Eq> Eq for Rows<K, R> {}

/// What changed in a window since the message before it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Diff<K, R> {
    /// Every row, in order: a receiver drops what it holds, whatever its revision.
    Reset { revision: u64, rows: Rows<K, R> },
    /// The change from revision `base` (which a receiver must hold) to `revision`.
    Edit { base: u64, revision: u64, edit: Edit<K, R> },
}

impl<K, R> Diff<K, R> {
    /// The revision a receiver holds after it applied this diff.
    pub fn revision(&self) -> u64 {
        match self {
            Self::Reset { revision, .. } | Self::Edit { revision, .. } => *revision,
        }
    }
}

/// A kept row that changed places: from its index in the base list to its index in the new list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Move {
    pub from: usize,
    pub to: usize,
}

/// A row and its index in the new list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placed<K, R> {
    pub at: usize,
    pub key: K,
    pub row: R,
}

/// The change from a base list to a new list (see the crate documentation for the index rules).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit<K, R> {
    /// The base indices of the rows the new list does not have, ascending.
    pub removed: Vec<usize>,
    /// The kept rows that change places, ascending by their new index. Every other kept row keeps
    /// its order relative to the other unlisted kept rows.
    pub moved: Vec<Move>,
    /// The rows the base list did not have, ascending by their new index.
    pub inserted: Vec<Placed<K, R>>,
    /// The kept rows (moved or not) whose value changed, ascending by their new index.
    pub changed: Vec<Placed<K, R>>,
    /// The number of rows in the new list.
    pub count: usize,
}

impl<K, R> Edit<K, R> {
    /// Whether a row leaves, comes or changes places (else only values change).
    pub fn is_structural(&self) -> bool {
        !self.removed.is_empty() || !self.moved.is_empty() || !self.inserted.is_empty()
    }

    /// Whether the new list equals the base list.
    pub fn is_empty(&self) -> bool {
        !self.is_structural() && self.changed.is_empty()
    }
}

/// The producer side of one window: the list it sent last and the revision of that message.
#[derive(Clone, Debug)]
pub struct Window<K, R> {
    revision: u64,
    /// None before the first message and after [`Window::invalidate`]: the next message is a reset.
    sent: Option<Rows<K, R>>,
}

impl<K: Eq + Hash + Clone, R: Clone + PartialEq> Default for Window<K, R> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Eq + Hash + Clone, R: Clone + PartialEq> Window<K, R> {
    /// A window whose first message has revision 1.
    pub fn new() -> Self {
        Self::starting_after(0)
    }

    /// A window whose first message has revision `revision + 1`: a window that replaces another one
    /// for the same receiver (a new spec) goes on from the old one's revision.
    pub fn starting_after(revision: u64) -> Self {
        Self { revision, sent: None }
    }

    /// The revision of the last message (0, or the `starting_after` revision, before the first
    /// one).
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The list the last message brought a receiver to; None before the first message and after
    /// [`Window::invalidate`].
    pub fn sent(&self) -> Option<&Rows<K, R>> {
        self.sent.as_ref()
    }

    /// The next message is a reset: the receiver asked for every row (it saw a gap or refused an
    /// edit), or the window shows something else now.
    pub fn invalidate(&mut self) {
        self.sent = None;
    }

    /// The message that brings a receiver from the last list to `rows`: None when `rows` is that
    /// list, a reset for the first message and after [`Window::invalidate`], else the minimal edit.
    pub fn next(&mut self, rows: Rows<K, R>) -> Option<Diff<K, R>> {
        let revision = self.revision.wrapping_add(1);
        let diff = match &self.sent {
            None => Diff::Reset { revision, rows: rows.clone() },
            Some(sent) => {
                let edit = edit_between(sent, &rows);
                if edit.is_empty() {
                    return None;
                }
                Diff::Edit { base: self.revision, revision, edit }
            }
        };
        self.revision = revision;
        self.sent = Some(rows);
        Some(diff)
    }
}

/// The minimal edit from `base` to `new`, in O(n log n): the kept rows keep their places along one
/// longest increasing run of their new indices, and only the others move.
fn edit_between<K: Eq + Hash + Clone, R: Clone + PartialEq>(
    base: &Rows<K, R>,
    new: &Rows<K, R>,
) -> Edit<K, R> {
    let mut removed = Vec::new();
    // The kept rows in base order, each from its base index to its new index.
    let mut kept = Vec::new();
    for (from, key) in base.keys.iter().enumerate() {
        match new.position(key) {
            Some(to) => kept.push(Move { from, to }),
            None => removed.push(from),
        }
    }
    let targets: Vec<usize> = kept.iter().map(|step| step.to).collect();
    let mut moved: Vec<Move> = kept
        .into_iter()
        .zip(longest_increasing(&targets))
        .filter(|(_, keeps_place)| !keeps_place)
        .map(|(step, _)| step)
        .collect();
    moved.sort_unstable_by_key(|step| step.to);
    let mut inserted = Vec::new();
    let mut changed = Vec::new();
    for (at, (key, row)) in new.iter().enumerate() {
        match base.get(key) {
            None => inserted.push(Placed { at, key: key.clone(), row: row.clone() }),
            Some(before) if before != row => {
                changed.push(Placed { at, key: key.clone(), row: row.clone() });
            }
            Some(_) => {}
        }
    }
    Edit { removed, moved, inserted, changed, count: new.len() }
}

/// Marks the members of one longest strictly increasing subsequence of `values` (patience sorting
/// with back links, O(n log n)). Ties between equally long subsequences go to the one that ends at
/// the smallest last value found first, so the same input always marks the same rows.
fn longest_increasing(values: &[usize]) -> Vec<bool> {
    // tails[l]: the index (into `values`) of the smallest last value of an increasing subsequence
    // of length l + 1 found so far; their values increase with l.
    let mut tails: Vec<usize> = Vec::new();
    // before[i]: the index before i in the subsequence that ends at i.
    let mut before: Vec<Option<usize>> = Vec::with_capacity(values.len());
    for (i, value) in values.iter().enumerate() {
        let length =
            tails.partition_point(|&tail| values.get(tail).is_some_and(|last| last < value));
        before.push(length.checked_sub(1).and_then(|shorter| tails.get(shorter).copied()));
        match tails.get_mut(length) {
            Some(tail) => *tail = i,
            None => tails.push(i),
        }
    }
    let mut member = vec![false; values.len()];
    let mut at = tails.last().copied();
    while let Some(i) = at {
        if let Some(mark) = member.get_mut(i) {
            *mark = true;
        }
        at = before.get(i).copied().flatten();
    }
    member
}

/// The receiver side of one window: the rows it shows and the revision they are at.
#[derive(Clone, Debug)]
pub struct Applied<K, R> {
    /// None until the first reset.
    revision: Option<u64>,
    rows: Rows<K, R>,
}

/// Why a receiver refused a diff. Either way it keeps its rows and asks its producer for a reset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApplyError {
    /// The edit starts from `base`, but the receiver holds `held` (None: no reset came yet).
    Gap { held: Option<u64>, base: u64 },
    /// The edit does not fit the rows the receiver holds.
    Malformed(Malformed),
}

/// How an edit does not fit the receiver's rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Malformed {
    /// A base index is past the base rows, or a new index past the new count.
    IndexOutOfRange,
    /// A base row is removed or moved twice.
    BaseRowTwice,
    /// A new index gets two rows.
    NewIndexTwice,
    /// The base rows that stay and the inserted rows are fewer than the new count.
    TooFewRows,
    /// The base rows that stay and the inserted rows are more than the new count.
    TooManyRows,
    /// A changed row's key is not the key at its new index.
    KeyMismatch,
    /// The new list has a key twice.
    DuplicateKey,
    /// An edit that only changes values gives another count.
    CountMismatch,
}

impl fmt::Display for ApplyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Gap { held: Some(held), base } => {
                write!(f, "the edit starts from revision {base}, but the receiver holds {held}")
            }
            Self::Gap { held: None, base } => {
                write!(
                    f,
                    "the edit starts from revision {base}, but the receiver holds no rows yet"
                )
            }
            Self::Malformed(why) => write!(f, "the edit does not fit the receiver's rows: {why:?}"),
        }
    }
}

impl std::error::Error for ApplyError {}

impl<K: Eq + Hash + Clone, R: Clone> Default for Applied<K, R> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Eq + Hash + Clone, R: Clone> Applied<K, R> {
    /// A receiver that holds no rows yet: it takes only a reset.
    pub fn new() -> Self {
        Self { revision: None, rows: Rows::empty() }
    }

    /// The revision of the last diff applied; None before the first reset.
    pub fn revision(&self) -> Option<u64> {
        self.revision
    }

    /// The rows the receiver shows.
    pub fn rows(&self) -> &Rows<K, R> {
        &self.rows
    }

    /// Applies `diff`; a refused diff changes nothing.
    pub fn apply(&mut self, diff: Diff<K, R>) -> Result<(), ApplyError> {
        match diff {
            Diff::Reset { revision, rows } => {
                self.rows = rows;
                self.revision = Some(revision);
                Ok(())
            }
            Diff::Edit { base, revision, edit } => {
                if self.revision != Some(base) {
                    return Err(ApplyError::Gap { held: self.revision, base });
                }
                if edit.is_structural() {
                    self.rows = rebuilt(&self.rows, edit).map_err(ApplyError::Malformed)?;
                } else {
                    replace_values(&mut self.rows, edit).map_err(ApplyError::Malformed)?;
                }
                self.revision = Some(revision);
                Ok(())
            }
        }
    }
}

/// An edit that only changes values, applied in place in O(changed rows); checked whole before the
/// first write, so a refused edit changes nothing.
fn replace_values<K: PartialEq, R>(
    rows: &mut Rows<K, R>,
    edit: Edit<K, R>,
) -> Result<(), Malformed> {
    if edit.count != rows.keys.len() {
        return Err(Malformed::CountMismatch);
    }
    for change in &edit.changed {
        match rows.keys.get(change.at) {
            None => return Err(Malformed::IndexOutOfRange),
            Some(key) if *key != change.key => return Err(Malformed::KeyMismatch),
            Some(_) => {}
        }
    }
    for change in edit.changed {
        if let Some(row) = rows.rows.get_mut(change.at) {
            *row = change.row;
        }
    }
    Ok(())
}

/// The new list of a structural edit, built beside the base list (which stays as it is on a
/// refusal).
fn rebuilt<K: Eq + Hash + Clone, R: Clone>(
    base: &Rows<K, R>,
    edit: Edit<K, R>,
) -> Result<Rows<K, R>, Malformed> {
    let Edit { removed, moved, inserted, changed, count } = edit;
    // The base rows that leave their place: removed, or moved to another index.
    let mut gone = vec![false; base.keys.len()];
    let mut leave = |from: usize| -> Result<(), Malformed> {
        let slot = gone.get_mut(from).ok_or(Malformed::IndexOutOfRange)?;
        if *slot {
            return Err(Malformed::BaseRowTwice);
        }
        *slot = true;
        Ok(())
    };
    for &from in &removed {
        leave(from)?;
    }
    // The new list holds the base rows that stay and the inserted ones: a `count` that differs is
    // refused here, before anything is allocated for it (a huge count would abort the process).
    match base
        .keys
        .len()
        .checked_sub(removed.len())
        .and_then(|kept| kept.checked_add(inserted.len()))
    {
        Some(expected) if count == expected => {}
        Some(expected) if count > expected => return Err(Malformed::TooFewRows),
        _ => return Err(Malformed::TooManyRows),
    }
    let mut slots: Vec<Option<(K, R)>> = std::iter::repeat_with(|| None).take(count).collect();
    let mut put = |at: usize, key: K, row: R| -> Result<(), Malformed> {
        let slot = slots.get_mut(at).ok_or(Malformed::IndexOutOfRange)?;
        if slot.is_some() {
            return Err(Malformed::NewIndexTwice);
        }
        *slot = Some((key, row));
        Ok(())
    };
    for Move { from, to } in moved {
        leave(from)?;
        let key = base.keys.get(from).ok_or(Malformed::IndexOutOfRange)?;
        let row = base.rows.get(from).ok_or(Malformed::IndexOutOfRange)?;
        put(to, key.clone(), row.clone())?;
    }
    for Placed { at, key, row } in inserted {
        put(at, key, row)?;
    }
    // The rows that keep their places fill the free indices in base order.
    let mut staying = base
        .keys
        .iter()
        .zip(&base.rows)
        .zip(&gone)
        .filter(|(_, left)| !**left)
        .map(|(pair, _)| pair);
    let mut keys = Vec::with_capacity(count);
    let mut rows = Vec::with_capacity(count);
    for slot in slots {
        let (key, row) = match slot {
            Some(placed) => placed,
            None => {
                let (key, row) = staying.next().ok_or(Malformed::TooFewRows)?;
                (key.clone(), row.clone())
            }
        };
        keys.push(key);
        rows.push(row);
    }
    if staying.next().is_some() {
        return Err(Malformed::TooManyRows);
    }
    for Placed { at, key, row } in changed {
        match keys.get(at) {
            None => return Err(Malformed::IndexOutOfRange),
            Some(held) if *held != key => return Err(Malformed::KeyMismatch),
            Some(_) => {}
        }
        if let Some(slot) = rows.get_mut(at) {
            *slot = row;
        }
    }
    Rows::from_parts(keys, rows).map_err(|_| Malformed::DuplicateKey)
}

#[cfg(test)]
mod view_rows_tests;
