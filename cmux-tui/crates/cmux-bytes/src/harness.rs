//! The bytes-path harness: real folders, real codec CPU on both ends, and a
//! link model per network profile. One run of a (folder, scenario, profile,
//! strategy) gives time to the first agent turn, time to fully synced, bytes
//! on the wire, and CPU on each end.
//!
//! The codec work is real: every file is read, chunked, compressed and then
//! decoded again on the "receiver" and compared with the original, so a
//! harness run is also a round-trip check and a never-grows check. The link
//! is a model (bandwidth, RTT, loss, per-stream TCP ceiling): CPU is
//! measured, wire time is computed. `netns` validation of the model runs
//! separately (`cmux-bytes netcheck`).

use std::collections::HashMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use base64::Engine as _;

use crate::cas::{self, Have};
use crate::cdc::Chunker;
use crate::classify::{self, Kind};
use crate::dict::Trained;
use crate::frame::{self, Decoded, Encoding};
use crate::order::{self, Entry};
use crate::params::Params;
use crate::policy::{self, Link};

/// This thread's CPU time, seconds: the codec cost measured this way does not grow when other
/// work shares the machine, so two hill-climb runs compare like for like.
pub fn cpu_now() -> f64 {
    let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `t` is a valid out-pointer; CLOCK_THREAD_CPUTIME_ID is always available on Linux and macOS.
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut t) };
    t.tv_sec as f64 + t.tv_nsec as f64 * 1e-9
}

struct Clock(f64);

impl Clock {
    fn start() -> Self {
        Self(cpu_now())
    }
    fn secs(&self) -> f64 {
        cpu_now() - self.0
    }
}

/// A network profile.
#[derive(Clone, Copy, Debug)]
pub struct Profile {
    pub name: &'static str,
    /// Uplink, bytes per second (the Mac's upload is the bottleneck).
    pub bandwidth: f64,
    pub rtt: f64,
    pub loss: f64,
}

pub const PROFILES: [Profile; 4] = [
    Profile { name: "lan", bandwidth: 117e6, rtt: 0.001, loss: 0.0 },
    Profile { name: "home-wifi", bandwidth: 5e6, rtt: 0.025, loss: 0.001 },
    Profile { name: "lossy", bandwidth: 1.25e6, rtt: 0.080, loss: 0.02 },
    Profile { name: "tailnet-xregion", bandwidth: 25e6, rtt: 0.150, loss: 0.0005 },
];

pub fn profile(name: &str) -> Option<Profile> {
    PROFILES.iter().copied().find(|p| p.name == name)
}

/// One TCP stream's ceiling: the receive window over RTT, and Mathis et al.
/// (MSS/RTT * 1.22/sqrt(loss)) when the link drops packets.
pub fn tcp_stream_ceiling(p: &Profile) -> f64 {
    let window = 4.0 * 1024.0 * 1024.0;
    let by_window = window / p.rtt.max(1e-4);
    if p.loss <= 0.0 {
        return by_window;
    }
    by_window.min(1448.0 * 1.22 / (p.rtt * p.loss.sqrt()))
}

/// A loss-tolerant (BBR-style, Braid RFD 0164 D-class 3) stream: paced at the
/// probed rate, losing only the dropped packets.
pub fn paced_stream_ceiling(p: &Profile) -> f64 {
    p.bandwidth * (1.0 - p.loss)
}

/// Which strategy sends the bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Strategy {
    /// What `cmux link sync` does on feat-cmux-next today: 8 connections, small files 32 per
    /// round trip, a large file one 8 MiB part per round trip, deflate-3 after a 64 KiB
    /// probe, base64 in JSON lines, dedup by path only, the agent starts once the copy ends.
    Today,
    /// This crate: manifest first, then the first-turn files, then the fill, CDC chunks
    /// deduped by hash, a per-chunk codec choice, raw binary frames, pipelined streams.
    New,
}

