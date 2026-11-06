//! Scratch probe (never merge): one stderr line per journal append, write and sync.
use std::sync::atomic::{AtomicU32, Ordering};

pub(crate) fn line(args: std::fmt::Arguments<'_>) {
    static N: AtomicU32 = AtomicU32::new(0);
    if N.fetch_add(1, Ordering::Relaxed) < 4_000 {
        let us = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_micros());
        eprintln!("ACPMUX-PERF-PROBE {us} {args}");
    }
}
