//! Which encoding each chunk gets.
//!
//! In order: a chunk the receiver holds goes as a reference; a compressed
//! kind or a high-entropy chunk is stored without a compressor pass; the
//! rest get zstd at the highest level whose throughput, across the cores
//! doing it, still outruns the link by `cpu_headroom` (so compression never
//! becomes the bottleneck), with a dictionary for small chunks of a kind
//! that has one.

use crate::cas::{self, Have};
use crate::classify::Kind;
use crate::dict::Trained;
use crate::entropy;
use crate::frame::Encoding;
use crate::params::Params;

/// What the sender knows about the link and itself.
#[derive(Clone, Copy, Debug)]
pub struct Link {
    /// Measured or probed goodput, bytes per second.
    pub bytes_per_sec: f64,
    /// Round-trip time, seconds.
    pub rtt: f64,
    /// Cores the sender may spend on compression.
    pub cores: usize,
}

/// Approximate single-core zstd compression throughput on source-like data, bytes/s, by level.
/// From `cmux-bytes bench-levels` on gcp-agent-lane-12 (n2 class); the harness re-measures it.
pub fn zstd_speed(level: i32) -> f64 {
    const MB: f64 = 1e6;
    // Measured with `cmux-bytes bench-levels` on a 106 MB source tree, one core of a GCP lane VM
    // (2026-11-25); a level between two measured ones takes the slower.
    match level {
        i32::MIN..=1 => 330.0 * MB,
        2 => 290.0 * MB,
        3 => 250.0 * MB,
        4 => 230.0 * MB,
        5 => 140.0 * MB,
        6 => 100.0 * MB,
        7 => 85.0 * MB,
        8 => 67.0 * MB,
        9 => 62.0 * MB,
        10..=12 => 30.0 * MB,
        13..=15 => 6.4 * MB,
        16..=17 => 4.0 * MB,
        18..=19 => 2.4 * MB,
        _ => 1.5 * MB,
    }
}

/// Compressed/raw per zstd level, from the same `bench-levels` run as `zstd_speed` (source text;
/// only the shape matters: each level against its neighbours).
pub fn zstd_ratio(level: i32) -> f64 {
    match level {
        i32::MIN..=1 => 0.335,
        2 => 0.315,
        3 => 0.299,
        4 => 0.296,
        5 => 0.282,
        6 => 0.272,
        7 => 0.267,
        8 => 0.265,
        9 => 0.261,
        10..=12 => 0.256,
        13..=15 => 0.249,
        16..=17 => 0.234,
        _ => 0.229,
    }
}

/// The zstd level for `link`: the one that moves raw bytes fastest through the pipeline, which is
/// the slower of compression on `cores` (derated by `cpu_headroom`) and the link carrying the
/// compressed bytes. Among levels within 2% of the best rate the highest wins (fewer bytes for
/// the same time), so a LAN gets a fast level and a slow link a strong one.
pub fn level_for(link: &Link, params: &Params) -> i32 {
    let cores = link.cores.max(1) as f64;
    let rate = |l: i32| {
        (zstd_speed(l) * cores / params.cpu_headroom).min(link.bytes_per_sec / zstd_ratio(l))
    };
    let levels = params.min_level..=params.max_level;
    let best = levels.clone().map(rate).fold(0.0, f64::max);
    levels.rev().find(|l| rate(*l) >= best * 0.98).unwrap_or(params.min_level)
}

/// The decision for one chunk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plan {
    pub encoding: Encoding,
    /// Why, for the harness's breakdown.
    pub reason: Reason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    Have,
    CompressedKind,
    HighEntropy,
    Dictionary,
    Compress,
    Tiny,
}

pub fn plan_chunk(
    chunk: &[u8],
    kind: Kind,
    have: &Have,
    hash: &cas::Hash,
    level: i32,
    dicts: &Trained,
    params: &Params,
) -> Plan {
    if chunk.len() >= cas::MIN_REF_BYTES && have.contains(hash) {
        return Plan { encoding: Encoding::Ref, reason: Reason::Have };
    }
    if chunk.len() < 64 {
        return Plan { encoding: Encoding::Store, reason: Reason::Tiny };
    }
    if kind == Kind::Compressed {
        return Plan { encoding: Encoding::Store, reason: Reason::CompressedKind };
    }
    if entropy::bits_per_byte(chunk, params.entropy_sample) >= params.entropy_store_bits {
        return Plan { encoding: Encoding::Store, reason: Reason::HighEntropy };
    }
    if params.dictionaries
        && chunk.len() <= params.dict_max_chunk
        && let Some(id) = dicts.for_kind(kind)
    {
        return Plan { encoding: Encoding::ZstdDict(level, id), reason: Reason::Dictionary };
    }
    Plan { encoding: Encoding::Zstd(level), reason: Reason::Compress }
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