impl Strategy {
    pub fn name(self) -> &'static str {
        match self {
            Strategy::Today => "today",
            Strategy::New => "new",
        }
    }
}

/// What a folder's codec pass produced, before the link is applied.
#[derive(Clone, Debug, Default)]
pub struct Encoded {
    pub files: u64,
    pub dirs: u64,
    pub raw_bytes: u64,
    /// Work items in send order; each is one request (today) or a run of frames (new).
    pub items: Vec<Item>,
    /// Bytes of payload that grew past raw (must stay 0 for New).
    pub grown_bytes: u64,
    /// Largest (wire - raw) over any one payload.
    pub worst_growth: i64,
    pub reasons: HashMap<&'static str, u64>,
    pub dict_bytes: u64,
    pub verify_failures: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Item {
    pub wire_up: u64,
    pub wire_down: u64,
    pub cpu_send: f64,
    pub cpu_recv: f64,
    /// Waits for its answer before the connection sends the next item.
    pub round_trip: bool,
    /// Needed for the first agent turn (manifest, instructions).
    pub first_turn: bool,
    /// Trains the dictionaries: chunks that use one wait for it to finish.
    pub trains_dicts: bool,
    /// Holds a chunk compressed with a dictionary.
    pub needs_dicts: bool,
}

/// A scenario over a folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scenario {
    /// The VM has nothing.
    Cold,
    /// The VM has the folder as it was; 2% of files were edited (16 bytes inserted mid-file).
    Edit,
}

impl Scenario {
    pub fn name(self) -> &'static str {
        match self {
            Scenario::Cold => "cold",
            Scenario::Edit => "edit",
        }
    }
}

/// A file read for the harness.
struct File {
    bytes: Vec<u8>,
}

/// Lists `root` (no symlinks followed), up to `cap` bytes of file content in fill order.
pub fn walk(root: &Path, cap: u64) -> (Vec<Entry>, u64, u64) {
    let mut entries = Vec::new();
    let mut dirs = 0u64;
    let mut stack = vec![PathBuf::new()];
    let now = std::time::SystemTime::now();
    while let Some(rel) = stack.pop() {
        let Ok(read) = std::fs::read_dir(root.join(&rel)) else { continue };
        dirs += 1;
        for e in read.flatten() {
            let Ok(meta) = e.metadata() else { continue };
            let name = rel.join(e.file_name());
            if meta.is_dir() {
                stack.push(name);
            } else if meta.is_file() {
                let age = meta
                    .modified()
                    .ok()
                    .and_then(|m| now.duration_since(m).ok())
                    .map(|d| d.as_secs());
                entries.push(Entry {
                    path: name.to_string_lossy().into_owned(),
                    size: meta.len(),
                    age_secs: age,
                });
            }
        }
    }
    order::fill_order(&mut entries);
    let mut total = 0u64;
    entries.retain(|e| {
        if total >= cap {
            return false;
        }
        total += e.size;
        true
    });
    (entries, dirs, total)
}

fn read_file(root: &Path, entry: &Entry) -> Option<File> {
    let path = root.join(&entry.path);
    let mut f = std::fs::File::open(&path).ok()?;
    let mut bytes = Vec::with_capacity(entry.size as usize);
    f.read_to_end(&mut bytes).ok()?;
    Some(File { bytes })
}

/// The deterministic edit the Edit scenario applies to about 2% of files.
/// Whether the edit scenario changes this file (about 2%, by path, files of 64 bytes or more).
fn is_edited(path: &str, size: u64) -> bool {
    blake3::hash(path.as_bytes()).as_bytes()[0] <= 5 && size >= 64
}

fn edited(path: &str, bytes: &[u8]) -> Option<Vec<u8>> {
    if !is_edited(path, bytes.len() as u64) {
        return None;
    }
    let mut out = bytes.to_vec();
    let at = bytes.len() / 2;
    out.splice(at..at, *b"/* cmux edit */\n");
    Some(out)
}

