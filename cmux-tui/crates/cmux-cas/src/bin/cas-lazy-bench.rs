//! Measurement harness for the C2 lazy restore (`cmux_cas::lazy`).
//!
//! `cas-lazy-bench --dir WORK [--size-gib 20] [--file-mib 16] [--samples 200] [--rtt-ms 0]
//! [--link-mib-s 70] [--streams 4] [--floor-gib 100] [--keep]` builds a synthetic tree of about `--size-gib` (three quarters
//! unique noise, a quarter repeats from a small pool, so dedup and the manifest shape are
//! realistic) into zstd-1 packs under WORK, then measures against an empty store:
//!
//! * `list_stat_us`: a directory listing plus a stat, answered from the manifest, no fetch;
//! * `first_read_ms` p50/p95/max: the first 4 KiB read of `--samples` random files, each a cold
//!   file (one coalesced Range GET on a pack, `--rtt-ms` added per request to model a link);
//! * `full_restore_s`: prefetch the whole tree in manifest order (64 MiB batches, `--streams`
//!   at once) into a fresh store, then `verify_s`: re-hash every file against its manifest entry.
//!
//! Both are measured twice on the same packs: `local` (no added cost per request) and `link`
//! (`--rtt-ms` per request plus `--link-mib-s` per stream, the design doc's paused-VM figures).
//!
//! It refuses to start unless free space after the build and the restore store (2x the tree)
//! stays above `--floor-gib`. Prints one JSON line. Nothing is deleted except WORK's own build
//! output, and only without `--keep`.

use cmux_cas::lazy::{DirSource, Lazy};
use cmux_cas::manifest::{self, File, Manifest};
use cmux_cas::{Id, Result, Store, cdc, pack, store};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn noise(n: usize, seed: u64) -> Vec<u8> {
    let mut s = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    let mut out = Vec::with_capacity(n);
    while out.len() < n {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        out.extend_from_slice(&s.to_le_bytes());
    }
    out.truncate(n);
    out
}

fn free_bytes(dir: &Path) -> Result<u64> {
    let out = std::process::Command::new("df").args(["--output=avail", "-B1"]).arg(dir).output()?;
    let text = String::from_utf8(out.stdout)?;
    Ok(text.lines().nth(1).ok_or("df printed nothing")?.trim().parse()?)
}

fn arg<T: std::str::FromStr>(args: &[String], name: &str, default: T) -> Result<T> {
    match args.iter().position(|a| a == name) {
        Some(i) => args
            .get(i + 1)
            .ok_or(format!("{name} needs a value"))?
            .parse()
            .map_err(|_| format!("bad {name}").into()),
        None => Ok(default),
    }
}

