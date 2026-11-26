//! Stable references and bidirectional links.
//!
//! A message may link to an RFD, session, PR, issue, Slack thread, file or shared document. A link is
//! a [`StableRef`]: what it is ([`RefKind`]), where it lives ([`RefSource`]), its id there, and a
//! display title. Identity is the [`RefKey`] (kind, source and normalized id); the title is display
//! only, so a renamed RFD is still the same ref.
//!
//! [`LinkGraph`] keeps every link from both ends: linking a thread to RFD 0170 makes the thread one of
//! RFD 0170's links and the RFD one of the thread's. Reading links goes through a reader's own
//! permission, so linking a pair thread into an RFD space never shows it to someone who could not
//! already read it.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RefKind {
    Rfd,
    Session,
    Thread,
    Message,
    Space,
    Pr,
    Issue,
    SlackThread,
    File,
    SharedDocument,
}

impl RefKind {
    pub const ALL: [RefKind; 10] = [
        Self::Rfd,
        Self::Session,
        Self::Thread,
        Self::Message,
        Self::Space,
        Self::Pr,
        Self::Issue,
        Self::SlackThread,
        Self::File,
        Self::SharedDocument,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rfd => "rfd",
            Self::Session => "session",
            Self::Thread => "thread",
            Self::Message => "message",
            Self::Space => "space",
            Self::Pr => "pr",
            Self::Issue => "issue",
            Self::SlackThread => "slack-thread",
            Self::File => "file",
            Self::SharedDocument => "doc",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }
}

/// Where the referenced record lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RefSource {
    /// The hosted forum, rooms and sessions.
    Cmux,
    /// The RFD corpus in cmuxterm-hq (`docs/rfd/`).
    Hq,
    GitHub,
    Linear,
    Slack,
}

impl RefSource {
    pub const ALL: [RefSource; 5] = [Self::Cmux, Self::Hq, Self::GitHub, Self::Linear, Self::Slack];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cmux => "cmux",
            Self::Hq => "hq",
            Self::GitHub => "github",
            Self::Linear => "linear",
            Self::Slack => "slack",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }
}

/// A ref's identity: kind, source and normalized id.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct RefKey {
    pub kind: RefKind,
    pub source: RefSource,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefError {
    /// No `kind:source/id` shape.
    Shape,
    UnknownKind(String),
    UnknownSource(String),
    /// The id is empty or not valid for its kind.
    BadId(String),
}

impl fmt::Display for RefError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Shape => write!(f, "a ref is kind:source/id"),
            Self::UnknownKind(k) => write!(f, "unknown ref kind {k:?}"),
            Self::UnknownSource(s) => write!(f, "unknown ref source {s:?}"),
            Self::BadId(id) => write!(f, "bad ref id {id:?}"),
        }
    }
}

impl std::error::Error for RefError {}

impl RefKey {
    /// A key with its id normalized for its kind, so two spellings of one record are one key:
    /// `rfd` ids are four digits (`170`, `RFD 170` and `0170` are RFD 0170); a PR or issue's
    /// `owner/repo#N` has its repository lowercased, as GitHub's are case-insensitive.
    pub fn new(kind: RefKind, source: RefSource, id: &str) -> Result<Self, RefError> {
        let id = normalize_id(kind, id)?;
        Ok(Self { kind, source, id })
    }

    /// `kind:source/id`, the one string form. [`RefKey::parse`] reads it back to the same key.
    pub fn canonical(&self) -> String {
        format!("{}:{}/{}", self.kind.as_str(), self.source.as_str(), self.id)
    }

    pub fn parse(s: &str) -> Result<Self, RefError> {
        let (kind, rest) = s.split_once(':').ok_or(RefError::Shape)?;
        let (source, id) = rest.split_once('/').ok_or(RefError::Shape)?;
        let kind = RefKind::parse(kind).ok_or_else(|| RefError::UnknownKind(kind.to_owned()))?;
        let source =
            RefSource::parse(source).ok_or_else(|| RefError::UnknownSource(source.to_owned()))?;
        Self::new(kind, source, id)
    }
}

impl fmt::Display for RefKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.canonical())
    }
}

