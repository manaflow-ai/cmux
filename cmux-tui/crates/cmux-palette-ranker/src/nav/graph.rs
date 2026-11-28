//! The palette's scope graph: every scope and how scopes enter each other (which prefix or keyword
//! enters which child from a given parent). A port of the app's `PaletteScopeGraph`
//! (plans/cmux-next/palette-scopes.md section 3); the reducer reads it as its environment.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_segmentation::UnicodeSegmentation;

/// The full palette, always level 0 of an open palette.
pub const ROOT: &str = "root";

/// Where the prefix, the keyword and the scope row enter a scope.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(tag = "kind", content = "scopes", rename_all = "camelCase")]
pub enum Parents {
    /// Only from the root (the full palette).
    #[default]
    Root,
    /// From any scope.
    Anywhere,
    /// From these scopes.
    Only(BTreeSet<String>),
}

impl Parents {
    pub fn allows(&self, parent: &str) -> bool {
        match self {
            Parents::Root => parent == ROOT,
            Parents::Anywhere => true,
            Parents::Only(set) => set.contains(parent),
        }
    }

    /// Whether some parent allows both rule sets (conservative for `anywhere`).
    pub fn overlaps(&self, other: &Parents) -> bool {
        match (self, other) {
            (Parents::Anywhere, _) | (_, Parents::Anywhere) => true,
            (Parents::Root, Parents::Root) => true,
            (Parents::Root, Parents::Only(set)) | (Parents::Only(set), Parents::Root) => {
                set.contains(ROOT)
            }
            (Parents::Only(x), Parents::Only(y)) => !x.is_disjoint(y),
        }
    }
}

/// A palette scope as the catalog lists it: pure data, no item source. The display fields
/// (title, symbol, placeholder, open action, owner) pass through untouched.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Descriptor {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub symbol: String,
    #[serde(default)]
    pub placeholder: String,
    #[serde(default)]
    pub prefix: Option<String>,
    #[serde(default)]
    pub keywords: Vec<String>,
    #[serde(default)]
    pub parents: Parents,
    #[serde(default)]
    pub empty_query_selection: i64,
    #[serde(default)]
    pub open_action: Option<String>,
    #[serde(default)]
    pub owner: String,
}

impl Descriptor {
    /// The descriptor as the app's initializer leaves it: keywords lowercased, the empty-query
    /// row at least 0.
    fn normalized(mut self) -> Self {
        self.keywords = self.keywords.iter().map(|keyword| lowercased(keyword)).collect();
        self.empty_query_selection = self.empty_query_selection.max(0);
        self
    }
}

/// Why a descriptor (or part of one) was left out of the graph.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Problem {
    /// The root id is reserved for the full palette.
    ReservedId {
        id: String,
    },
    DuplicateId {
        id: String,
    },
    /// A prefix must be one punctuation or symbol character.
    InvalidPrefix {
        id: String,
        prefix: String,
    },
    /// Two scopes enterable from the same parent share a prefix; the later one loses its prefix.
    PrefixCollision {
        id: String,
        with: String,
        prefix: String,
    },
    /// Two scopes enterable from the same parent share a keyword; the later one loses that keyword.
    KeywordCollision {
        id: String,
        with: String,
        keyword: String,
    },
}

/// Every palette scope, in registration order, with the problems registration found.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Graph {
    pub root: Descriptor,
    /// Registered scopes in registration order (the scope list, `palette.scopes`).
    pub scopes: Vec<Descriptor>,
    pub problems: Vec<Problem>,
    #[serde(skip)]
    index: HashMap<String, usize>,
}

impl Default for Graph {
    fn default() -> Self {
        Graph::new(Descriptor { id: ROOT.to_owned(), ..Descriptor::default() }, Vec::new())
    }
}

impl Graph {
    /// Registers `descriptors` in order. A later descriptor that collides with an earlier one
    /// keeps its id but loses the colliding prefix or keyword (user assignments are registered
    /// first, so they win).
    pub fn new(root: Descriptor, descriptors: Vec<Descriptor>) -> Self {
        // The root has no prefix, keyword or parent: it is only ever level 0.
        let root = Descriptor {
            id: ROOT.to_owned(),
            prefix: None,
            keywords: Vec::new(),
            parents: Parents::Only(BTreeSet::new()),
            ..root.normalized()
        };
        let mut graph =
            Graph { root, scopes: Vec::new(), problems: Vec::new(), index: HashMap::new() };
        for descriptor in descriptors {
            graph.register(descriptor.normalized());
        }
        graph
    }