fn pct(sorted: &[f64], p: f64) -> f64 {
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let work: PathBuf = arg(&args, "--dir", PathBuf::new())?;
    if work.as_os_str().is_empty() {
        return Err("usage: cas-lazy-bench --dir WORK [--size-gib N] ...".into());
    }
    let size_gib: f64 = arg(&args, "--size-gib", 20.0)?;
    let file_mib: usize = arg(&args, "--file-mib", 16)?;
    let samples: usize = arg(&args, "--samples", 200)?;
    let rtt_ms: u64 = arg(&args, "--rtt-ms", 0)?;
    let floor_gib: f64 = arg(&args, "--floor-gib", 100.0)?;
    let keep = args.iter().any(|a| a == "--keep");
    let link_mib_s: f64 = arg(&args, "--link-mib-s", 70.0)?;
    let streams: usize = arg(&args, "--streams", 4)?;
    let total = (size_gib * (1u64 << 30) as f64) as u64;
    std::fs::create_dir_all(&work)?;
    let free = free_bytes(&work)?;
    let need = 2 * total + (floor_gib * (1u64 << 30) as f64) as u64;
    if free < need {
        return Err(format!("{free} bytes free; need {need} (2x tree + floor)").into());
    }
    let packs = work.join("packs");
    std::fs::create_dir_all(&packs)?;

    // Build: files of file_mib, chunked, framed into ~256 MiB packs.
    let t = Instant::now();
    let nfiles = usize::try_from(total / ((file_mib as u64) << 20))?.max(1);
    let (mut files, mut indexes) = (Vec::with_capacity(nfiles), Vec::new());
    let mut seen = HashSet::new();
    let mut w = pack::Writer::default();
    let mut pending = 0usize;
    let flush = |w: &mut pack::Writer, indexes: &mut Vec<pack::Index>| -> Result<()> {
        let (bytes, idx) = std::mem::take(w).finish();
        if !idx.entries.is_empty() {
            std::fs::write(packs.join(format!("{}.pack", idx.pack.ok_or("no id")?.hex())), bytes)?;
            indexes.push(idx);
        }
        Ok(())
    };
    for i in 0..nfiles {
        let n = file_mib << 20;
        let data =
            if i % 4 == 3 { noise(n, (i % 8) as u64 + 1_000_000) } else { noise(n, i as u64) };
        let mut chunks = Vec::new();
        for (at, len) in cdc::chunks(&data) {
            let piece = &data[at..at + len];
            let id = Id::of(piece);
            if seen.insert(id) {
                let f = store::encode(piece, 1)?;
                pending += f.len();
                w.push(id, &f)?;
            }
            chunks.push(manifest::Chunk { id, len: u32::try_from(len)? });
        }
        files.push(File {
            path: format!("d{:03}/s{:02}/f{i:06}.bin", i % 64, i % 16),
            exec: false,
            size: n as u64,
            hash: Id::of(&data),
            chunks,
        });
        if pending >= 256 << 20 {
            flush(&mut w, &mut indexes)?;
            pending = 0;
        }
    }
    flush(&mut w, &mut indexes)?;
    files.sort_by(|a, b| a.path.cmp(&b.path));
    let m = Manifest { schema: manifest::SCHEMA, files };
    let build_s = t.elapsed().as_secs_f64();
    let pack_bytes: u64 =
        indexes.iter().flat_map(|i| i.entries.iter()).map(|e| u64::from(e.len)).sum();
    let distinct = m.distinct_chunks().len();

    let mut profiles = Vec::new();
    for (name, rtt, mib_s) in [("local", 0u64, 0.0f64), ("link", rtt_ms, link_mib_s)] {
        profiles.push(measure(name, &m, &indexes, &packs, &work, rtt, mib_s, samples, streams)?);
    }
    println!(
        "{}",
        serde_json::json!({
            "tree_bytes": m.size(), "files": m.files.len(), "distinct_chunks": distinct,
            "pack_bytes": pack_bytes, "packs": indexes.len(), "build_s": build_s,
            "streams": streams, "profiles": profiles,
        })
    );
    if !keep {
        // Only what this run made.
        std::fs::remove_dir_all(&packs)?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn measure(
    name: &str,
    m: &Manifest,
    indexes: &[pack::Index],
    packs: &Path,
    work: &Path,
    rtt_ms: u64,
    mib_s: f64,
    samples: usize,
    streams: usize,
) -> Result<serde_json::Value> {
    use std::sync::atomic::Ordering::Relaxed;
    let src = || DirSource {
        dir: packs.to_path_buf(),
        rtt: Duration::from_millis(rtt_ms),
        bytes_per_s: (mib_s * 1048576.0) as u64,
    };

    // Listing and stat on an empty store: manifest only.
    let store_a = work.join(format!("store-{name}-a"));
    let lazy = Lazy::new(m.clone(), indexes.to_vec(), Store::new(&store_a), src());
    let t = Instant::now();
    let mut listed = 0;
    for _ in 0..1000 {
        listed += lazy.list("d000").map_or(0, |l| l.len());
        let _ = lazy.stat(&m.files[m.files.len() / 2].path);
    }
    let list_stat_us = t.elapsed().as_secs_f64() * 1e6 / 1000.0;
    if lazy.stats().requests.load(Relaxed) != 0 {
        return Err("list/stat fetched".into());
    }

    // First 4 KiB read of `samples` distinct cold files at random offsets.
    let mut s = 0x2545_F491_4F6C_DD1Du64;
    let mut rnd = || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    };
    let mut order: Vec<usize> = (0..m.files.len()).collect();
    for i in (1..order.len()).rev() {
        order.swap(i, (rnd() % (i as u64 + 1)) as usize);
    }
    let mut lat = Vec::new();
    for &i in order.iter().take(samples) {
        let f = &m.files[i];
        let off = rnd() % (f.size - 4096);
        let t = Instant::now();
        let got = lazy.read(&f.path, off, 4096)?;
        lat.push(t.elapsed().as_secs_f64() * 1e3);
        if got.len() != 4096 {
            return Err("short read".into());
        }
    }
    lat.sort_by(f64::total_cmp);
    let first_wire = lazy.stats().wire_bytes.load(Relaxed) / lat.len().max(1) as u64;
    drop(lazy);
    std::fs::remove_dir_all(&store_a)?;

    // Full restore into a fresh store on `streams` streams, then verify every file.
    let store_b = work.join(format!("store-{name}-b"));
    let full = Lazy::new(m.clone(), indexes.to_vec(), Store::new(&store_b), src());
    let t = Instant::now();
    full.prefetch_all(streams, 64 << 20)?;
    let full_restore_s = t.elapsed().as_secs_f64();
    let t = Instant::now();
    for f in &m.files {
        full.verify(&f.path)?;
    }
    let verify_s = t.elapsed().as_secs_f64();
    let v = serde_json::json!({
        "profile": name, "rtt_ms": rtt_ms, "mib_s_per_stream": mib_s,
        "list_stat_us": list_stat_us, "listed": listed,
        "first_read_samples": lat.len(), "first_read_ms_p50": pct(&lat, 0.5),
        "first_read_ms_p95": pct(&lat, 0.95), "first_read_ms_max": pct(&lat, 1.0),
        "first_read_wire_bytes": first_wire,
        "full_restore_s": full_restore_s,
        "full_restore_mib_s": m.size() as f64 / 1048576.0 / full_restore_s,
        "full_restore_requests": full.stats().requests.load(Relaxed),
        "full_restore_wire_bytes": full.stats().wire_bytes.load(Relaxed),
        "verify_s": verify_s,
    });
    eprintln!("{v}");
    drop(full);
    std::fs::remove_dir_all(&store_b)?;
    Ok(v)
}