fn normalize_id(kind: RefKind, id: &str) -> Result<String, RefError> {
    let bad = || RefError::BadId(id.to_owned());
    let trimmed = id.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
        return Err(bad());
    }
    match kind {
        RefKind::Rfd => {
            let digits = trimmed
                .strip_prefix("RFD")
                .or_else(|| trimmed.strip_prefix("rfd"))
                .unwrap_or(trimmed)
                .trim_start_matches([' ', '-', '_']);
            if digits.is_empty() || digits.len() > 9 || !digits.bytes().all(|b| b.is_ascii_digit())
            {
                return Err(bad());
            }
            let n: u32 = digits.parse().map_err(|_| bad())?;
            Ok(format!("{n:04}"))
        }
        RefKind::Pr | RefKind::Issue => {
            let (repo, number) = trimmed.rsplit_once('#').ok_or_else(bad)?;
            let (owner, name) = repo.split_once('/').ok_or_else(bad)?;
            if owner.is_empty() || name.is_empty() || name.contains('/') {
                return Err(bad());
            }
            if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
                return Err(bad());
            }
            let n: u64 = number.parse().map_err(|_| bad())?;
            if n == 0 {
                return Err(bad());
            }
            Ok(format!("{}/{}#{n}", owner.to_ascii_lowercase(), name.to_ascii_lowercase()))
        }
        _ => Ok(trimmed.to_owned()),
    }
}

/// A link target: its identity and what to show for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StableRef {
    pub key: RefKey,
    /// Display only. Never part of identity.
    pub title: String,
}

impl StableRef {
    pub fn new(
        kind: RefKind,
        source: RefSource,
        id: &str,
        title: impl Into<String>,
    ) -> Result<Self, RefError> {
        Ok(Self { key: RefKey::new(kind, source, id)?, title: title.into() })
    }

    pub fn rfd(number: u32, title: impl Into<String>) -> Self {
        Self {
            key: RefKey { kind: RefKind::Rfd, source: RefSource::Hq, id: format!("{number:04}") },
            title: title.into(),
        }
    }

    pub fn same_target(&self, other: &StableRef) -> bool {
        self.key == other.key
    }
}

/// Every link, readable from both ends.
#[derive(Debug, Clone, Default)]
pub struct LinkGraph {
    edges: BTreeMap<RefKey, BTreeSet<RefKey>>,
}

impl LinkGraph {
    pub fn new() -> Self {
        Self::default()
    }

    /// Link `a` and `b` both ways. Returns whether it was new; a self-link is refused (false).
    pub fn link(&mut self, a: &RefKey, b: &RefKey) -> bool {
        if a == b {
            return false;
        }
        let new = self.edges.entry(a.clone()).or_default().insert(b.clone());
        self.edges.entry(b.clone()).or_default().insert(a.clone());
        new
    }

    /// Remove the link from both ends. Returns whether it existed.
    pub fn unlink(&mut self, a: &RefKey, b: &RefKey) -> bool {
        let had = self.edges.get_mut(a).is_some_and(|s| s.remove(b));
        if let Some(s) = self.edges.get_mut(b) {
            s.remove(a);
        }
        self.edges.retain(|_, s| !s.is_empty());
        had
    }

    pub fn linked(&self, a: &RefKey, b: &RefKey) -> bool {
        self.edges.get(a).is_some_and(|s| s.contains(b))
    }

    /// Every ref linked to `of`, in key order, whatever the reader may see.
    pub fn links(&self, of: &RefKey) -> Vec<RefKey> {
        self.edges.get(of).map(|s| s.iter().cloned().collect()).unwrap_or_default()
    }

    /// The refs linked to `of` that the reader can read. A link never shows a reader a target their
    /// own permission does not reach.
    pub fn visible_links(&self, of: &RefKey, can_read: impl Fn(&RefKey) -> bool) -> Vec<RefKey> {
        self.edges
            .get(of)
            .map(|s| s.iter().filter(|k| can_read(k)).cloned().collect())
            .unwrap_or_default()
    }

    /// `of`'s links of one kind: a thread's RFDs, an RFD's sessions.
    pub fn links_of_kind(&self, of: &RefKey, kind: RefKind) -> Vec<RefKey> {
        self.edges
            .get(of)
            .map(|s| s.iter().filter(|k| k.kind == kind).cloned().collect())
            .unwrap_or_default()
    }

    /// Number of distinct links.
    pub fn len(&self) -> usize {
        self.edges.values().map(BTreeSet::len).sum::<usize>() / 2
    }

    pub fn is_empty(&self) -> bool {
        self.edges.is_empty()
    }
}
