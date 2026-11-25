//! The RFD 0166 replay harness (rows U2, W1, B1): given the trees of consecutive published
//! artifacts, oldest first, print what `cas/1` moves against today's whole-archive download.
//!
//! `cas-replay [--archive-bytes N]... DIR...` hashes each DIR into a manifest and, for every
//! consecutive pair and for the oldest against the newest (N-k to N), prints one JSON line:
//! `{from, to, full, want_raw, want_wire, ranges, range_bytes, ms}`. `full` is the archive a
//! client downloads today (its `--archive-bytes`, in DIR order, else the tree's size), `want_wire`
//! the compressed chunk files a client holding `from` lacks, and `range_bytes` what Range GETs
//! on one pack of the newest tree read for them (wants coalesced under [`pack::GAP`]). No
//! network: every number comes from the trees on disk.

use cmux_cas::manifest::Manifest;
use cmux_cas::{Id, Result, pack, plan, store};
use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::path::PathBuf;
use std::time::Instant;

fn main() -> Result<()> {
    let mut dirs = Vec::new();
    let mut full = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--archive-bytes" {
            full.push(args.next().ok_or("--archive-bytes needs a number")?.parse::<u64>()?);
        } else {
            dirs.push(PathBuf::from(a));
        }
    }
    if dirs.len() < 2 {
        return Err("usage: cas-replay [--archive-bytes N]... DIR DIR...".into());
    }
    let mut wire: HashMap<Id, u64> = HashMap::new();
    let mut ms = Vec::new();
    for dir in &dirs {
        let t = Instant::now();
        let m = Manifest::of_dir(dir, |id, bytes| {
            if let Entry::Vacant(e) = wire.entry(id) {
                e.insert(store::encode(bytes, store::LEVEL)?.len() as u64);
            }
            Ok(())
        })?;
        ms.push((m, t.elapsed().as_millis()));
    }
    let row = |from: usize, to: usize| -> Result<()> {
        let (next, t) = &ms[to];
        let want = plan::want_after(next, &[&ms[from].0]);
        let want_raw: u64 = want.iter().map(|c| u64::from(c.len)).sum();
        let want_wire: u64 = want.iter().map(|c| wire[&c.id]).sum();
        // One pack of the newest tree's chunks, in manifest order, as the floor would publish it.
        let mut placed = 0u64;
        let mut idx = pack::Index { pack: Some(next.id()?), entries: Vec::new() };
        for c in next.distinct_chunks() {
            let len = wire[&c.id];
            idx.entries.push(pack::Entry { id: c.id, offset: placed, len: u32::try_from(len)? });
            placed += len;
        }
        let (ranges, missing) = pack::ranges(&[idx], &want, pack::GAP);
        assert!(missing.is_empty());
        let range_bytes: u64 = ranges.iter().map(pack::Range::len).sum();
        let full = full.get(to).copied().unwrap_or_else(|| next.size());
        println!(
            "{}",
            serde_json::json!({
                "from": dirs[from], "to": dirs[to], "full": full, "tree": next.size(),
                "want_raw": want_raw, "want_wire": want_wire, "ranges": ranges.len(),
                "range_bytes": range_bytes, "pct_of_full": (range_bytes as f64) * 100.0 / (full as f64),
                "ms": t,
            })
        );
        Ok(())
    };
    for i in 1..dirs.len() {
        row(i - 1, i)?;
    }
    if dirs.len() > 2 {
        row(0, dirs.len() - 1)?;
    }
    Ok(())
}
