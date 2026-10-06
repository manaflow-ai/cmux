//! The local search index (stub).

use std::ops::Range;
use std::path::Path;

use crate::error::HistoryError;

/// What a search hit is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SearchKind {
    Chat,
    Command,
    Scrollback,
    Tab,
    Workspace,
}

impl SearchKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Command => "command",
            Self::Scrollback => "scrollback",
            Self::Tab => "tab",
            Self::Workspace => "workspace",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchDoc {
    pub key: String,
    pub source: String,
    pub kind: SearchKind,
    pub target: String,
    pub position: Option<i64>,
    pub title: String,
    pub text: String,
    pub at_ms: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchHit {
    pub key: String,
    pub kind: SearchKind,
    pub target: String,
    pub position: Option<i64>,
    pub title: String,
    pub snippet: String,
    pub highlights: Vec<Range<usize>>,
    pub at_ms: i64,
}

pub trait SearchFeed {
    fn sources(&self) -> Result<Vec<String>, HistoryError>;
    fn read(
        &self,
        source: &str,
        after: Option<i64>,
        max: usize,
    ) -> Result<(Vec<SearchDoc>, i64), HistoryError>;
}

pub struct SearchIndex;

impl SearchIndex {
    pub fn open(_path: &Path) -> Result<Self, HistoryError> {
        Ok(Self)
    }
    pub fn open_in_memory() -> Result<Self, HistoryError> {
        Ok(Self)
    }
    pub fn append(
        &mut self,
        _source: &str,
        _docs: &[SearchDoc],
        _cursor: Option<i64>,
    ) -> Result<(), HistoryError> {
        Ok(())
    }
    pub fn upsert(&mut self, _doc: &SearchDoc) -> Result<(), HistoryError> {
        Ok(())
    }
    pub fn remove_source(&mut self, _source: &str) -> Result<(), HistoryError> {
        Ok(())
    }
    pub fn cursor(&self, _source: &str) -> Result<Option<i64>, HistoryError> {
        Ok(None)
    }
    pub fn search(
        &self,
        _query: &str,
        _kinds: &[SearchKind],
        _limit: usize,
    ) -> Result<Vec<SearchHit>, HistoryError> {
        Ok(Vec::new())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BackfillStep {
    pub indexed: usize,
    pub done: bool,
}

pub struct Backfill;

impl Backfill {
    pub fn step(
        _index: &mut SearchIndex,
        _feed: &dyn SearchFeed,
        _budget: usize,
    ) -> Result<BackfillStep, HistoryError> {
        Ok(BackfillStep { indexed: 0, done: true })
    }
}

#[cfg(test)]
#[path = "search_index_tests.rs"]
mod tests;
