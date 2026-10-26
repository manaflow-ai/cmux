//! Once-per-site dedupe for stall records and debug logs: a fixed, lock-free
//! open-addressing set of call-site hashes.

use std::panic::Location;
use std::sync::atomic::{AtomicU64, Ordering};

/// Distinct stalled sites remembered per process; later sites are counted
/// in `Counts::sites_dropped` and not recorded.
pub(crate) const CAPACITY: usize = 1024;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Seen {
    First,
    Before,
    TableFull,
}

// 0 marks an empty slot; `site_key` never returns it.
static TABLE: [AtomicU64; CAPACITY] = [const { AtomicU64::new(0) }; CAPACITY];

/// Whether `location` stalled before in this process.
pub(crate) fn first_at(location: &Location<'_>) -> Seen {
    insert(&TABLE, site_key(location))
}

pub(crate) fn insert(table: &[AtomicU64], key: u64) -> Seen {
    let start = usize::try_from(key % table.len() as u64).unwrap_or(0);
    for probe in 0..table.len() {
        let slot = &table[(start + probe) % table.len()];
        match slot.compare_exchange(0, key, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => return Seen::First,
            Err(existing) if existing == key => return Seen::Before,
            Err(_) => {}
        }
    }
    Seen::TableFull
}

/// FNV-1a over `file:line:col`, never 0. Keyed by value, not by the
/// `Location` address, which the compiler may duplicate across codegen units.
pub(crate) fn site_key(location: &Location<'_>) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    let bytes = location
        .file()
        .bytes()
        .chain(location.line().to_le_bytes())
        .chain(location.column().to_le_bytes());
    for byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(PRIME);
    }
    hash.max(1)
}
