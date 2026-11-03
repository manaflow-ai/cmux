//! Durable activity identities for the existing code-mode workflow runtime.

use anyhow::Result;
use serde_json::Value;
use std::path::Path;

/// The next activity is either already finished or belongs to this stable identity.
#[derive(Debug, Clone, PartialEq)]
pub enum Activity {
    Replay(Result<Value, Value>),
    Work { id: String, recovered: bool },
}

/// One exclusive execution of a pinned workflow script.
pub struct Journal;

impl Journal {
    pub fn open(_directory: &Path, _source: &str, _fresh_call_limit: usize) -> Result<Self> {
        Ok(Self)
    }

    pub fn begin(&mut self, _kind: &str, _prompt: &str, _options: &Value) -> Result<Activity> {
        Ok(Activity::Work { id: "activity".into(), recovered: false })
    }

    pub fn complete(&mut self, _id: &str, _result: Result<Value, Value>) -> Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests;
