//! Owner-side sort and filter for `fs.list` (finder.md 4.2). The comparator
//! matches the app's (`first-party-apps/finder/src/model/listing.ts`):
//! natural, case-insensitive names, with the raw name as the tiebreaker.

use std::cmp::Ordering;

use serde::{Deserialize, Serialize};

use super::{Entry, EntryKind};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SortKey {
    #[default]
    Name,
    Modified,
    Size,
    Kind,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SortDirection {
    #[default]
    Asc,
    Desc,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sort {
    #[serde(default)]
    pub key: SortKey,
    #[serde(default)]
    pub dir: SortDirection,
    #[serde(default)]
    pub dirs_first: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Filter {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<EntryKind>>,
}

impl Filter {
    #[must_use]
    pub fn admits(&self, entry: &Entry) -> bool {
        if entry.hidden && !self.hidden {
            return false;
        }
        if let Some(kinds) = &self.kinds
            && !kinds.contains(&entry.kind)
        {
            return false;
        }
        match &self.query {
            Some(query) if !query.is_empty() => {
                entry.name.to_lowercase().contains(&query.to_lowercase())
            }
            _ => true,
        }
    }
}

/// Sorts `entries` in place.
pub fn sort_entries(entries: &mut [Entry], sort: Sort) {
    entries.sort_by(|left, right| compare(left, right, sort));
}

fn compare(left: &Entry, right: &Entry, sort: Sort) -> Ordering {
    if sort.dirs_first {
        let left_dir = left.kind == EntryKind::Dir;
        let right_dir = right.kind == EntryKind::Dir;
        if left_dir != right_dir {
            return right_dir.cmp(&left_dir);
        }
    }
    let primary = match sort.key {
        SortKey::Name => Ordering::Equal,
        SortKey::Modified => left.mtime.cmp(&right.mtime),
        SortKey::Size => left.size.cmp(&right.size),
        SortKey::Kind => kind_rank(left.kind).cmp(&kind_rank(right.kind)),
    };
    let ordered = primary.then_with(|| natural(&left.name, &right.name));
    match sort.dir {
        SortDirection::Asc => ordered,
        SortDirection::Desc => ordered.reverse(),
    }
}

fn kind_rank(kind: EntryKind) -> u8 {
    match kind {
        EntryKind::Dir => 0,
        EntryKind::File => 1,
        EntryKind::Symlink => 2,
        EntryKind::Other => 3,
    }
}

/// Natural, case-insensitive order: digit runs compare by value, text runs
/// by lowercase; the raw names break ties so the order is total.
#[must_use]
pub fn natural(left: &str, right: &str) -> Ordering {
    let mut left_chars = left.chars().peekable();
    let mut right_chars = right.chars().peekable();
    loop {
        match (left_chars.peek().copied(), right_chars.peek().copied()) {
            (None, None) => return left.cmp(right),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(l), Some(r)) if l.is_ascii_digit() && r.is_ascii_digit() => {
                let left_run = take_digits(&mut left_chars);
                let right_run = take_digits(&mut right_chars);
                let left_value = left_run.trim_start_matches('0');
                let right_value = right_run.trim_start_matches('0');
                let order = left_value
                    .len()
                    .cmp(&right_value.len())
                    .then_with(|| left_value.cmp(right_value));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(l), Some(r)) => {
                let order = l.to_lowercase().cmp(r.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                left_chars.next();
                right_chars.next();
            }
        }
    }
}

fn take_digits(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut run = String::new();
    while let Some(character) = chars.peek().copied().filter(char::is_ascii_digit) {
        run.push(character);
        chars.next();
    }
    run
}
