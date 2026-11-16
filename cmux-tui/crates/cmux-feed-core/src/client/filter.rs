//! The Inbox's filter (Swift `FeedInboxFilter`): client-only presentation of
//! the owner's feed. Filtering never marks an item read or changes the
//! selection. Search terms match case, diacritic and width insensitive, as
//! Swift `range(of:options: [.caseInsensitive, .diacriticInsensitive])`
//! did.

use icu_normalizer::DecomposingNormalizerBorrowed;
use icu_normalizer::properties::CanonicalCombiningClassMapBorrowed;
use serde::Deserialize;

use super::item::FeedItem;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Connection {
    #[default]
    Feed,
    Github,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    #[default]
    All,
    Unread,
    NeedsYou,
    Notices,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Filter {
    #[serde(default)]
    pub connection: Connection,
    #[serde(default)]
    pub category: Category,
    #[serde(default)]
    pub query: Option<String>,
}

/// A filter with its query folded once.
pub struct Matcher {
    filter: Filter,
    terms: Vec<String>,
}

impl Matcher {
    pub fn new(filter: Filter) -> Self {
        let terms =
            filter.query.as_deref().unwrap_or_default().split_whitespace().map(fold).collect();
        Self { filter, terms }
    }

    pub fn is_everything(&self) -> bool {
        self.filter.connection == Connection::Feed
            && self.filter.category == Category::All
            && self.terms.is_empty()
    }

    pub fn keeps(&self, item: &FeedItem) -> bool {
        if self.filter.connection == Connection::Github && !is_github(item) {
            return false;
        }
        let category = match self.filter.category {
            Category::All => true,
            Category::Unread => item.is_unread(),
            Category::NeedsYou => item.is_open_request(),
            Category::Notices => !item.is_request(),
        };
        if !category {
            return false;
        }
        if self.terms.is_empty() {
            return true;
        }
        let searchable = fold(&format!(
            "{} {} {} {}",
            item.title,
            item.body,
            item.poster.display_label(),
            item.context_str("url").unwrap_or_default()
        ));
        self.terms.iter().all(|term| searchable.contains(term.as_str()))
    }
}

/// A GitHub item: the integration's dedupe namespace, or its label.
pub fn is_github(item: &FeedItem) -> bool {
    item.dedupe_key.as_deref().is_some_and(|key| key.starts_with("github:"))
        || item.poster.label == "GitHub"
}

const NFKD: DecomposingNormalizerBorrowed<'static> = DecomposingNormalizerBorrowed::new_nfkd();
const COMBINING_CLASS: CanonicalCombiningClassMapBorrowed<'static> =
    CanonicalCombiningClassMapBorrowed::new();

/// The folded form of `text`: NFKD, combining marks dropped, lowercased
/// (the history search's fold, cmux-history `fold`).
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in NFKD.normalize_iter(text.chars()) {
        if COMBINING_CLASS.get_u8(ch) != 0 {
            continue;
        }
        for lower in ch.to_lowercase() {
            if COMBINING_CLASS.get_u8(lower) != 0 {
                continue;
            }
            match lower {
                'ß' => out.push_str("ss"),
                'ς' => out.push('σ'),
                other => out.push(other),
            }
        }
    }
    out
}
