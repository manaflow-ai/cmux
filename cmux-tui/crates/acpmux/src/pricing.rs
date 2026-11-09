//! The bundled price table (`pricing/prices.json`): USD per million tokens for input, output,
//! cache read and cache write, per vendor, for the cost ledger (`hub/ledger`). One versioned
//! file: every ledger entry records the `version` it was priced with, so a later table never
//! reprices old spend.
//!
//! A model id matches the longest entry id it starts with, when what follows is nothing, a
//! bracketed or `@`/`:` tag (`claude-opus-5-5[1m]`) or a `-` and four or more digits (a dated
//! snapshot, `claude-opus-4-5-20251101`). `gpt-5-mini` and `claude-opus-5-9` never take
//! `gpt-5`'s or `claude-opus-5`'s price: a model the table does not list stays unpriced rather
//! than priced like a sibling. A `vendor/` prefix
//! (`openai/gpt-5.5`) is dropped before matching, and an alias (`opus`) is the id it names.
//!
//! Sources, recorded per vendor in the file: Anthropic's first-party API rates (5-minute cache
//! writes, Haiku 5.5 at its rate for prompts up to 100K tokens), and the model catalog acpmux
//! ships (`catalog/models-v1.json`) for the others. A model no source prices is left out. A
//! missing cache read price bills cache reads as input; a missing cache write price bills them
//! nothing (those vendors do not charge for writes).
//!
//! A cache write is billed by its tier. `cacheWrite` is the 5-minute rate; the hour-long writes a
//! turn reports (`TurnUsage::cache_write_1h_tokens`, the tier cmux asks Claude Code for by
//! default, `prompt_cache_env.rs`) bill at an entry's `cacheWrite1h`, else at twice its input
//! price (Anthropic's rule), or nothing where the vendor charges no writes at all (no `cacheWrite`,
//! or `"cacheWrite": 0`).

use std::sync::LazyLock;

use serde::Deserialize;

const BUNDLED: &str = include_str!("pricing/prices.json");

/// USD per million tokens.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Price {
    pub input: f64,
    pub output: f64,
    #[serde(default)]
    pub cache_read: Option<f64>,
    #[serde(default)]
    pub cache_write: Option<f64>,
    /// The hour-long cache write rate, when it is not twice the input price.
    #[serde(default, rename = "cacheWrite1h")]
    pub cache_write_1h: Option<f64>,
}

impl Price {
    /// The hour-long cache write rate: the entry's own, else twice the input price for a vendor
    /// that charges writes. A vendor that charges none, by a missing or an explicit zero
    /// `cacheWrite` (`"cacheWrite": 0`), bills neither tier.
    pub fn cache_write_1h_rate(&self) -> f64 {
        let charged = self.cache_write.is_some_and(|rate| rate > 0.0);
        self.cache_write_1h.unwrap_or(if charged { self.input * 2.0 } else { 0.0 })
    }
}

#[derive(Debug, Deserialize)]
struct Entry {
    id: String,
    #[serde(flatten)]
    price: Price,
}

#[derive(Debug, Deserialize)]
struct Vendor {
    models: Vec<Entry>,
}

#[derive(Debug, Deserialize)]
struct File {
    version: String,
    currency: String,
    #[serde(default)]
    aliases: std::collections::BTreeMap<String, String>,
    vendors: std::collections::BTreeMap<String, Vendor>,
}

/// The loaded table: entries longest id first, so the first match is the longest.
#[derive(Debug)]
pub struct PriceTable {
    pub version: String,
    pub currency: String,
    aliases: std::collections::BTreeMap<String, String>,
    entries: Vec<(String, String, Price)>,
}

static TABLE: LazyLock<PriceTable> = LazyLock::new(|| {
    PriceTable::parse(BUNDLED).unwrap_or_else(|e| {
        // A test guards the bundled file; an unreadable one prices nothing.
        tracing::error!("bundled price table: {e}");
        PriceTable {
            version: String::new(),
            currency: "USD".into(),
            aliases: Default::default(),
            entries: vec![],
        }
    })
});

/// The bundled table.
pub fn table() -> &'static PriceTable {
    &TABLE
}

