//! The install's port block (server.md 8.2).
//!
//! First candidate `15432 + fnv1a64(install_id) % 10000`, then the next
//! candidate in `[15432, 25432)` (wrapping) whose whole 32-port block is free.
//! `+0` is Postgres, `+1..=+31` are app services. A persisted port is reused
//! unchanged, so the block never moves once chosen.

use std::collections::BTreeSet;

pub const RANGE_START: u16 = 15432;
pub const RANGE_LEN: u16 = 10_000;
pub const BLOCK_LEN: u16 = 32;
pub const SERVICE_PORTS: usize = (BLOCK_LEN - 1) as usize;
/// The stock Postgres port; never ours, so a distro cluster never collides.
pub const POSTGRES_DEFAULT: u16 = 5432;

/// 64-bit FNV-1a over the UTF-8 bytes.
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

pub fn first_candidate(install_id: &str) -> u16 {
    let offset = (fnv1a64(install_id.as_bytes()) % u64::from(RANGE_LEN)) as u16;
    RANGE_START + offset
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortBlock {
    pub postgres: u16,
    pub services: [u16; SERVICE_PORTS],
}

impl PortBlock {
    pub fn starting_at(base: u16) -> Option<PortBlock> {
        let last = base.checked_add(BLOCK_LEN - 1)?;
        if base == 0 || (base..=last).contains(&POSTGRES_DEFAULT) {
            return None;
        }
        let mut services = [0u16; SERVICE_PORTS];
        for (i, port) in services.iter_mut().enumerate() {
            *port = base + 1 + i as u16;
        }
        Some(PortBlock { postgres: base, services })
    }

    pub fn ports(&self) -> impl Iterator<Item = u16> + '_ {
        std::iter::once(self.postgres).chain(self.services.iter().copied())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PortSource {
    /// `postgres.port` from `server.json` (or set by the user).
    Persisted,
    /// Newly chosen; the caller persists `postgres` before using it.
    Allocated,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Allocation {
    pub block: PortBlock,
    pub source: PortSource,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PortError {
    /// The persisted port is 0, 5432, or its block does not fit below 65536.
    InvalidPersisted(u16),
    /// No free 32-port block in the range.
    Exhausted,
}

/// Chooses the install's port block.
///
/// A persisted port wins even when it is in `in_use`: the holder is usually
/// our own cluster. The I/O crate detects a foreign holder when the cluster
/// fails to bind and reports it; it never moves the port silently.
pub fn allocate(
    install_id: &str,
    in_use: &BTreeSet<u16>,
    persisted: Option<u16>,
) -> Result<Allocation, PortError> {
    if let Some(port) = persisted {
        let block = PortBlock::starting_at(port).ok_or(PortError::InvalidPersisted(port))?;
        return Ok(Allocation { block, source: PortSource::Persisted });
    }
    let first = first_candidate(install_id) - RANGE_START;
    for step in 0..RANGE_LEN {
        let base = RANGE_START + (first + step) % RANGE_LEN;
        let Some(block) = PortBlock::starting_at(base) else { continue };
        if block.ports().all(|p| !in_use.contains(&p)) {
            return Ok(Allocation { block, source: PortSource::Allocated });
        }
    }
    Err(PortError::Exhausted)
}
