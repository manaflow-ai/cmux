//! Owner-side listing snapshots behind a cursor (finder.md 4.2).
//!
//! The owner reads, filters and sorts a directory once and hands out
//! batches. A snapshot lives 5 minutes after its last use; each
//! (app, conn) keeps at most 8. Expiry is checked when a listing is used,
//! so nothing runs on a timer.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::{Entry, FsError};
use crate::ids::random_id;

pub const LISTING_PREFIX: &str = "lst_";
pub const LISTING_IDLE_TTL: Duration = Duration::from_secs(5 * 60);
pub const LISTINGS_PER_OWNER: usize = 8;
pub const MAX_BATCH: usize = 1000;

/// One batch of a listing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page {
    pub listing: String,
    pub entries: Vec<Entry>,
    pub cursor: Option<String>,
    pub total: Option<u64>,
    pub revision: String,
}

struct Listing {
    owner: String,
    entries: Vec<Entry>,
    revision: String,
    last_used: Instant,
}

/// The snapshots of one link.
#[derive(Default)]
pub struct Listings {
    listings: HashMap<String, Listing>,
}

impl Listings {
    /// Stores a sorted snapshot for `owner` (an app and conn key) and
    /// returns its first batch.
    pub fn insert(
        &mut self,
        owner: &str,
        entries: Vec<Entry>,
        revision: String,
        limit: usize,
        now: Instant,
    ) -> Page {
        self.expire(now);
        let mine = self.listings.iter().filter(|(_, listing)| listing.owner == owner);
        if mine.clone().count() >= LISTINGS_PER_OWNER
            && let Some(oldest) =
                mine.min_by_key(|(_, listing)| listing.last_used).map(|(id, _)| id.clone())
        {
            self.listings.remove(&oldest);
        }
        let id = random_id(LISTING_PREFIX);
        self.listings.insert(
            id.clone(),
            Listing { owner: owner.to_owned(), entries, revision, last_used: now },
        );
        self.page(owner, &id, None, limit, now).expect("the listing was just stored")
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
        let end = (offset + limit).min(stored.entries.len());
        Ok(Page {
            listing: listing.to_owned(),
            entries: stored.entries[offset..end].to_vec(),
            cursor: (end < stored.entries.len()).then(|| format!("c{end}")),
            total: Some(stored.entries.len() as u64),
            revision: stored.revision.clone(),
        })
    }

    fn expire(&mut self, now: Instant) {
        self.listings.retain(|_, listing| {
            now.saturating_duration_since(listing.last_used) < LISTING_IDLE_TTL
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs::EntryKind;

    fn entries(count: usize) -> Vec<Entry> {
        (0..count)
            .map(|index| Entry {
                name: format!("f{index}"),
                kind: EntryKind::File,
                size: Some(1),
                mtime: None,
                hidden: false,
                target_kind: None,
            })
            .collect()
    }

    #[test]
    fn batches_follow_the_cursor_and_expire_when_idle() {
        let mut listings = Listings::default();
        let start = Instant::now();
        let first = listings.insert("app/conn", entries(5), "r1".into(), 2, start);
        assert_eq!(first.entries.len(), 2);
        assert_eq!(first.total, Some(5));
        let second =
            listings.page("app/conn", &first.listing, first.cursor.as_deref(), 2, start).unwrap();
        assert_eq!(second.entries[0].name, "f2");
        let third =
            listings.page("app/conn", &first.listing, second.cursor.as_deref(), 2, start).unwrap();
        assert_eq!(third.entries.len(), 1);
        assert_eq!(third.cursor, None);
        assert_eq!(
            listings.page("other/conn", &first.listing, None, 2, start),
            Err(FsError::CursorExpired),
            "another app cannot read the snapshot"
        );
        assert_eq!(
            listings.page("app/conn", &first.listing, Some("c99"), 2, start),
            Err(FsError::CursorExpired)
        );
        let later = start + LISTING_IDLE_TTL;
        assert_eq!(
            listings.page("app/conn", &first.listing, None, 2, later),
            Err(FsError::CursorExpired)
        );
    }

    #[test]
    fn an_owner_keeps_at_most_eight_listings() {
        let mut listings = Listings::default();
        let start = Instant::now();
        let first = listings.insert("a", entries(1), "r".into(), 1, start);
        for step in 1..=LISTINGS_PER_OWNER {
            listings.insert(
                "a",
                entries(1),
                "r".into(),
                1,
                start + Duration::from_secs(step as u64),
            );
        }
        assert_eq!(
            listings.page("a", &first.listing, None, 1, start + Duration::from_secs(20)),
            Err(FsError::CursorExpired),
            "the least recently used listing is dropped"
        );
    }
}