impl PriceTable {
    pub fn parse(text: &str) -> Result<Self, serde_json::Error> {
        let file: File = serde_json::from_str(text)?;
        let mut entries: Vec<(String, String, Price)> = file
            .vendors
            .into_iter()
            .flat_map(|(vendor, v)| {
                v.models.into_iter().map(move |e| (e.id, vendor.clone(), e.price))
            })
            .collect();
        entries.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then_with(|| a.0.cmp(&b.0)));
        Ok(Self { version: file.version, currency: file.currency, aliases: file.aliases, entries })
    }

    /// The vendor and price for `model`, when the table lists it. A `provider/` prefix picks
    /// that vendor's entry when two vendors list the same id (`alibaba/kimi-k3`).
    pub fn lookup(&self, model: &str) -> Option<(&str, Price)> {
        let model = model.trim();
        let (provider, bare) = match model.rsplit_once('/') {
            Some((p, b)) => (p.rsplit('/').next().filter(|p| !p.is_empty()), b),
            None => (None, model),
        };
        let bare = self.aliases.get(bare).map_or(bare, String::as_str);
        let mut matches = self.entries.iter().filter(|(id, _, _)| matches_id(bare, id));
        let first = matches.next()?;
        let chosen = match provider {
            Some(p) if first.1 != p => {
                std::iter::once(first).chain(matches).find(|e| e.1 == p).unwrap_or(first)
            }
            _ => first,
        };
        Some((chosen.1.as_str(), chosen.2))
    }

    /// What `usage` costs at `model`'s price; None when the table does not list it, or when the
    /// harness reported no token counts at all (absent is not zero: such a turn is unpriced).
    pub fn cost(&self, model: &str, usage: &crate::store::TurnUsage) -> Option<f64> {
        if usage.input_tokens.is_none()
            && usage.output_tokens.is_none()
            && usage.cache_read_tokens.is_none()
            && usage.cache_write_tokens.is_none()
        {
            return None;
        }
        let (_, p) = self.lookup(model)?;
        let per = |tokens: Option<u64>, price: f64| tokens.unwrap_or(0) as f64 * price / 1e6;
        // The writes' hour-long part at its tier, the rest at the 5-minute rate.
        let write = usage.cache_write_tokens.unwrap_or(0);
        let write_1h = usage.cache_write_1h_tokens.unwrap_or(0).min(write);
        Some(
            per(usage.input_tokens, p.input)
                + per(usage.output_tokens, p.output)
                + per(usage.cache_read_tokens, p.cache_read.unwrap_or(p.input))
                + per(Some(write - write_1h), p.cache_write.unwrap_or(0.0))
                + per(Some(write_1h), p.cache_write_1h_rate()),
        )
    }
}