fn is_first_turn(entry: &Entry) -> bool {
    order::heat(entry) < 10
}

/// Today's codec pass: what `remote.rs` + `small_writes.rs` send.
pub fn encode_today(
    root: &Path,
    entries: &[Entry],
    scenario: Scenario,
    prefix_len: usize,
) -> Encoded {
    const BATCH_FILES: usize = 32;
    const BATCH_BYTES: u64 = 1 << 20;
    const PART: usize = 8 << 20;
    const PROBE: usize = 64 * 1024;
    let mut out = Encoded::default();
    let deflate = |b: &[u8]| {
        use std::io::Write as _;
        let mut e = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::new(3));
        // Writing to a Vec cannot fail; an empty result would show as a verify failure.
        e.write_all(b).and_then(|()| e.finish()).unwrap_or_default()
    };
    let inflate = |b: &[u8]| {
        let mut d = flate2::read::DeflateDecoder::new(b);
        let mut o = Vec::new();
        // A failed inflate leaves a short buffer, which the round-trip check counts.
        let _ = d.read_to_end(&mut o);
        o
    };
    let b64 = base64::engine::general_purpose::STANDARD;
    // Today lists the machine's folder (1,000 entries a page) and makes folders (256 a batch).
    let listing_pages = (entries.len() as u64).div_ceil(1000).max(1);
    for _ in 0..listing_pages {
        out.items.push(Item {
            wire_up: 120,
            wire_down: 1000 * 160,
            round_trip: true,
            ..Item::default()
        });
    }
    let mut batch = Item { round_trip: true, ..Item::default() };
    let mut batch_files = 0usize;
    let mut batch_bytes = 0u64;
    for entry in entries {
        let Some(file) = read_file(root, entry) else { continue };
        out.files += 1;
        let bytes = match scenario {
            Scenario::Cold => file.bytes,
            // Today skips an unchanged path (manifest compare) and sends an edited one whole.
            Scenario::Edit => match edited(&entry.path, &file.bytes) {
                Some(b) => b,
                None => continue,
            },
        };
        out.raw_bytes += bytes.len() as u64;
        let request_overhead = 170 + (prefix_len + entry.path.len()) as u64;
        let answer = 150 + (prefix_len + entry.path.len()) as u64;
        let parts: Vec<&[u8]> =
            if bytes.is_empty() { vec![&[][..]] } else { bytes.chunks(PART).collect() };
        let t = Clock::start();
        let probe_shrinks = {
            let p = bytes.get(..bytes.len().min(PROBE)).unwrap_or_default();
            let w = deflate(p);
            w.len() + 64 < p.len() && w.len() * 10 < p.len() * 9
        };
        let mut wires = Vec::new();
        for part in &parts {
            let payload = if probe_shrinks {
                let d = deflate(part);
                if d.len() < part.len() { (d, true) } else { (part.to_vec(), false) }
            } else {
                (part.to_vec(), false)
            };
            let text = b64.encode(&payload.0);
            wires.push((text, payload.1, part.len()));
        }
        let cpu_send = t.secs();
        let t = Clock::start();
        let mut back = Vec::with_capacity(bytes.len());
        for (text, deflated, _) in &wires {
            let raw = b64.decode(text).unwrap_or_default();
            if *deflated { back.extend(inflate(&raw)) } else { back.extend(raw) }
        }
        let cpu_recv = t.secs();
        if back != bytes {
            out.verify_failures += 1;
        }
        let wire: u64 = wires.iter().map(|w| w.0.len() as u64).sum::<u64>()
            + request_overhead * parts.len() as u64;
        let growth = wire as i64 - bytes.len() as i64;
        if growth > 0 {
            out.grown_bytes += growth as u64;
        }
        out.worst_growth = out.worst_growth.max(growth);
        *out.reasons.entry(if probe_shrinks { "deflate" } else { "base64" }).or_default() +=
            bytes.len() as u64;
        if bytes.len() <= PART
            && (batch_files < BATCH_FILES)
            && batch_bytes + bytes.len() as u64 <= BATCH_BYTES
        {
            batch.wire_up += wire;
            batch.wire_down += answer;
            batch.cpu_send += cpu_send;
            batch.cpu_recv += cpu_recv;
            batch_files += 1;
            batch_bytes += bytes.len() as u64;
            continue;
        }
        if batch_files > 0 {
            out.items
                .push(std::mem::replace(&mut batch, Item { round_trip: true, ..Item::default() }));
            batch_files = 0;
            batch_bytes = 0;
        }
        if bytes.len() as u64 <= BATCH_BYTES {
            batch = Item {
                wire_up: wire,
                wire_down: answer,
                cpu_send,
                cpu_recv,
                round_trip: true,
                first_turn: false,
                ..Item::default()
            };
            batch_files = 1;
            batch_bytes = bytes.len() as u64;
        } else {
            // A large file: one round trip per part, plus a stat, a delete and a rename.
            let n = parts.len() as u64;
            for i in 0..n {
                out.items.push(Item {
                    wire_up: wire / n,
                    wire_down: answer,
                    cpu_send: cpu_send / n as f64,
                    cpu_recv: cpu_recv / n as f64,
                    round_trip: true,
                    first_turn: false,
                    ..Item::default()
                });
                let _ = i;
            }
            if n > 1 {
                for _ in 0..3 {
                    out.items.push(Item {
                        wire_up: 200,
                        wire_down: 200,
                        round_trip: true,
                        ..Item::default()
                    });
                }
            }
        }
    }
    if batch_files > 0 {
        out.items.push(batch);
    }
    out
}

