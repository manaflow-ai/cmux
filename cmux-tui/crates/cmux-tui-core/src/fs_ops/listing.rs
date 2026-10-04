//! `fs.list` snapshots behind an `lst_` cursor, sort and filter (the same
//! shapes and comparator as the link's SFTP owner, finder.md 4.2).
//!
//! The owner reads, filters and sorts a directory once and hands out
//! batches. A snapshot lives 5 minutes after its last use; each caller
//! keeps at most 8. Expiry is checked when a listing is used, so nothing
//! runs on a timer.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::entry::{Entry, EntryKind};
use super::error::FsError;
use super::sys;

pub const LISTING_PREFIX: &str = "lst_";
pub const LISTING_IDLE_TTL: Duration = Duration::from_secs(5 * 60);
pub const LISTINGS_PER_OWNER: usize = 8;
pub const MAX_BATCH: usize = 1000;
/// Most snapshots the daemon keeps across all callers.
const MAX_LISTINGS: usize = 256;

/// One batch of a listing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Page {
    pub entries: Vec<Entry>,
    pub listing: String,
    pub cursor: Option<String>,
    pub total: u64,
    pub revision: String,
}

struct Listing {
    owner: String,
    entries: Vec<Entry>,
    revision: String,
    last_used: Instant,
}

#[derive(Default)]
pub struct Listings {
    listings: HashMap<String, Listing>,
}

impl Listings {
    /// Stores a sorted snapshot for `owner` and returns its first batch.
    pub fn insert(
        &mut self,
        owner: &str,
        entries: Vec<Entry>,
        revision: String,
        limit: usize,
        now: Instant,
    ) -> Result<Page, FsError> {
        self.expire(now);
        let mine: Vec<(String, Instant)> = self
            .listings
            .iter()
            .filter(|(_, listing)| listing.owner == owner)
            .map(|(id, listing)| (id.clone(), listing.last_used))
            .collect();
        if mine.len() >= LISTINGS_PER_OWNER {
            self.drop_oldest(mine);
        }
        if self.listings.len() >= MAX_LISTINGS {
            let all = self.listings.iter().map(|(id, l)| (id.clone(), l.last_used)).collect();
            self.drop_oldest(all);
        }
        let id = format!("{LISTING_PREFIX}{}", sys::random_hex(12));
        self.listings.insert(
            id.clone(),
            Listing { owner: owner.to_owned(), entries, revision, last_used: now },
        );
        self.page(owner, &id, None, limit, now)
    }

    fn drop_oldest(&mut self, candidates: Vec<(String, Instant)>) {
        if let Some((oldest, _)) = candidates.into_iter().min_by_key(|(_, used)| *used) {
            self.listings.remove(&oldest);
        }
    }

    /// A later batch. A listing of another owner is reported as expired so
    /// that its existence does not leak.
    pub fn page(
        &mut self,
        owner: &str,
        listing: &str,
        cursor: Option<&str>,
        limit: usize,
        now: Instant,
    ) -> Result<Page, FsError> {
        self.expire(now);
        let stored = self
            .listings
            .get_mut(listing)
            .filter(|stored| stored.owner == owner)
            .ok_or(FsError::CursorExpired)?;
        stored.last_used = now;
        let offset = match cursor {
            None => 0,
            Some(cursor) => cursor
                .strip_prefix('c')
                .and_then(|offset| offset.parse::<usize>().ok())
                .filter(|offset| *offset <= stored.entries.len())
                .ok_or(FsError::CursorExpired)?,
        };
        let limit = limit.clamp(1, MAX_BATCH);
        let end = offset.saturating_add(limit).min(stored.entries.len());
        Ok(Page {
            entries: stored.entries[offset..end].to_vec(),
            listing: listing.to_owned(),
            cursor: (end < stored.entries.len()).then(|| format!("c{end}")),
            total: stored.entries.len() as u64,
            revision: stored.revision.clone(),
        })
    }

    fn expire(&mut self, now: Instant) {
        self.listings.retain(|_, listing| {
            now.saturating_duration_since(listing.last_used) < LISTING_IDLE_TTL
        });
    }
}

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
    /// Dotfiles are listed only when this is true.
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
