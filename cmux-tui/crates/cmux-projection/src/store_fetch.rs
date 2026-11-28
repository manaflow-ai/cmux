//! The machine's side of RFD 0007 slice 3, "Faults from the store": a [`Fetch`] that asks the
//! store before the Mac, so a session keeps reading files it never read before while the Mac
//! sleeps.
//!
//! The Mac's [`crate::upload::Uploader`] puts the folder's small files in the store in prefetch
//! order and lists what it put ([`Link::stored`]): each file's entry and git blob id. The machine
//! learns that list from the Mac over the link while it is awake ([`StoreFirst::refresh`]), so the
//! ids are the Mac's own and the store is untrusted transport: a fault of a listed file asks the
//! blob chain ([`crate::peers::Chain`], whose every answer is hashed against its id) and serves
//! it; a file not listed, or one no source answers, goes to the Mac as before.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use crate::link::Link;
use crate::peers::Chain;
use crate::{Fetch, FetchError, Fetched};

/// Where faults went, for the mount's timing line and the tests.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Faults {
    /// Files served from the store.
    pub store: u64,
    /// Files (or ranges) asked of the Mac.
    pub mac: u64,
    /// Listed files no store source answered (asked of the Mac instead).
    pub missed: u64,
}

/// The store, then the Mac.
pub struct StoreFirst {
    link: Arc<Link>,
    chain: Chain,
    failures: Vec<AtomicUsize>,
    /// Entry to blob id, as the Mac listed them.
    ids: RwLock<HashMap<u32, String>>,
    /// The Mac upload's epoch and how many of its files this machine has learned.
    learned: Mutex<(u64, u32)>,
    store: AtomicU64,
    mac: AtomicU64,
    missed: AtomicU64,
}

impl StoreFirst {
    /// Faults of `link`'s folder, asked of `chain` first.
    #[must_use]
    pub fn new(link: Arc<Link>, chain: Chain) -> Self {
        let failures = chain.counters();
        Self {
            link,
            chain,
            failures,
            ids: RwLock::new(HashMap::new()),
            learned: Mutex::new((0, 0)),
            store: AtomicU64::new(0),
            mac: AtomicU64::new(0),
            missed: AtomicU64::new(0),
        }
    }

    /// Learns from the Mac which files it has put in the store since the last call; returns how
    /// many are new. Asks nothing while no stream is attached (the Mac is asleep: what was
    /// learned stays).
    pub fn refresh(&self) -> usize {
        let mut learned = self.learned.lock().unwrap_or_else(PoisonError::into_inner);
        let mut new = 0;
        while self.link.attached() {
            let since = learned.1;
            let Ok((epoch, files)) = self.link.stored(since) else { break };
            if epoch != learned.0 {
                // A new upload (the Mac restarted): its list starts again from 0. Ids already
                // learned stay valid (an id names bytes, not a moment).
                *learned = (epoch, 0);
                if since != 0 {
                    continue;
                }
            }
            if files.is_empty() {
                break;
            }
            learned.1 += files.len() as u32;
            let mut ids = self.ids.write().unwrap_or_else(PoisonError::into_inner);
            for (entry, oid) in files {
                if ids.insert(entry, oid).is_none() {
                    new += 1;
                }
            }
        }
        new
    }

    /// How many files the machine can read from the store.
    #[must_use]
    pub fn listed(&self) -> usize {
        self.ids.read().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Where faults went so far.
    #[must_use]
    pub fn faults(&self) -> Faults {
        Faults {
            store: self.store.load(Ordering::Relaxed),
            mac: self.mac.load(Ordering::Relaxed),
            missed: self.missed.load(Ordering::Relaxed),
        }
    }

    /// The whole of `entry` from the store, or `None` (not listed, or no source has it).
    fn stored_bytes(&self, entry: u32) -> Option<Vec<u8>> {
        let oid = self.ids.read().unwrap_or_else(PoisonError::into_inner).get(&entry).cloned()?;
        match self.chain.blob(&oid, &self.failures) {
            Some(bytes) => {
                self.store.fetch_add(1, Ordering::Relaxed);
                Some(bytes)
            }
            None => {
                self.missed.fetch_add(1, Ordering::Relaxed);
                None
            }
        }
    }
}

impl Fetch for StoreFirst {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        if let Some(bytes) = self.stored_bytes(entry) {
            let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
            let end = start.saturating_add(len as usize).min(bytes.len());
            return Ok(bytes.get(start..end).unwrap_or_default().to_vec());
        }
        self.mac.fetch_add(1, Ordering::Relaxed);
        self.link.read(entry, offset, len)
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        let mut answers: Vec<Option<Result<Vec<u8>, FetchError>>> =
            entries.iter().map(|entry| self.stored_bytes(*entry).map(Ok)).collect();
        let rest: Vec<u32> = entries
            .iter()
            .zip(&answers)
            .filter(|(_, answer)| answer.is_none())
            .map(|(entry, _)| *entry)
            .collect();
        if !rest.is_empty() {
            self.mac.fetch_add(rest.len() as u64, Ordering::Relaxed);
            let mut from_mac = self.link.batch(&rest).into_iter();
            for answer in answers.iter_mut().filter(|answer| answer.is_none()) {
                *answer = Some(from_mac.next().unwrap_or(Err(FetchError::Failed)));
            }
        }
        answers.into_iter().map(|answer| answer.unwrap_or(Err(FetchError::Failed))).collect()
    }

    // The store holds the manifest's bytes; a file the Mac re-lists after a change
    // (`Fetched::Restated`) can only come from the Mac.
    fn read_fresh(&self, entry: u32, offset: u64, len: u32) -> Result<Fetched, FetchError> {
        if let Some(bytes) = self.stored_bytes(entry) {
            let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
            let end = start.saturating_add(len as usize).min(bytes.len());
            return Ok(Fetched::Same(bytes.get(start..end).unwrap_or_default().to_vec()));
        }
        self.mac.fetch_add(1, Ordering::Relaxed);
        self.link.read_fresh(entry, offset, len)
    }

    fn batch_fresh(&self, entries: &[u32]) -> Vec<Result<Fetched, FetchError>> {
        let mut answers: Vec<Option<Result<Fetched, FetchError>>> = entries
            .iter()
            .map(|entry| self.stored_bytes(*entry).map(|bytes| Ok(Fetched::Same(bytes))))
            .collect();
        let rest: Vec<u32> = entries
            .iter()
            .zip(&answers)
            .filter(|(_, answer)| answer.is_none())
            .map(|(entry, _)| *entry)
            .collect();
        if !rest.is_empty() {
            self.mac.fetch_add(rest.len() as u64, Ordering::Relaxed);
            let mut from_mac = self.link.batch_fresh(&rest).into_iter();
            for answer in answers.iter_mut().filter(|answer| answer.is_none()) {
                *answer = Some(from_mac.next().unwrap_or(Err(FetchError::Failed)));
            }
        }
        answers.into_iter().map(|answer| answer.unwrap_or(Err(FetchError::Failed))).collect()
    }
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