/// The new codec pass.
pub fn encode_new(
    root: &Path,
    entries: &[Entry],
    scenario: Scenario,
    params: &Params,
    link: &Link,
) -> Encoded {
    let mut out = Encoded::default();
    let chunker = Chunker::new(params.cdc_avg);
    let level = policy::level_for(link, params);
    // Dictionaries: trained on a sample of the folder's small files (read once more; counted as
    // sender CPU, and the dictionaries count as wire bytes).
    let t = Clock::start();
    // On an edit the remote already holds the dictionaries (trained on the cold copy): reuse them,
    // and send neither them nor their training again.
    let dicts = if params.dictionaries && link.bytes_per_sec <= params.dict_max_bandwidth {
        let mut samples: Vec<(Kind, Vec<u8>)> = Vec::new();
        for e in entries
            .iter()
            .filter(|e| e.size > 0 && e.size <= params.dict_max_chunk as u64)
            .step_by(3)
            .take(6000)
        {
            if let Some(f) = read_file(root, e) {
                let kind = classify::classify(&e.path, &f.bytes);
                samples.push((kind, f.bytes));
            }
        }
        Trained::train(samples.iter().map(|(k, b)| (*k, b.as_slice())), params.dict_bytes)
    } else {
        Trained::default()
    };
    let dict_cpu = if scenario == Scenario::Edit { 0.0 } else { t.secs() };
    out.dict_bytes = if scenario == Scenario::Edit { 0 } else { dicts.wire_bytes() };

    // The manifest: per file a path, size, mode and mtime. It gates the first turn, so it takes the
    // link's level like any chunk: zstd-19 on a 46,784-file manifest cost 1.5 s of CPU, longer than a
    // LAN takes to send the whole folder.
    let t = Clock::start();
    let mut manifest = Vec::new();
    // An edit's manifest holds only the changed entries (the remote has the rest).
    let changed = |e: &Entry| scenario == Scenario::Cold || is_edited(&e.path, e.size);
    for e in entries.iter().filter(|e| changed(e)) {
        manifest.extend_from_slice(e.path.as_bytes());
        manifest.push(0);
        manifest.extend_from_slice(&e.size.to_le_bytes());
        manifest.extend_from_slice(&[0; 8]);
    }
    let (mframe, _) = frame::encode(&manifest, Encoding::Zstd(level), params.keep_ratio, &());
    let mcpu = t.secs();
    out.items.push(Item {
        wire_up: mframe.len() as u64 + 64,
        wire_down: 64,
        cpu_send: mcpu,
        cpu_recv: 0.0,
        round_trip: false,
        first_turn: true,
        ..Item::default()
    });
    // Dictionaries train beside the first-turn files (which go without one) and ride the fill.
    if out.dict_bytes > 0 {
        out.items.push(Item {
            wire_up: out.dict_bytes,
            wire_down: 16,
            cpu_send: dict_cpu,
            trains_dicts: true,
            ..Item::default()
        });
    }

    let mut have = Have::default();
    let mut store: HashMap<cas::Hash, ()> = HashMap::new();
    // A run of frames for one file, cut into items of about 1 MiB so streams share them.
    for entry in entries {
        let Some(file) = read_file(root, entry) else { continue };
        out.files += 1;
        let first_turn = is_first_turn(entry);
        let bytes = match scenario {
            Scenario::Cold => file.bytes,
            Scenario::Edit => {
                // The VM holds the original: its chunks are in `have`.
                for (o, l) in chunker.chunks(&file.bytes) {
                    let h = cas::hash(file.bytes.get(o..o + l).unwrap_or_default());
                    have.insert(h);
                    store.insert(h, ());
                }
                match edited(&entry.path, &file.bytes) {
                    Some(b) => b,
                    None => continue,
                }
            }
        };
        out.raw_bytes += bytes.len() as u64;
        let kind =
            classify::classify(&entry.path, bytes.get(..bytes.len().min(4096)).unwrap_or_default());
        let mut item =
            Item { first_turn, wire_up: 12 + entry.path.len().min(16) as u64, ..Item::default() };
        let chunks = if bytes.is_empty() { vec![(0, 0)] } else { chunker.chunks(&bytes) };
        for (o, l) in chunks {
            let raw = bytes.get(o..o + l).unwrap_or_default();
            let t = Clock::start();
            let h = cas::hash(raw);
            let none = Trained::default();
            let plan = policy::plan_chunk(
                raw,
                kind,
                &have,
                &h,
                level,
                if first_turn { &none } else { &dicts },
                params,
            );
            let (f, used) = frame::encode(raw, plan.encoding, params.keep_ratio, &dicts);
            item.cpu_send += t.secs();
            // On an edit the remote has the dictionaries already: nothing to wait for.
            item.needs_dicts |=
                scenario == Scenario::Cold && matches!(used, Encoding::ZstdDict(..));
            let reason = match (plan.reason, used) {
                (policy::Reason::Have, _) => "have",
                (_, Encoding::Store) => match plan.reason {
                    policy::Reason::CompressedKind => "store:compressed-kind",
                    policy::Reason::HighEntropy => "store:entropy",
                    policy::Reason::Tiny => "store:tiny",
                    _ => "store:no-gain",
                },
                (_, Encoding::ZstdDict(..)) => "zstd+dict",
                _ => "zstd",
            };
            *out.reasons.entry(reason).or_default() += l as u64;
            let growth = f.len() as i64 - l as i64 - frame::MAX_OVERHEAD as i64;
            if growth > 0 {
                out.grown_bytes += growth as u64;
            }
            out.worst_growth = out.worst_growth.max(f.len() as i64 - l as i64);
            // Receiver: decode and check.
            let t = Clock::start();
            let ok = match frame::decode(&f, &dicts) {
                Ok(Decoded::Bytes(b)) => b == raw,
                Ok(Decoded::Ref { hash, len }) => store.contains_key(&hash) && len == l as u64,
                Err(_) => false,
            };
            item.cpu_recv += t.secs();
            if !ok {
                out.verify_failures += 1;
            }
            have.insert(h);
            store.insert(h, ());
            // Stream framing: file id and offset.
            item.wire_up += f.len() as u64 + 6;
            if item.wire_up >= 1 << 20 {
                item.wire_down += 16;
                out.items
                    .push(std::mem::replace(&mut item, Item { first_turn, ..Item::default() }));
            }
        }
        if item.wire_up > 0 {
            item.wire_down += 16;
            out.items.push(item);
        }
    }
    out
}

