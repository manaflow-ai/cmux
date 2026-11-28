//! The ask matcher (RFD 0010, "Matching: embeddings plus structure"): proposes the asks a new
//! prompt repeats or follows up, each with a confidence and the parts it came from. It proposes
//! links, never merges asks.
//!
//! Hybrid, as the RFD's measurement recommends: nearest neighbours over the person's asks by
//! embedding, rescored with structure the ledger already has (same session, recency), plus keyword
//! hits for rare identifiers (PR numbers, file names, paths) that embeddings blur.
//!
//! The embedding here is local and dependency-free: signed feature hashing of words and
//! character trigrams into [`DIMS`] dimensions, L2-normalised, so cosine is a dot product. Each
//! ask is embedded once when it is folded in, and a query is one brute-force pass. A learned model
//! (bge-small) replaces [`embed`] without changing the scoring around it.

use std::collections::{HashMap, HashSet};

/// The embedding's width.
pub(super) const DIMS: usize = 256;
/// Matches one query returns at most.
pub(super) const TOP: usize = 3;
/// Below this score a candidate is not proposed.
pub(super) const FLOOR: f32 = 0.30;
/// Same-session bonus: a follow-up in the chat it was typed in.
const SAME_SESSION: f32 = 0.05;
/// Recency bonus at age zero, halving every [`HALF_LIFE_MS`].
const RECENT: f32 = 0.05;
const HALF_LIFE_MS: f64 = 7.0 * 24.0 * 3600.0 * 1000.0;
/// What a full keyword hit (every rare identifier of the query, at full rarity) adds.
const KEYWORD: f32 = 0.40;

/// One proposed link, with the parts of its score.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Match {
    pub ask: String,
    pub score: f32,
    pub cosine: f32,
    pub structure: f32,
    pub keyword: f32,
}

/// What the matcher keeps per ask.
pub(super) struct Indexed {
    pub vec: Vec<f32>,
    pub rare: HashSet<String>,
}

impl Indexed {
    pub(super) fn of(text: &str) -> Self {
        Self { vec: embed(text), rare: rare_identifiers(text) }
    }
}

/// One candidate as the matcher sees it.
pub(super) struct Candidate<'a> {
    pub ask: &'a str,
    pub sid: &'a str,
    pub ts: u64,
    pub index: &'a Indexed,
}

fn words(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
}

/// FNV-1a: stable across runs and builds, unlike the std hasher.
fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

fn add(vec: &mut [f32], feature: &[u8], weight: f32) {
    let h = fnv(feature);
    let slot = (h % DIMS as u64) as usize;
    let sign = if h >> 63 == 0 { 1.0 } else { -1.0 };
    vec[slot] += sign * weight;
}

/// The text's embedding: words weigh more than their trigrams, which carry inflections and typos.
pub(super) fn embed(text: &str) -> Vec<f32> {
    let mut vec = vec![0.0f32; DIMS];
    for word in words(text) {
        let mut key = Vec::with_capacity(word.len() + 2);
        key.push(b'w');
        key.extend_from_slice(word.as_bytes());
        add(&mut vec, &key, 1.0);
        let padded: Vec<char> = std::iter::once('^').chain(word.chars()).chain(['$']).collect();
        for gram in padded.windows(3) {
            let gram: String = gram.iter().collect();
            let mut key = vec![b'g'];
            key.extend_from_slice(gram.as_bytes());
            add(&mut vec, &key, 0.5);
        }
    }
    let norm = vec.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in &mut vec {
            *x /= norm;
        }
    }
    vec
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// Tokens embeddings blur: anything with a digit (PR and issue numbers, versions), a path or file
/// name (`.` or `/` inside), or a `snake_case` / `kebab-case` identifier.
pub(super) fn rare_identifiers(text: &str) -> HashSet<String> {
    text.split_whitespace()
        .map(|t| {
            t.trim_matches(|c: char| !(c.is_alphanumeric() || c == '_' || c == '/'))
                .trim_start_matches('#')
                .to_lowercase()
        })
        .filter(|t| t.chars().count() >= 3)
        .filter(|t| {
            t.chars().any(|c| c.is_ascii_digit())
                || t.contains('.')
                || t.contains('/')
                || t.contains('_')
                || (t.contains('-') && t.chars().any(char::is_alphabetic))
        })
        .collect()
}

/// The top [`TOP`] candidates at or above [`FLOOR`] for `text`, best first. `sid` and `now` are
/// the query's chat and time; `skip` is an ask that must not match itself.
pub(super) fn related<'a>(
    text: &str,
    sid: Option<&str>,
    now: u64,
    skip: Option<&str>,
    candidates: impl Iterator<Item = Candidate<'a>> + Clone,
) -> Vec<Match> {
    let query = Indexed::of(text);
    // How many asks carry each of the query's rare identifiers: a token in every ask is no signal.
    let mut df: HashMap<&str, usize> = query.rare.iter().map(|t| (t.as_str(), 0)).collect();
    let mut total = 0usize;
    for c in candidates.clone() {
        total += 1;
        for (token, n) in df.iter_mut() {
            if c.index.rare.contains(*token) {
                *n += 1;
            }
        }
    }
    let idf = |token: &str| {
        let n = df.get(token).copied().unwrap_or(0) as f32;
        ((total as f32 + 1.0) / (n + 1.0)).ln() / ((total as f32 + 1.0).ln()).max(f32::EPSILON)
    };
    let rare_weight: f32 = query.rare.iter().map(|t| idf(t)).sum();
    let mut out: Vec<Match> = candidates
        .filter(|c| Some(c.ask) != skip)
        .map(|c| {
            let cosine = dot(&query.vec, &c.index.vec).max(0.0);
            let age = now.saturating_sub(c.ts) as f64;
            let mut structure = RECENT * (0.5f64.powf(age / HALF_LIFE_MS)) as f32;
            if sid.is_some_and(|s| s == c.sid) {
                structure += SAME_SESSION;
            }
            let keyword = if rare_weight > 0.0 {
                let hit: f32 =
                    query.rare.iter().filter(|t| c.index.rare.contains(*t)).map(|t| idf(t)).sum();
                KEYWORD * hit / rare_weight
            } else {
                0.0
            };
            Match {
                ask: c.ask.to_string(),
                score: (cosine + structure + keyword).min(1.0),
                cosine,
                structure,
                keyword,
            }
        })
        .filter(|m| m.score >= FLOOR)
        .collect();
    out.sort_by(|a, b| b.score.total_cmp(&a.score).then_with(|| a.ask.cmp(&b.ask)));
    out.truncate(TOP);
    out
}
