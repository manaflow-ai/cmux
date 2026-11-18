//! The order of the way back's work list around moves ([`super`]): a move's old path (its
//! origin) holds the only copy, on this Mac, of what the machine moved, so it is changed last,
//! and only when the move landed whole.
//!
//! Every item at, below or above an origin (its whiteout, the deletes an opaque folder means
//! there, a path an earlier pull brought that vanished there, a file over it) waits until every
//! other item ran. Then a move whose new path has an item that did not land in this pull keeps
//! its origin: each waiting item at, below or above it is refused as `origin_kept`, nothing
//! there changes, and neither the move nor a group holding such an item is settled. A move an
//! earlier pull settled landed then, and keeps nothing.

use super::{Failure, Group, Item, Run, Work};

/// Whether `path` is `top` or below it.
fn at_or_below(path: &str, top: &str) -> bool {
    path.strip_prefix(top).is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

/// Whether `item` can change what is at `origin`: it is at the origin or below it, or it is
/// above it and not a folder made (a folder above an origin is one here already).
fn touches(item: &Item, origin: &str) -> bool {
    match item.work {
        Work::Refused(_) => false,
        Work::Dir => item.path == origin,
        _ => at_or_below(&item.path, origin) || at_or_below(origin, &item.path),
    }
}

impl Run<'_, '_> {
    /// Runs the vanished paths, then the groups, the items touching an origin last.
    pub(super) fn ordered(&mut self, vanished: &[Item], groups: &[Group]) -> Result<(), Failure> {
        let origins: Vec<&str> = groups.iter().filter_map(|g| g.origin.as_deref()).collect();
        let waits = |item: &Item| origins.iter().any(|origin| touches(item, origin));
        let mut later_vanished = Vec::new();
        for item in vanished {
            if waits(item) {
                later_vanished.push(item);
            } else {
                self.step(item)?;
            }
        }
        let mut later = Vec::new();
        let mut moves = Vec::new();
        for group in groups {
            if let Some(tag) = &group.tag
                && self.settled(&group.head, tag)
            {
                continue;
            }
            if group.origin.is_none() && group.items.iter().any(waits) {
                later.push(group);
                continue;
            }
            for item in &group.items {
                self.step(item)?;
            }
            if group.origin.is_some() {
                moves.push(group);
            } else {
                self.settle(group)?;
            }
        }
        let mut kept = Vec::new();
        for group in moves {
            let landed = !self.unlanded.iter().any(|path| at_or_below(path, &group.head));
            match &group.origin {
                Some(origin) if !landed => kept.push(origin.clone()),
                _ => self.settle(group)?,
            }
        }
        for item in later_vanished {
            self.waited(item, &kept)?;
        }
        for group in later {
            let mut whole = true;
            for item in &group.items {
                whole &= self.waited(item, &kept)?;
            }
            if whole {
                self.settle(group)?;
            }
        }
        Ok(())
    }

    /// Runs an item that waited for the moves, or refuses it when it touches an origin that is
    /// `kept`; whether it ran.
    fn waited(&mut self, item: &Item, kept: &[String]) -> Result<bool, Failure> {
        if kept.iter().any(|origin| touches(item, origin)) {
            self.refuse(&item.path, "origin_kept");
            return Ok(false);
        }
        self.step(item)?;
        Ok(true)
    }
}
