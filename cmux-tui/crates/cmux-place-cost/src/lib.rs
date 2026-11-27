//! One placement cost for every placer (RFD 0182 B7, `docs/rfd/0182-kernel-sched-mem.md` §M7).
//!
//! Our nodes are a Mac, a GCP VM, a Freestyle VM, a laptop; their "memory" is the checkout, the
//! build cache and the prompt cache, which lives on one provider account. AutoNUMA's rule, with
//! the distance in dollars and seconds:
//!
//! `cost(node) = rent × expected run + cold start (checkout, build cache) + cache refill
//! (context × write multiplier, when the account changes) + RTT × turns`.
//!
//! Account affinity is first-touch: a session stays on the account that holds its cache, and a
//! node that would send its turns elsewhere is charged the refill. Seconds become dollars at
//! [`Prices::usd_per_second`], so one number orders every node; [`Cost`] keeps both halves and
//! each term so a placer can say why. A term the caller could not read is counted as zero and
//! named in [`Cost::unknown`], never guessed.

#![forbid(unsafe_code)]

/// What is being placed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Work {
    /// Seconds it is expected to run (rent is paid for this long).
    pub expected_run_s: f64,
    /// Model turns it is expected to take (each pays one round trip to the node).
    pub turns: u32,
    /// Tokens of prompt prefix a cache miss rewrites.
    pub context_tokens: u64,
    /// The provider account holding its prompt cache now; `None` for work with no cache yet (a
    /// new session), which no node can miss.
    pub cache_account: Option<String>,
}

/// One candidate node.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Node {
    pub name: String,
    /// On-demand USD per hour; `Some(0.0)` for a machine already paid for. `None`: unknown.
    pub rent_usd_per_hour: Option<f64>,
    /// It already holds the work's checkout and build cache (the node the work last ran on).
    pub warm: bool,
    /// Seconds to make a checkout and build cache here from cold; read only when not `warm`.
    pub cold_start_s: Option<f64>,
    /// Round trip from the person or coordinator to it, in milliseconds.
    pub rtt_ms: Option<f64>,
    /// The account its turns would go to; `None`: unknown (a cached work is charged the refill).
    pub account: Option<String>,
}

/// The prices that turn tokens and seconds into dollars. Planning figures, not a bill.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Prices {
    /// USD per million uncached input tokens.
    pub input_usd_per_mtok: f64,
    /// A cache write's price as a multiple of input: 1.25 for the 5-minute TTL, 2 for the hour.
    pub write_multiplier: f64,
    /// A cache read's multiple (0.1): what the turn would have paid had it hit, so a refill
    /// charges only the difference.
    pub read_multiplier: f64,
    /// What one second of the work waiting is worth, in USD.
    pub usd_per_second: f64,
}

impl Prices {
    /// An agent lane: Opus-class input at $5 per million, the 5-minute cache, and a lane second
    /// priced at $0.004 ($14.40 an hour, the order of a busy lane's token spend).
    pub const LANE: Self = Self {
        input_usd_per_mtok: 5.0,
        write_multiplier: 1.25,
        read_multiplier: 0.1,
        usd_per_second: 0.004,
    };
}

/// The cost of one node for one work, term by term.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Cost {
    pub rent_usd: f64,
    pub refill_usd: f64,
    pub cold_start_s: f64,
    pub rtt_s: f64,
    /// The terms read as zero because the node did not say: `rent`, `cold_start`, `rtt`.
    pub unknown: Vec<&'static str>,
}

impl Cost {
    /// The dollar half: rent and refill.
    pub fn usd(&self) -> f64 {
        self.rent_usd + self.refill_usd
    }

    /// The seconds half: cold start and round trips.
    pub fn seconds(&self) -> f64 {
        self.cold_start_s + self.rtt_s
    }

    /// Both halves in dollars, the number placers order by.
    pub fn total_usd(&self, prices: &Prices) -> f64 {
        self.usd() + self.seconds() * prices.usd_per_second
    }
}

/// `node`'s cost for `work`.
pub fn cost(node: &Node, work: &Work, prices: &Prices) -> Cost {
    let mut unknown = Vec::new();
    let mut known = |v: Option<f64>, term: &'static str| {
        v.filter(|v| v.is_finite() && *v >= 0.0).unwrap_or_else(|| {
            unknown.push(term);
            0.0
        })
    };
    let run_s = work.expected_run_s.max(0.0);
    let rent_usd = known(node.rent_usd_per_hour, "rent") * run_s / 3600.0;
    let cold_start_s = if node.warm { 0.0 } else { known(node.cold_start_s, "cold_start") };
    let rtt_s = known(node.rtt_ms, "rtt") / 1000.0 * f64::from(work.turns);
    let refill_usd = match &work.cache_account {
        Some(held) if node.account.as_ref() != Some(held) => {
            refill_usd(work.context_tokens, prices)
        }
        _ => 0.0,
    };
    Cost { rent_usd, refill_usd, cold_start_s, rtt_s, unknown }
}

/// What rewriting `context_tokens` of prefix costs over reading it from cache.
pub fn refill_usd(context_tokens: u64, prices: &Prices) -> f64 {
    let extra = (prices.write_multiplier - prices.read_multiplier).max(0.0);
    // Token counts fit f64's 53-bit mantissa exactly far past any context window.
    #[allow(clippy::cast_precision_loss)]
    let tokens = context_tokens as f64;
    tokens / 1_000_000.0 * prices.input_usd_per_mtok * extra
}

/// Every node with its cost, cheapest first; equal totals keep the caller's order (its tier).
pub fn rank<'a>(nodes: &'a [Node], work: &Work, prices: &Prices) -> Vec<(&'a Node, Cost)> {
    let mut out: Vec<(&Node, Cost)> = nodes.iter().map(|n| (n, cost(n, work, prices))).collect();
    out.sort_by(|a, b| a.1.total_usd(prices).total_cmp(&b.1.total_usd(prices)));
    out
}

#[cfg(test)]
#[path = "lib_tests.rs"]
mod tests;
