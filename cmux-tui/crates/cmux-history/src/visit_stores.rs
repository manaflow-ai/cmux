//! Every browser profile's visit log under one directory: one SQLite file
//! per profile, named by an injective encoding of the profile id.

use std::collections::BTreeMap;
use std::collections::btree_map::Entry;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::entry::{HistoryEntry, HistoryKind};
use crate::error::HistoryError;
use crate::query::HistoryQuery;
use crate::visits::{NewVisit, VisitStore, VisitSummary};

const EXTENSION: &str = ".sqlite";
/// The page window a list reads per profile when the query has no limit
/// (Swift `HistoryService.entries`).
const DEFAULT_PAGE_LIMIT: usize = 500;

/// What a removal did: how many visits went, and the id that restores them
/// (`None` when nothing was removed). RECOVERABLE-BY-DEFAULT: every removal
/// keeps a backup until it is restored, purged by the person, or its visits
/// pass the retention.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Removal {
    pub removed: usize,
    pub restore_id: Option<String>,
}

/// The visit logs of every profile, opened on first use and kept open (one
/// connection per profile).
pub struct VisitStores {
    directory: PathBuf,
    open: BTreeMap<String, VisitStore>,
}

impl VisitStores {
    /// Stores under `directory`; nothing is created until a store opens.
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into(), open: BTreeMap::new() }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// The file of `profile`'s log.
    pub fn path(&self, profile: &str) -> PathBuf {
        self.directory.join(profile_file_name(profile))
    }

    /// `profile`'s log, opened (and created) on first use.
    pub fn store(&mut self, profile: &str) -> Result<&VisitStore, HistoryError> {
        let path = self.path(profile);
        match self.open.entry(profile.to_owned()) {
            Entry::Occupied(entry) => Ok(entry.into_mut()),
            Entry::Vacant(entry) => Ok(entry.insert(VisitStore::open(&path)?)),
        }
    }

    /// Every profile with a log on disk or open, sorted.
    pub fn profiles(&self) -> Result<Vec<String>, HistoryError> {
        let mut profiles: Vec<String> = self.open.keys().cloned().collect();
        match std::fs::read_dir(&self.directory) {
            Ok(entries) => {
                for entry in entries {
                    let name = entry?.file_name();
                    if let Some(profile) = name.to_str().and_then(profile_from_file_name) {
                        profiles.push(profile);
                    }
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        profiles.sort();
        profiles.dedup();
        Ok(profiles)
    }

    /// Records a visit in `profile`'s log; returns the entry id.
    pub fn record(&mut self, profile: &str, visit: &NewVisit) -> Result<String, HistoryError> {
        let id = self.store(profile)?.record(visit)?;
        Ok(format!("page:{profile}:{id}"))
    }

    /// Sets the title of `url`'s newest visit in `profile`.
    pub fn update_title(
        &mut self,
        profile: &str,
        url: &str,
        title: &str,
    ) -> Result<usize, HistoryError> {
        self.store(profile)?.update_title(url, title)
    }

    /// `profile`'s summaries (the omnibox seed).
    pub fn summaries(
        &mut self,
        profile: &str,
        limit: usize,
    ) -> Result<Vec<VisitSummary>, HistoryError> {
        self.store(profile)?.summaries(limit)
    }

    /// The page entries of every profile for `query`'s window: its text
    /// pre-filter, the start of its range and its limit (default 500) per
    /// profile. Not yet sorted or filtered; pass the merge to
    /// [`crate::apply`].
    pub fn entries(
        &mut self,
        query: &HistoryQuery,
        now_ms: i64,
        local_day_start_ms: i64,
    ) -> Result<Vec<HistoryEntry>, HistoryError> {
        if !query.wants(HistoryKind::Page) {
            return Ok(Vec::new());
        }
        let since = query.range.start(now_ms, local_day_start_ms);
        let limit = query.limit.unwrap_or(DEFAULT_PAGE_LIMIT);
        let mut entries = Vec::new();
        for profile in self.profiles()? {
            entries.extend(self.store(&profile)?.entries(&profile, &query.text, since, limit)?);
        }
        Ok(entries)
    }

    /// Removes the page visits named by entry ids (`page:<profile>:<id>`);
    /// other ids are ignored. Returns how many visits went.
    pub fn remove_ids<S: AsRef<str>>(&mut self, ids: &[S]) -> Result<Removal, HistoryError> {
        let backup = new_restore_id()?;
        let mut removed = 0;
        for id in ids {
            if let Some((profile, visit)) = parse_page_id(id.as_ref()) {
                removed += self.store(profile)?.remove_visit(visit, &backup)?;
            }
        }
        Ok(removal(removed, backup))
    }

    /// Removes every visit of `host` and its subdomains, in `profile` or
    /// (`None`) every profile.
    pub fn remove_host(
        &mut self,
        host: &str,
        profile: Option<&str>,
    ) -> Result<Removal, HistoryError> {
        let backup = new_restore_id()?;
        let mut removed = 0;
        for profile in self.targets(profile)? {
            removed += self.store(&profile)?.remove_host(host, &backup)?;
        }
        Ok(removal(removed, backup))
    }

    /// Removes visits at or after `since_ms` (`None`: all), in `profile` or
    /// every profile.
    pub fn clear(
        &mut self,
        since_ms: Option<i64>,
        profile: Option<&str>,
    ) -> Result<Removal, HistoryError> {
        let backup = new_restore_id()?;
        let mut removed = 0;
        for profile in self.targets(profile)? {
            removed += self.store(&profile)?.remove_since(since_ms, &backup)?;
        }
        Ok(removal(removed, backup))
    }

    /// Restores a removal in every profile; returns how many visits came back.
    pub fn restore(&mut self, restore_id: &str) -> Result<usize, HistoryError> {
        let mut restored = 0;
        for profile in self.profiles()? {
            restored += self.store(&profile)?.restore(restore_id)?;
        }
        Ok(restored)
    }

    /// Deletes a removal's backup for good (a user-origin op); returns how
    /// many visits it held.
    pub fn purge(&mut self, restore_id: &str) -> Result<usize, HistoryError> {
        let mut purged = 0;
        for profile in self.profiles()? {
            purged += self.store(&profile)?.purge(restore_id)?;
        }
        Ok(purged)
    }

    /// Prunes every profile to 90 days and 100,000 visits.
    pub fn prune(&mut self, now_ms: i64) -> Result<usize, HistoryError> {
        let mut removed = 0;
        for profile in self.profiles()? {
            removed += self.store(&profile)?.prune(now_ms)?;
        }
        Ok(removed)
    }

    fn targets(&self, profile: Option<&str>) -> Result<Vec<String>, HistoryError> {
        match profile {
            Some(profile) => Ok(vec![profile.to_owned()]),
            None => self.profiles(),
        }
    }
}

fn removal(removed: usize, backup: String) -> Removal {
    Removal { removed, restore_id: (removed > 0).then_some(backup) }
}

/// A fresh restore id, `history:<32 hex>`: 128 bits from the OS random
/// source. An id is a capability to bring data back, so it is never
/// derived from another one.
fn new_restore_id() -> Result<String, HistoryError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| HistoryError::Io(std::io::Error::other(error.to_string())))?;
    Ok(format!("history:{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()))
}

/// `page:<profile>:<visit id>`; the profile may contain colons.
fn parse_page_id(id: &str) -> Option<(&str, i64)> {
    let (profile, visit) = id.strip_prefix("page:")?.rsplit_once(':')?;
    Some((profile, visit.parse().ok()?))
}

/// The file name of a profile's log: ASCII letters, digits and `-` stay;
/// `.` stays except as the first character; every other byte becomes `_`
/// and two lowercase hex digits. `_` always starts an escape, so the
/// encoding is injective and never yields `.`, `..` or a path separator.
pub fn profile_file_name(profile: &str) -> String {
    let mut name = String::with_capacity(profile.len() + EXTENSION.len());
    for (index, byte) in profile.bytes().enumerate() {
        let keep = byte.is_ascii_alphanumeric() || byte == b'-' || (byte == b'.' && index > 0);
        if keep {
            name.push(char::from(byte));
        } else {
            name.push_str(&format!("_{byte:02x}"));
        }
    }
    name.push_str(EXTENSION);
    name
}

/// The profile id of a log file name, or `None` for any other file
/// (including SQLite's `-wal` and `-shm` side files).
pub fn profile_from_file_name(name: &str) -> Option<String> {
    let stem = name.strip_suffix(EXTENSION)?;
    let mut bytes = Vec::with_capacity(stem.len());
    let mut rest = stem.as_bytes();
    while let Some((&byte, tail)) = rest.split_first() {
        if byte == b'_' {
            let hex = std::str::from_utf8(tail.get(..2)?).ok()?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
            rest = &tail[2..];
        } else {
            bytes.push(byte);
            rest = tail;
        }
    }
    let profile = String::from_utf8(bytes).ok()?;
    (profile_file_name(&profile) == name).then_some(profile)
}

#[cfg(test)]
#[path = "visit_stores_tests.rs"]
mod tests;
