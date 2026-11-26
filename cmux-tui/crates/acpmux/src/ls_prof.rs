//! TEMP local profiling (not for commit).
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Instant;
pub static S: [AtomicU64; 12] = [const { AtomicU64::new(0) }; 12];
pub fn on() -> bool { std::env::var_os("ACPMUX_LS_PROF").is_some() }
pub fn add(i: usize, t: Instant) { S[i].fetch_add(t.elapsed().as_micros() as u64, Relaxed); }
pub fn inc(i: usize, n: u64) { S[i].fetch_add(n, Relaxed); }
pub fn dump(tag: &str) {
    let p = "/tmp/acpmux-ls-prof.log"; if !std::path::Path::new(p).exists() { return; }
    let v: Vec<u64> = S.iter().map(|a| a.swap(0, Relaxed)).collect();
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(p) {
        let _ = writeln!(f, "{tag} {v:?}");
    }
}
