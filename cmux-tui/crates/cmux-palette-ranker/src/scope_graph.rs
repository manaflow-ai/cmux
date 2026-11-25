//! The palette's scope graph: every scope and how scopes enter each other (which prefix or
//! keyword enters which child from a given parent). Pure and immutable once built; the
//! navigation reducer ([`crate::nav`]) reads it as its environment.
//!
//! Moved from Swift (`PaletteScopeGraph`, `PaletteScopeDescriptor`); the JSON shapes are the
//! Swift types' synthesized `Codable` forms (an enum case is `{"case": {"_0": value}}`), so the
//! macOS app sends and reads them with no hand-written mirror. plans/cmux-next/palette-scopes.md
//! section 3.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_segmentation::UnicodeSegmentation;

/// The full palette's id, always level 0 of an open palette.
pub const ROOT: &str = "root";

/// Where the prefix, the keyword and the scope row enter a scope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Parents {
    /// Only from the root (the full palette).
    Root {},
    /// From any scope.
    Anywhere {},
    /// From these scopes.
    Only {
        #[serde(rename = "_0", default)]
        scopes: Vec<String>,
    },
}

impl Parents {
    pub fn allows(&self, parent: &str) -> bool {
        match self {
            Parents::Root {} => parent == ROOT,
            Parents::Anywhere {} => true,
            Parents::Only { scopes } => scopes.iter().any(|s| s == parent),
        }
    }

    /// Whether some parent allows both rule sets (conservative for `anywhere`).
    pub fn overlaps(&self, other: &Parents) -> bool {
        match (self, other) {
            (Parents::Anywhere {}, _) | (_, Parents::Anywhere {}) => true,
            (Parents::Root {}, Parents::Root {}) => true,
            (Parents::Root {}, Parents::Only { scopes })
            | (Parents::Only { scopes }, Parents::Root {}) => scopes.iter().any(|s| s == ROOT),
            (Parents::Only { scopes: x }, Parents::Only { scopes: y }) => {
                x.iter().any(|s| y.contains(s))
            }
        }
    }
}

/// A palette scope as the catalog lists it: pure data, no item source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Descriptor {
    pub id: String,
    /// Chip text and scope row title.
    pub title: String,
    /// SF Symbol of the chip and the scope row.
    pub symbol: String,
    pub placeholder: String,
    /// One punctuation or symbol character typed into an empty query, or none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefix: Option<String>,
    /// Lowercased words: an exact keyword plus Tab enters the scope.
    #[serde(default)]
    pub keywords: Vec<String>,
    pub parents: Parents,
    /// The row an empty query selects, clamped to the rows.
    #[serde(default)]
    pub empty_query_selection: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_action: Option<String>,
    /// `client` for built-in scopes, `app:<id>` for app scopes.
    pub owner: String,
}

/// Why a descriptor (or one of its entry gestures) was left out of the graph.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Problem {
    /// The root id is reserved for the full palette.
    #[serde(rename = "reservedID")]
    ReservedId {
        #[serde(rename = "_0")]
        id: String,
    },
    #[serde(rename = "duplicateID")]
    DuplicateId {
        #[serde(rename = "_0")]
        id: String,
    },
    /// A prefix must be one punctuation or symbol character.
    InvalidPrefix {
        #[serde(rename = "_0")]
        id: String,
        #[serde(rename = "_1")]
        prefix: String,
    },
    /// Two scopes enterable from the same parent share a prefix; the later one loses its prefix.
    PrefixCollision {
        #[serde(rename = "_0")]
        id: String,
        with: String,
        prefix: String,
    },
    /// Two scopes enterable from the same parent share a keyword; the later one loses it.
    KeywordCollision {
        #[serde(rename = "_0")]
        id: String,
        with: String,
        keyword: String,
    },
}

/// The registered graph: the root, the scopes in registration order and what was refused.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Graph {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<Descriptor>,
    /// Scopes in registration order (the scope list, `palette.scopes`).
    #[serde(default)]
    pub scopes: Vec<Descriptor>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub problems: Vec<Problem>,
}

/// One grapheme that is a single punctuation or symbol scalar.
pub fn is_valid_prefix(prefix: &str) -> bool {
    let mut scalars = prefix.chars();
    let (Some(scalar), None) = (scalars.next(), scalars.next()) else { return false };
    is_punctuation_or_symbol(scalar)
}

/// Foundation's `CharacterSet.punctuationCharacters` (P*) or `symbols` (S*).
fn is_punctuation_or_symbol(c: char) -> bool {
    use GeneralCategory::*;
    matches!(
        get_general_category(c),
        ConnectorPunctuation
            | DashPunctuation
            | OpenPunctuation
            | ClosePunctuation
            | InitialPunctuation
            | FinalPunctuation
            | OtherPunctuation
            | MathSymbol
            | CurrencySymbol
            | ModifierSymbol
            | OtherSymbol
    )
}

/// Foundation's `CharacterSet.whitespaces`: Unicode Zs and the horizontal tab.
fn is_whitespace(c: char) -> bool {
    c == '\t' || get_general_category(c) == GeneralCategory::SpaceSeparator
}