/// One measured run.
#[derive(Clone, Debug)]
pub struct Run {
    pub first_turn_s: f64,
    pub synced_s: f64,
    pub wire_bytes: u64,
    pub cpu_send_s: f64,
    pub cpu_recv_s: f64,
}

/// Applies a link to an encoded folder. `jitter` scales bandwidth and RTT (1.0 = nominal).
pub fn simulate(
    enc: &Encoded,
    strategy: Strategy,
    p: &Profile,
    params: &Params,
    cores: usize,
    jitter: (f64, f64),
) -> Run {
    let p = Profile { bandwidth: p.bandwidth * jitter.0, rtt: p.rtt * jitter.1, ..*p };
    let (streams, per_stream, setup_rtts) = match strategy {
        // Today: 8 connections, each a TCP stream through the link; dial + identify + hold.
        Strategy::Today => (8usize, tcp_stream_ceiling(&p), 3.0),
        Strategy::New => {
            // Paced (Braid) streams when the param says so; else TCP like today.
            let per = if params.paced { paced_stream_ceiling(&p) } else { tcp_stream_ceiling(&p) };
            // Bandwidth probing: enough streams to fill the link, between the bounds. The probe
            // reads the unjittered profile (what a short probe sees), the run gets the jitter.
            let want = (p.bandwidth / jitter.0 / per).ceil() as usize;
            let s =
                want.clamp(params.streams.max(1), params.max_streams.max(params.streams.max(1)));
            (s, per, 2.0)
        }
    };
    let agg = p.bandwidth.min(per_stream * streams as f64);
    let per = per_stream.min(agg);
    // Cores: today compresses on the thread of each connection; new on a pool of `cores`.
    let send_cores = match strategy {
        Strategy::Today => streams.min(cores).max(1),
        Strategy::New => cores.max(1),
    } as f64;
    let setup = setup_rtts * p.rtt;

    // Today: greedy list scheduling of items to the least-loaded connection, in order; each item is a
    // round trip on its connection (serialize, send, wait for the answer).
    // New: a two-stage pipeline. A pool of `send_cores` compressors takes items in order (an item on the
    // core that frees first); a stream sends the next item once it is compressed and the stream is free.
    // The receiver decodes on its own pool, overlapped with the wire, so it bounds the total only by its
    // whole CPU over its cores.
    let run = |items: &[&Item]| -> (f64, u64, f64, f64) {
        let mut load = vec![0.0f64; streams];
        let mut pool = vec![0.0f64; send_cores as usize];
        let mut wire = 0u64;
        let mut cs = 0.0;
        let mut cr = 0.0;
        let mut dicts_ready = 0.0f64;
        for it in items {
            let w = it.wire_up as f64 / per;
            let i = least(&load);
            if it.round_trip {
                if let Some(slot) = load.get_mut(i) {
                    *slot += it.cpu_send + w + p.rtt + it.cpu_recv;
                }
            } else {
                let c = least(&pool);
                let free = pool.get(c).copied().unwrap_or(0.0);
                let start = if it.needs_dicts { free.max(dicts_ready) } else { free };
                let done = start + it.cpu_send;
                if let Some(slot) = pool.get_mut(c) {
                    *slot = done;
                }
                if it.trains_dicts {
                    dicts_ready = done;
                }
                if let Some(slot) = load.get_mut(i) {
                    *slot = slot.max(done) + w;
                }
            }
            wire += it.wire_up + it.wire_down;
            cs += it.cpu_send;
            cr += it.cpu_recv;
        }
        let longest = load.iter().cloned().fold(0.0, f64::max);
        let by_bw = items.iter().map(|i| i.wire_up).sum::<u64>() as f64 / agg;
        let by_recv = match strategy {
            Strategy::New => cr / send_cores,
            Strategy::Today => 0.0,
        };
        (longest.max(by_bw).max(by_recv), wire, cs, cr)
    };
    let all: Vec<&Item> = enc.items.iter().collect();
    let (total, wire, cs, cr) = run(&all);
    let synced = setup + total + p.rtt;
    let first_turn = match strategy {
        Strategy::Today => synced + p.rtt,
        Strategy::New => {
            let first: Vec<&Item> = enc.items.iter().filter(|i| i.first_turn).collect();
            let (t, ..) = run(&first);
            setup + t + 2.0 * p.rtt
        }
    };
    Run {
        first_turn_s: first_turn,
        synced_s: synced,
        wire_bytes: wire,
        cpu_send_s: cs,
        cpu_recv_s: cr,
    }
}

