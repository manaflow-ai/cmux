//! A maintained projection for `_acpmux/usage` (decision 368). Requests read only keys,
//! bounded rank ranges and cached totals. Local writes and mirrored peer row writes maintain
//! separate persistent tables, so a request can merge their first page without walking either.

use crate::protocol::session::UsageStats;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::cmp::Ordering;
use std::sync::Arc;

pub(crate) const MAX_KEYS: usize = 100;
pub(crate) const MAX_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Sort {
    #[default]
    Cost,
    Context,
}

/// Numbers unknown to v1 sort below every known value, including zero.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
struct Number(f64);
impl PartialEq for Number {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for Number {}
impl PartialOrd for Number {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Number {
    fn cmp(&self, other: &Self) -> Ordering {
        other.0.total_cmp(&self.0)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Rank {
    first: Number,
    second: Number,
    id: String,
    key: String,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Entry {
    pub(crate) key: String,
    pub(crate) row: Value,
    stats: UsageStats,
    pub(crate) bytes: usize,
}

impl Entry {
    pub(crate) fn new(key: String, summary: &Value) -> Option<Self> {
        let stats: UsageStats = serde_json::from_value(summary.get("usageStats")?.clone()).ok()?;
        let mut row = serde_json::Map::new();
        for field in ["sessionId", "name", "title", "displayTitle", "harness", "peer", "host"] {
            if let Some(value) = summary.get(field) {
                row.insert(field.into(), value.clone());
            }
        }
        row.insert("key".into(), json!(key));
        row.insert("usageStats".into(), serde_json::to_value(&stats).ok()?);
        let row = Value::Object(row);
        let bytes = serde_json::to_vec(&row).ok()?.len();
        Some(Self { key, row, stats, bytes })
    }

    pub(crate) fn with_key(&self, key: &str) -> Option<Self> {
        Self::new(key.to_owned(), &self.row)
    }

    pub(crate) fn rank(&self, sort: Sort) -> Rank {
        let cost = self.stats.cost_usd24h.filter(|n| n.is_finite() && *n >= 0.0).unwrap_or(-1.0);
        let context = self.stats.context_tokens.map(|n| n as f64).unwrap_or(-1.0);
        let (first, second) = match sort {
            Sort::Cost => (cost, context),
            Sort::Context => (context, cost),
        };
        Rank {
            first: Number(first),
            second: Number(second),
            id: self.row["sessionId"].as_str().unwrap_or(&self.key).to_owned(),
            key: self.key.clone(),
        }
    }
}

/// Known subtotals retain a known-row count: unknown is never represented as a known zero.
#[derive(Clone, Copy, Default)]
struct Sum {
    value: f64,
    known: usize,
}
impl Sum {
    fn change(&mut self, value: Option<f64>, add: bool) {
        if let Some(value) = value.filter(|n| n.is_finite() && *n >= 0.0) {
            if add {
                self.value += value;
                self.known += 1;
            } else {
                self.value -= value;
                self.known -= 1;
            }
            if self.known == 0 {
                self.value = 0.0;
            }
        }
    }
    fn merged(self, other: Self) -> Value {
        let known = self.known + other.known;
        json!({"value": if known == 0 { None } else { Some((self.value + other.value).max(0.0)) }, "known": known})
    }
}

#[derive(Clone, Default)]
struct Totals {
    cost: Sum,
    context: Sum,
    tokens: Sum,
    calls: Sum,
    subagents: Sum,
    compactions: Sum,
}
impl Totals {
    fn change(&mut self, s: &UsageStats, add: bool) {
        self.cost.change(s.cost_usd24h, add);
        self.context.change(s.context_tokens.map(|n| n as f64), add);
        self.tokens.change(s.tokens24h.map(|n| n as f64), add);
        self.calls.change(s.calls24h.map(|n| n as f64), add);
        self.subagents.change(s.subagents_live.map(|n| n as f64), add);
        self.compactions.change(s.compactions24h.map(|n| n as f64), add);
    }
}

/// Cloning a table shares its nodes. A mutation costs O(log N); a page O(log N + page size).
#[derive(Clone, Default)]
pub(crate) struct UsageOrder {
    entries: imbl::HashMap<String, Arc<Entry>>,
    cost: imbl::OrdSet<Rank>,
    context: imbl::OrdSet<Rank>,
    totals: Totals,
    pub(crate) revision: u64,
}

impl UsageOrder {
    pub(crate) fn replace(&mut self, key: &str, entry: Option<Entry>) {
        self.replace_shared(key, entry.map(Arc::new));
    }

    pub(crate) fn replace_shared(&mut self, key: &str, entry: Option<Arc<Entry>>) {
        if self.entries.get(key) == entry.as_ref() {
            return;
        }
        self.remove(key);
        if let Some(entry) = entry {
            self.cost.insert(entry.rank(Sort::Cost));
            self.context.insert(entry.rank(Sort::Context));
            self.totals.change(&entry.stats, true);
            self.entries.insert(key.to_owned(), entry);
            self.revision += 1;
        }
    }

    pub(crate) fn remove(&mut self, key: &str) {
        if let Some(old) = self.entries.remove(key) {
            self.cost.remove(&old.rank(Sort::Cost));
            self.context.remove(&old.rank(Sort::Context));
            self.totals.change(&old.stats, false);
            self.revision += 1;
        }
    }

    pub(crate) fn get(&self, key: &str) -> Option<&Arc<Entry>> {
        self.entries.get(key)
    }
    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) fn page(&self, sort: Sort, after: Option<&Rank>, limit: usize) -> Vec<Arc<Entry>> {
        use std::ops::Bound::{Excluded, Unbounded};
        let order = match sort {
            Sort::Cost => &self.cost,
            Sort::Context => &self.context,
        };
        let bounds = (after.map_or(Unbounded, Excluded), Unbounded);
        order
            .range::<_, Rank>(bounds)
            .take(limit)
            .filter_map(|rank| self.entries.get(&rank.key).cloned())
            .collect()
    }

    pub(crate) fn totals_with(&self, other: &Self) -> Value {
        let (a, b) = (&self.totals, &other.totals);
        json!({"costUsd24h": a.cost.merged(b.cost), "contextTokens": a.context.merged(b.context),
            "tokens24h": a.tokens.merged(b.tokens), "calls24h": a.calls.merged(b.calls),
            "subagentsLive": a.subagents.merged(b.subagents), "compactions24h": a.compactions.merged(b.compactions)})
    }
}