/// A keyword as the graph compares it: trimmed of spaces and tabs, lowercased.
pub fn normalize_keyword(text: &str) -> String {
    text.trim_matches(is_whitespace).to_lowercase()
}

/// The first grapheme of `text` and the rest, as Swift's `first` and `dropFirst()`.
pub fn split_first_grapheme(text: &str) -> Option<(&str, &str)> {
    let first = text.graphemes(true).next()?;
    Some((first, &text[first.len()..]))
}

/// Applies the user's prefix choices (cmux.json `palette.scopePrefixes`, scope id to a character
/// or none): a choice replaces the scope's default, and any other scope that had that character
/// loses it, so the user's choice wins (decision D-PS4). An invalid character is ignored.
pub fn apply_assigned(
    assigned: &HashMap<String, Option<String>>,
    scopes: Vec<Descriptor>,
) -> Vec<Descriptor> {
    let valid: HashMap<&String, &Option<String>> = assigned
        .iter()
        .filter(|(_, choice)| choice.as_deref().is_none_or(is_valid_prefix))
        .collect();
    let taken: Vec<&String> = valid.values().filter_map(|choice| choice.as_ref()).collect();
    scopes
        .into_iter()
        .map(|mut scope| {
            if let Some(choice) = valid.get(&scope.id) {
                scope.prefix = (*choice).clone();
            } else if scope.prefix.as_ref().is_some_and(|prefix| taken.contains(&prefix)) {
                scope.prefix = None;
            }
            scope
        })
        .collect()
}

impl Graph {
    /// Registers `descriptors` in order. A later descriptor that collides with an earlier one
    /// keeps its id but loses the colliding prefix or keyword (user assignments are registered
    /// first, so they win). The root has no prefix, keyword or parent.
    pub fn build(root: Descriptor, descriptors: Vec<Descriptor>) -> Graph {
        let root = Descriptor {
            id: ROOT.into(),
            prefix: None,
            keywords: Vec::new(),
            parents: Parents::Only { scopes: Vec::new() },
            ..root
        };
        let mut graph = Graph { root: Some(root), scopes: Vec::new(), problems: Vec::new() };
        for descriptor in descriptors {
            graph.register(descriptor);
        }
        graph
    }

    fn register(&mut self, mut descriptor: Descriptor) {
        if descriptor.id == ROOT {
            self.problems.push(Problem::ReservedId { id: descriptor.id });
            return;
        }
        if self.scopes.iter().any(|s| s.id == descriptor.id) {
            self.problems.push(Problem::DuplicateId { id: descriptor.id });
            return;
        }
        if let Some(prefix) = descriptor.prefix.clone() {
            if !is_valid_prefix(&prefix) {
                self.problems.push(Problem::InvalidPrefix { id: descriptor.id.clone(), prefix });
                descriptor.prefix = None;
            } else if let Some(other) = self.scopes.iter().find(|s| {
                s.prefix.as_deref() == Some(prefix.as_str())
                    && s.parents.overlaps(&descriptor.parents)
            }) {
                self.problems.push(Problem::PrefixCollision {
                    id: descriptor.id.clone(),
                    with: other.id.clone(),
                    prefix,
                });
                descriptor.prefix = None;
            }
        }
        let mut keywords: Vec<String> = Vec::new();
        for keyword in std::mem::take(&mut descriptor.keywords) {
            if keyword.is_empty() || keywords.contains(&keyword) {
                continue;
            }
            if let Some(other) = self
                .scopes
                .iter()
                .find(|s| s.keywords.contains(&keyword) && s.parents.overlaps(&descriptor.parents))
            {
                self.problems.push(Problem::KeywordCollision {
                    id: descriptor.id.clone(),
                    with: other.id.clone(),
                    keyword,
                });
            } else {
                keywords.push(keyword);
            }
        }
        descriptor.keywords = keywords;
        self.scopes.push(descriptor);
    }

    pub fn descriptor(&self, id: &str) -> Option<&Descriptor> {
        if id == ROOT { self.root.as_ref() } else { self.scopes.iter().find(|s| s.id == id) }
    }

    pub fn contains(&self, id: &str) -> bool {
        id == ROOT || self.scopes.iter().any(|s| s.id == id)
    }

    /// The scope that the grapheme `prefix` enters from `parent`.
    pub fn child_by_prefix(&self, parent: &str, prefix: &str) -> Option<&Descriptor> {
        self.scopes.iter().find(|s| s.prefix.as_deref() == Some(prefix) && s.parents.allows(parent))
    }

    /// The scope whose keyword equals `text` (trimmed, case-insensitive) from `parent`.
    pub fn child_by_keyword(&self, parent: &str, text: &str) -> Option<&Descriptor> {
        let keyword = normalize_keyword(text);
        if keyword.is_empty() {
            return None;
        }
        self.scopes.iter().find(|s| s.keywords.contains(&keyword) && s.parents.allows(parent))
    }
}

#[cfg(test)]
#[path = "scope_graph_tests.rs"]
mod tests;