/// Index of the smallest of `v` (0 when empty).
fn least(v: &[f64]) -> usize {
    v.iter().enumerate().min_by(|a, b| a.1.total_cmp(b.1)).map_or(0, |(i, _)| i)
}

/// The `i`-th little-endian u32 of a hash.
fn word(h: &blake3::Hash, i: usize) -> u32 {
    h.as_bytes()
        .chunks_exact(4)
        .nth(i)
        .and_then(|w| <[u8; 4]>::try_from(w).ok())
        .map_or(0, u32::from_le_bytes)
}

/// p-th percentile (0..=100) of `v`, nearest rank.
pub fn pct(v: &[f64], p: f64) -> f64 {
    if v.is_empty() {
        return f64::NAN;
    }
    let mut s = v.to_vec();
    s.sort_by(f64::total_cmp);
    let rank = ((p / 100.0) * s.len() as f64).ceil().max(1.0) as usize;
    s.get(rank.min(s.len()).saturating_sub(1)).copied().unwrap_or(f64::NAN)
}

/// Deterministic jitter for run `i`: bandwidth 0.8..1.1, RTT 0.95..1.4 (a heavy tail on RTT).
pub fn jitter(seed: u64, i: u64) -> (f64, f64) {
    let h = blake3::hash(&[seed.to_le_bytes(), i.to_le_bytes()].concat());
    let a = f64::from(word(&h, 0)) / f64::from(u32::MAX);
    let b = f64::from(word(&h, 1)) / f64::from(u32::MAX);
    (0.8 + 0.3 * a, 0.95 + 0.45 * b * b)
}

