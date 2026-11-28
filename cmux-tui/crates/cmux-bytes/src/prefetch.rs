//! What a machine holds before a chat asks: "only what chats use ... but also what chats could
//! possibly use" (Leo, 2026-11-25). The candidate set (path, likelihood, size) comes from the
//! projection's hold model; this ranks it, plans the background fill over idle bandwidth, and
//! measures how well the holding worked: the first-turn hit rate and the bytes held but never read.
//!
//! The ranking rule. A held file is worth its likelihood of being read (a read it saves from
//! faulting: one round trip and the file's transfer, while the chat waits). It costs its size
//! on the link and on disk, plus a fixed per-file overhead ([`PER_FILE_COST`]: a frame, a
//! manifest row, an inode). So for a byte budget the greedy knapsack order is likelihood per
//! byte of cost, highest first, and that is the order here. Expected bytes saved (likelihood ×
//! size) breaks ties, so of two equally good files per byte the bigger one goes first, saving
//! more wire time once the chat reads it. A pure likelihood × size order would hold one
//! likely 200 MB asset ahead of a thousand likely source files; per byte holds the source first.

use std::collections::{HashMap, HashSet};

use crate::lanes::{Lane, Scheduler};

/// Bytes a held file costs beyond its content: a frame header, a manifest row and an inode's
/// worth. Without it, a thousand one-byte files with a 1% chance each would outrank a likely
/// 4 KB source file.
pub const PER_FILE_COST: u64 = 512;

/// One file a chat might read, as the projection's hold model names it.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub path: String,
    /// Chance, 0..=1, that a chat on this machine reads the file.
    pub likelihood: f32,
    pub size: u64,
}

impl Candidate {
    /// Likelihood per byte held, the ranking key.
    pub fn value_per_byte(&self) -> f64 {
        f64::from(self.likelihood) / (self.size + PER_FILE_COST) as f64
    }

    /// Bytes a chat is expected to read from this file, the tie-break.
    pub fn expected_bytes(&self) -> f64 {
        f64::from(self.likelihood) * self.size as f64
    }
}

/// `cands` minus what the machine already holds and what falls under `min_likelihood`, best
/// first (see the module docs for the rule). Duplicate paths keep their likeliest entry.
pub fn rank(
    cands: &[Candidate],
    already_held: &HashSet<String>,
    min_likelihood: f32,
) -> Vec<Candidate> {
    let mut best: HashMap<&str, &Candidate> = HashMap::new();
    for c in cands {
        if already_held.contains(&c.path)
            || c.likelihood.partial_cmp(&min_likelihood).is_none_or(|o| o.is_lt())
        {
            continue;
        }
        let e = best.entry(c.path.as_str()).or_insert(c);
        if c.likelihood > e.likelihood {
            *e = c;
        }
    }
    let mut out: Vec<Candidate> = best.into_values().cloned().collect();
    out.sort_by(|a, b| {
        b.value_per_byte()
            .total_cmp(&a.value_per_byte())
            .then_with(|| b.expected_bytes().total_cmp(&a.expected_bytes()))
            .then_with(|| a.path.cmp(&b.path))
    });
    out
}

/// What to send on the fill lane: the ranked files that fit in what the idle link carries in
/// `window_s` and in `budget_bytes`, in rank order. A file too big for what is left is skipped,
/// not a stop, so smaller files below it still fill the space.
pub fn plan(
    ranked: &[Candidate],
    idle_bytes_per_s: f64,
    window_s: f64,
    budget_bytes: u64,
) -> Vec<Candidate> {
    let link = (idle_bytes_per_s.max(0.0) * window_s.max(0.0)).min(u64::MAX as f64) as u64;
    let mut left = link.min(budget_bytes);
    let mut out = Vec::new();
    for c in ranked {
        if c.size <= left {
            left -= c.size;
            out.push(c.clone());
        }
    }
    out
}

/// Queues a plan on the fill lane only: manifest, faulted reads and hot files keep their
/// priority over it, and a fault for a planned file is the caller's `promote`.
pub fn enqueue(plan: Vec<Candidate>, s: &mut Scheduler<Candidate>) {
    for c in plan {
        s.push(Lane::Fill, c);
    }
}

/// How well the holding worked over a chat.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct HitStats {
    /// Share of the first turn's reads (by count: each miss is a stall) already held.
    pub first_turn_hit_rate: f64,
    /// The same share weighted by bytes.
    pub first_turn_hit_bytes_rate: f64,
    /// Bytes held that no read touched.
    pub held_never_read_bytes: u64,
    pub held_bytes: u64,
    pub first_turn_reads: u64,
}

/// `held` maps path to size; reads are (path, size). A first turn with no reads counts as all hit.
pub fn hit_stats(
    held: &HashMap<String, u64>,
    first_turn_reads: &[(String, u64)],
    all_reads: &[(String, u64)],
) -> HitStats {
    let (mut hits, mut hit_bytes, mut bytes) = (0u64, 0u64, 0u64);
    for (p, size) in first_turn_reads {
        bytes += size;
        if held.contains_key(p) {
            hits += 1;
            hit_bytes += size;
        }
    }
    let read: HashSet<&str> =
        all_reads.iter().chain(first_turn_reads).map(|(p, _)| p.as_str()).collect();
    let n = first_turn_reads.len() as u64;
    HitStats {
        first_turn_hit_rate: if n == 0 { 1.0 } else { hits as f64 / n as f64 },
        first_turn_hit_bytes_rate: if bytes == 0 { 1.0 } else { hit_bytes as f64 / bytes as f64 },
        held_never_read_bytes: held
            .iter()
            .filter(|(p, _)| !read.contains(p.as_str()))
            .map(|(_, s)| s)
            .sum(),
        held_bytes: held.values().sum(),
        first_turn_reads: n,
    }
}

#[cfg(test)]
#[path = "prefetch_tests.rs"]
mod tests;