    fn register(&mut self, mut descriptor: Descriptor) {
        if descriptor.id == ROOT {
            self.problems.push(Problem::ReservedId { id: descriptor.id });
            return;
        }
        if self.index.contains_key(&descriptor.id) {
            self.problems.push(Problem::DuplicateId { id: descriptor.id });
            return;
        }
        if let Some(prefix) = descriptor.prefix.clone() {
            if !is_valid_prefix(&prefix) {
                self.problems.push(Problem::InvalidPrefix { id: descriptor.id.clone(), prefix });
                descriptor.prefix = None;
            } else if let Some(other) = self.scopes.iter().find(|other| {
                other.prefix.as_deref() == Some(prefix.as_str())
                    && other.parents.overlaps(&descriptor.parents)
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
        for keyword in &descriptor.keywords {
            if keyword.is_empty() || keywords.contains(keyword) {
                continue;
            }
            if let Some(other) = self.scopes.iter().find(|other| {
                other.keywords.contains(keyword) && other.parents.overlaps(&descriptor.parents)
            }) {
                self.problems.push(Problem::KeywordCollision {
                    id: descriptor.id.clone(),
                    with: other.id.clone(),
                    keyword: keyword.clone(),
                });
            } else {
                keywords.push(keyword.clone());
            }
        }
        descriptor.keywords = keywords;
        self.index.insert(descriptor.id.clone(), self.scopes.len());
        self.scopes.push(descriptor);
    }

    pub fn descriptor(&self, id: &str) -> Option<&Descriptor> {
        if id == ROOT { Some(&self.root) } else { self.index.get(id).map(|&i| &self.scopes[i]) }
    }

    pub fn contains(&self, id: &str) -> bool {
        id == ROOT || self.index.contains_key(id)
    }

    /// The scope that the grapheme `prefix` enters from `parent`.
    pub fn child_by_prefix(&self, parent: &str, prefix: &str) -> Option<&Descriptor> {
        self.scopes.iter().find(|d| d.prefix.as_deref() == Some(prefix) && d.parents.allows(parent))
    }

    /// The scope whose keyword equals `text` (trimmed, case-insensitive) from `parent`.
    pub fn child_by_keyword(&self, parent: &str, text: &str) -> Option<&Descriptor> {
        let keyword = lowercased(trim_whitespace(text));
        if keyword.is_empty() {
            return None;
        }
        self.scopes.iter().find(|d| d.keywords.contains(&keyword) && d.parents.allows(parent))
    }

    /// Whether `child` may be entered from `parent` by prefix, keyword or scope row.
    pub fn can_enter(&self, child: &str, parent: &str) -> bool {
        self.index.get(child).is_some_and(|&i| self.scopes[i].parents.allows(parent))
    }

    /// Scopes enterable from `parent`, in registration order.
    pub fn children(&self, parent: &str) -> Vec<&Descriptor> {
        self.scopes.iter().filter(|d| d.parents.allows(parent)).collect()
    }
}

/// One grapheme of one scalar that is punctuation (`P*`) or a symbol (`S*`), as Foundation's
/// `CharacterSet.punctuationCharacters` and `.symbols` read it.
pub fn is_valid_prefix(prefix: &str) -> bool {
    let mut chars = prefix.chars();
    let (Some(scalar), None) = (chars.next(), chars.next()) else { return false };
    matches!(
        get_general_category(scalar),
        GeneralCategory::ConnectorPunctuation
            | GeneralCategory::DashPunctuation
            | GeneralCategory::OpenPunctuation
            | GeneralCategory::ClosePunctuation
            | GeneralCategory::InitialPunctuation
            | GeneralCategory::FinalPunctuation
            | GeneralCategory::OtherPunctuation
            | GeneralCategory::MathSymbol
            | GeneralCategory::CurrencySymbol
            | GeneralCategory::ModifierSymbol
            | GeneralCategory::OtherSymbol
    )
}

/// Foundation's `CharacterSet.whitespaces`: the space separators (`Zs`) and tab, not newlines.
fn is_whitespace(c: char) -> bool {
    c == '\t' || get_general_category(c) == GeneralCategory::SpaceSeparator
}

/// `trimmingCharacters(in: .whitespaces)`.
pub fn trim_whitespace(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}

/// Swift's `String.lowercased()`: each scalar's full lowercase mapping, with no locale and no
/// final-sigma context.
pub fn lowercased(text: &str) -> String {
    text.chars().flat_map(char::to_lowercase).collect()
}

/// The first grapheme of `text` and the rest, as Swift's `first` and `dropFirst()` read a String.
pub fn split_first_grapheme(text: &str) -> Option<(&str, &str)> {
    let first = text.graphemes(true).next()?;
    Some((first, &text[first.len()..]))
}

/// Applies the user's prefix assignments (`palette.scopes."<id>".prefix`, decision D-PS4): an
/// assignment replaces the scope's default (a null one removes it), and any other scope that had
/// an assigned character loses it, so the user's choice wins. An invalid character is ignored.
pub fn apply_assigned_prefixes(
    assigned: &HashMap<String, Option<String>>,
    scopes: Vec<Descriptor>,
) -> Vec<Descriptor> {
    if assigned.is_empty() {
        return scopes;
    }
    let valid: HashMap<&str, Option<&str>> = assigned
        .iter()
        .filter(|(_, prefix)| prefix.as_deref().is_none_or(is_valid_prefix))
        .map(|(id, prefix)| (id.as_str(), prefix.as_deref()))
        .collect();
    let taken: BTreeSet<&str> = valid.values().filter_map(|prefix| *prefix).collect();
    scopes
        .into_iter()
        .map(|mut scope| {
            if let Some(choice) = valid.get(scope.id.as_str()) {
                scope.prefix = choice.map(str::to_owned);
            } else if scope.prefix.as_deref().is_some_and(|prefix| taken.contains(prefix)) {
                scope.prefix = None;
            }
            scope
        })
        .collect()
}