/// One (folder, profile) prefetch result, averaged over the runs' simulated chats.
#[derive(Clone, Debug, Default)]
pub struct PrefetchRow {
    /// Today: the whole folder streams in fill order; what is held at the first turn is the
    /// prefix the link carried in the window, and the whole folder is held by the end.
    pub today: crate::prefetch::HitStats,
    /// The ranker: every candidate in rank order over the idle window before the first turn,
    /// then `prefetch_budget` of those above the floor kept.
    pub new: crate::prefetch::HitStats,
}

/// The chance a simulated chat reads `e`, from its heat: instructions and manifests about 0.9,
/// shallow source a quarter, dependency trees near zero.
fn read_chance(e: &Entry) -> f64 {
    let h = f64::from(order::heat(e));
    0.9 / (1.0 + h / 12.0).powi(2)
}

/// A uniform 0..1 from `(seed, salt, path)`.
fn unit(seed: u64, salt: u8, path: &str) -> f64 {
    let mut b = seed.to_le_bytes().to_vec();
    b.push(salt);
    b.extend_from_slice(path.as_bytes());
    f64::from(word(&blake3::hash(&b), 0)) / f64::from(u32::MAX)
}

/// Simulates `runs` chats over `entries` and measures both holdings.
///
/// The chat model: each file is read with [`read_chance`]; a read of a file hotter than 20
/// (instructions, shallow source, recent edits) happens on the first turn. The ranker sees a
/// noisy estimate of the chance (0.6 to 1.4 times the truth), as the projection's hold model
/// would give it, never the truth itself.
pub fn prefetch_eval(entries: &[Entry], params: &Params, p: &Profile, runs: u64) -> PrefetchRow {
    use crate::prefetch::{self, Candidate, HitStats};
    let mut sum = PrefetchRow::default();
    let runs = runs.max(1);
    let add = |acc: &mut HitStats, h: HitStats| {
        acc.first_turn_hit_rate += h.first_turn_hit_rate / runs as f64;
        acc.first_turn_hit_bytes_rate += h.first_turn_hit_bytes_rate / runs as f64;
        acc.held_never_read_bytes += h.held_never_read_bytes / runs;
        acc.held_bytes += h.held_bytes / runs;
        acc.first_turn_reads += h.first_turn_reads / runs;
    };
    for seed in 0..runs {
        let (bw, _) = jitter(seed ^ 0x5eed, 0);
        let idle = p.bandwidth * bw;
        let (mut first, mut later) = (Vec::new(), Vec::new());
        let mut cands = Vec::with_capacity(entries.len());
        for e in entries {
            let chance = read_chance(e);
            if unit(seed, 0, &e.path) < chance {
                let r = (e.path.clone(), e.size);
                if order::heat(e) < 20 { first.push(r) } else { later.push(r) }
            }
            let est = (chance * (0.6 + 0.8 * unit(seed, 1, &e.path))).min(1.0);
            cands.push(Candidate { path: e.path.clone(), likelihood: est as f32, size: e.size });
        }
        // Today: the fill-order prefix at the first turn, the whole folder after.
        let carried = (idle * params.prefetch_window_s) as u64;
        let mut at_first = HashMap::new();
        let mut sent = 0u64;
        for e in entries {
            if sent + e.size > carried {
                break;
            }
            sent += e.size;
            at_first.insert(e.path.clone(), e.size);
        }
        let all: HashMap<String, u64> = entries.iter().map(|e| (e.path.clone(), e.size)).collect();
        let mut today = prefetch::hit_stats(&at_first, &first, &later);
        let end = prefetch::hit_stats(&all, &first, &later);
        today.held_never_read_bytes = end.held_never_read_bytes;
        today.held_bytes = end.held_bytes;
        add(&mut sum.today, today);
        // New: before the first turn the idle link carries every candidate in rank order (no
        // floor, no budget: the window is spare link either way), the hot files included: the
        // ranker orders them better than fill order (on lossy, 4 MiB of fill-order hot files
        // fill the whole window and halve the hit rate). After it the machine keeps the
        // budget's worth above the floor too. Held-never-read counts all of it.
        let none = std::collections::HashSet::new();
        let window = prefetch::plan(
            &prefetch::rank(&cands, &none, 0.0),
            idle,
            params.prefetch_window_s,
            u64::MAX,
        );
        let kept = prefetch::plan(
            &prefetch::rank(&cands, &none, params.prefetch_min_likelihood as f32),
            idle,
            f64::INFINITY,
            params.prefetch_budget,
        );
        let at_first: HashMap<String, u64> =
            window.iter().map(|c| (c.path.clone(), c.size)).collect();
        let mut held = at_first.clone();
        held.extend(kept.into_iter().map(|c| (c.path, c.size)));
        let mut new = prefetch::hit_stats(&at_first, &first, &later);
        let end = prefetch::hit_stats(&held, &first, &later);
        new.held_never_read_bytes = end.held_never_read_bytes;
        new.held_bytes = end.held_bytes;
        add(&mut sum.new, new);
    }
    sum
}