/// `model` is `id`, or `id` with a tag or a dated suffix after it.
fn matches_id(model: &str, id: &str) -> bool {
    let Some(rest) = model.strip_prefix(id) else { return false };
    let mut chars = rest.chars();
    match chars.next() {
        None | Some('[' | '@' | ':') => true,
        // A dated snapshot (`-20251101`, `-2024-08-06`), never a version (`-9`).
        Some('-') => chars.take_while(char::is_ascii_digit).count() >= 4,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::TurnUsage;

    #[test]
    fn bundled_table_parses_with_a_version() {
        let t = PriceTable::parse(BUNDLED).expect("bundled prices.json");
        assert!(!t.version.is_empty());
        assert_eq!(t.currency, "USD");
        assert!(t.entries.len() > 50);
    }

    #[test]
    fn matches_the_longest_id_with_tags_and_snapshots() {
        let t = table();
        let (vendor, opus) = t.lookup("claude-opus-5-5[1m]").unwrap();
        assert_eq!(vendor, "anthropic");
        assert_eq!(opus.input, 4.0);
        assert_eq!(t.lookup("opus").unwrap().1, opus);
        assert_eq!(t.lookup("anthropic/claude-opus-5-5").unwrap().1, opus);
        assert_eq!(t.lookup("claude-opus-4-5-20251101").unwrap().1.input, 5.0);
        assert_eq!(t.lookup("openai/gpt-5.5").unwrap().0, "openai");
        // A sibling the table does not list is not priced like its neighbour.
        assert!(t.lookup("claude-opus-5-9").is_none());
        assert_eq!(t.lookup("gpt-5-2025-08-07").unwrap().1, t.lookup("gpt-5").unwrap().1);
        assert!(t.lookup("gpt-5.5-turbo-x").is_none());
        assert!(t.lookup("").is_none());
    }

    #[test]
    fn cost_bills_each_token_kind() {
        let usage = TurnUsage {
            cost_usd: None,
            input_tokens: Some(1_000_000),
            output_tokens: Some(100_000),
            cache_read_tokens: Some(1_000_000),
            cache_write_tokens: Some(1_000_000),
            cache_write_1h_tokens: None,
        };
        // 4 + 2 + 0.2 + 5
        let cost = table().cost("claude-opus-5-5", &usage).unwrap();
        assert!((cost - 11.2).abs() < 1e-9, "{cost}");
        assert!(table().cost("no-such-model", &usage).is_none());
        // A model with no reported counts is unpriced, not free; an explicit zero is free.
        let none = TurnUsage::default();
        assert!(table().cost("claude-opus-5-5", &none).is_none());
        let zero = TurnUsage { input_tokens: Some(0), ..TurnUsage::default() };
        assert_eq!(table().cost("claude-opus-5-5", &zero), Some(0.0));
    }

    #[test]
    fn hour_long_cache_writes_bill_at_their_tier() {
        let t = table();
        let usage = |write_1h: Option<u64>| TurnUsage {
            cache_write_tokens: Some(1_000_000),
            cache_write_1h_tokens: write_1h,
            ..TurnUsage::default()
        };
        // Opus 5.5: input 4, 5-minute writes 5, hour-long writes twice the input (8).
        let cost = |write_1h| t.cost("claude-opus-5-5", &usage(write_1h)).unwrap();
        assert!((cost(None) - 5.0).abs() < 1e-9, "{}", cost(None));
        assert!((cost(Some(1_000_000)) - 8.0).abs() < 1e-9, "{}", cost(Some(1_000_000)));
        // A quarter hour-long: 0.75 * 5 + 0.25 * 8.
        assert!((cost(Some(250_000)) - 5.75).abs() < 1e-9, "{}", cost(Some(250_000)));
        // A count past the writes is the writes.
        assert!((cost(Some(5_000_000)) - 8.0).abs() < 1e-9, "{}", cost(Some(5_000_000)));

        // An entry's own hour-long rate wins; a vendor that charges no writes bills none.
        let custom = PriceTable::parse(
            r#"{"version": "t", "currency": "USD", "vendors": {"v": {"models": [
                {"id": "own", "input": 1, "output": 1, "cacheWrite": 1.25, "cacheWrite1h": 3},
                {"id": "free", "input": 1, "output": 1},
                {"id": "zero", "input": 1, "output": 1, "cacheWrite": 0},
                {"id": "zero-own", "input": 1, "output": 1, "cacheWrite": 0, "cacheWrite1h": 2}
            ]}}}"#,
        )
        .unwrap();
        assert_eq!(custom.cost("own", &usage(Some(1_000_000))), Some(3.0));
        assert_eq!(custom.cost("free", &usage(Some(1_000_000))), Some(0.0));
        // An explicit zero write price is free at both tiers, not twice the input.
        assert_eq!(custom.cost("zero", &usage(Some(1_000_000))), Some(0.0));
        assert_eq!(custom.cost("zero", &usage(None)), Some(0.0));
        // Unless the entry names an hour-long rate of its own.
        assert_eq!(custom.cost("zero-own", &usage(Some(1_000_000))), Some(2.0));
    }

    #[test]
    fn bundled_entries_that_charge_no_writes_bill_no_hour_long_writes() {
        let t = PriceTable::parse(BUNDLED).unwrap();
        let free: Vec<&str> = t
            .entries
            .iter()
            .filter(|(_, _, p)| p.cache_write.is_none_or(|rate| rate == 0.0))
            .map(|(id, _, p)| {
                assert_eq!(p.cache_write_1h_rate(), p.cache_write_1h.unwrap_or(0.0), "{id}");
                id.as_str()
            })
            .collect();
        // The bundled table lists such vendors (glm-5.2 has `"cacheWrite": 0`).
        assert!(free.contains(&"glm-5.2"), "{free:?}");
        for (id, _, p) in &t.entries {
            if p.cache_write.is_some_and(|rate| rate > 0.0) && p.cache_write_1h.is_none() {
                assert_eq!(p.cache_write_1h_rate(), p.input * 2.0, "{id}");
            }
        }
    }

    #[test]
    fn a_provider_prefix_picks_its_own_vendor_for_a_shared_id() {
        let t = table();
        for (model, vendor) in [
            ("moonshotai/kimi-k3", "moonshotai"),
            ("alibaba/kimi-k3", "alibaba"),
            ("zai/glm-5.2", "zai"),
            ("alibaba/glm-5.2", "alibaba"),
        ] {
            assert_eq!(t.lookup(model).unwrap().0, vendor, "{model}");
        }
        // An unknown provider still finds the id.
        assert!(t.lookup("router/kimi-k3").is_some());
    }
}
