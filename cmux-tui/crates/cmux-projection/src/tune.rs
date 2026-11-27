//! The transport knobs a hill climb turns (`scripts/measure/projection-scale/hillclimb.py`).
//!
//! Each knob reads its environment variable once per process. Unset, unparsable or out of range
//! keeps the shipped default, so nothing changes unless a run sets one. The climb measures a
//! tree and a link profile under each setting and keeps the fastest; a winner becomes the new
//! default in its own PR, with the climb's numbers.

use std::sync::OnceLock;

use crate::wire;

/// The zstd level of a packed answer ([`wire::ZSTD_LEVEL`] by default). `0` sends answers raw;
/// negative levels are zstd's fast levels.
pub const ZSTD_LEVEL_VAR: &str = "CMUX_PROJECTION_ZSTD_LEVEL";
/// The most files one read-ahead batch asks for, the faulting file included. `1` turns
/// read-ahead off.
pub const READAHEAD_FILES_VAR: &str = "CMUX_PROJECTION_READAHEAD_FILES";
/// The most bytes one read-ahead batch asks for, the faulting file included.
pub const READAHEAD_BYTES_VAR: &str = "CMUX_PROJECTION_READAHEAD_BYTES";

/// The shipped read-ahead caps.
pub const DEFAULT_READAHEAD_FILES: usize = 256;
pub const DEFAULT_READAHEAD_BYTES: u64 = 16 * 1024 * 1024;

fn read<T: std::str::FromStr + Copy>(
    cell: &OnceLock<T>,
    var: &str,
    default: T,
    ok: impl Fn(T) -> bool,
) -> T {
    *cell.get_or_init(|| parse(std::env::var(var).ok().as_deref(), default, ok))
}

fn parse<T: std::str::FromStr + Copy>(raw: Option<&str>, default: T, ok: impl Fn(T) -> bool) -> T {
    raw.and_then(|s| s.trim().parse::<T>().ok()).filter(|v| ok(*v)).unwrap_or(default)
}

fn level_ok(level: i32) -> bool {
    (-7..=22).contains(&level)
}

fn files_ok(files: usize) -> bool {
    (1..=wire::MAX_BATCH as usize).contains(&files)
}

fn bytes_ok(bytes: u64) -> bool {
    (1..=wire::MAX_ANSWER / 2).contains(&bytes)
}

/// The zstd level packed answers use now; `0` means raw.
pub fn zstd_level() -> i32 {
    static CELL: OnceLock<i32> = OnceLock::new();
    read(&CELL, ZSTD_LEVEL_VAR, wire::ZSTD_LEVEL, level_ok)
}

/// The read-ahead file cap now.
pub fn readahead_files() -> usize {
    static CELL: OnceLock<usize> = OnceLock::new();
    read(&CELL, READAHEAD_FILES_VAR, DEFAULT_READAHEAD_FILES, files_ok)
}

/// The read-ahead byte cap now.
pub fn readahead_bytes() -> u64 {
    static CELL: OnceLock<u64> = OnceLock::new();
    read(&CELL, READAHEAD_BYTES_VAR, DEFAULT_READAHEAD_BYTES, bytes_ok)
}

#[cfg(test)]
#[path = "tune_tests.rs"]
mod tests;
