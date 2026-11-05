//! What earlier imports made, so a rerun is safe: a workspace recorded as
//! done never comes over twice, and one a run was cut off making (pending)
//! is closed and made again. Modeled on the classic migration's ledger.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// The ledger layout this build writes.
pub const VERSION: u32 = 1;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ledger {
    pub version: u32,
    /// Completed runs.
    pub runs: u32,
    /// By Conductor repo id: the project path it became.
    #[serde(default)]
    pub projects: BTreeMap<String, String>,
    /// By Conductor workspace id.
    #[serde(default)]
    pub workspaces: BTreeMap<String, Entry>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub stage: Stage,
    /// The cmux workspace made for it, once made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_workspace: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    /// A run started making it and has not finished.
    Pending,
    Done,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Load {
    /// No ledger yet: nothing was imported.
    None,
    Ledger(Ledger),
    /// Written by a newer cmux: left alone.
    Newer(u32),
    Unreadable(String),
}

impl Ledger {
    pub fn new() -> Self {
        Self { version: VERSION, ..Self::default() }
    }

    pub fn load(path: &Path) -> Load {
        match std::fs::read(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Load::None,
            Err(error) => Load::Unreadable(error.to_string()),
            Ok(bytes) => Self::decode(&bytes),
        }
    }

    pub fn decode(bytes: &[u8]) -> Load {
        #[derive(Deserialize)]
        struct Header {
            version: u32,
        }
        match serde_json::from_slice::<Header>(bytes) {
            Ok(header) if header.version > VERSION => Load::Newer(header.version),
            Ok(_) => match serde_json::from_slice::<Ledger>(bytes) {
                Ok(ledger) => Load::Ledger(ledger),
                Err(error) => Load::Unreadable(error.to_string()),
            },
            Err(error) => Load::Unreadable(error.to_string()),
        }
    }

    /// Writes the ledger whole or not at all (a temporary file renamed over).
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let bytes = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
        std::fs::write(&temporary, bytes)?;
        std::fs::rename(&temporary, path)
    }

    pub fn mark_pending(&mut self, workspace: &str) {
        self.workspaces
            .insert(workspace.into(), Entry { stage: Stage::Pending, cmux_workspace: None });
    }

    pub fn mark_done(&mut self, workspace: &str, cmux_workspace: &str) {
        self.workspaces.insert(
            workspace.into(),
            Entry { stage: Stage::Done, cmux_workspace: Some(cmux_workspace.into()) },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_newer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("conductor-import.json");
        assert_eq!(Ledger::load(&path), Load::None);
        let mut ledger = Ledger::new();
        ledger.mark_pending("w1");
        ledger.mark_done("w2", "ws-9");
        ledger.save(&path).unwrap();
        assert_eq!(Ledger::load(&path), Load::Ledger(ledger));
        assert_eq!(Ledger::decode(br#"{"version":99,"runs":0}"#), Load::Newer(99));
        assert!(matches!(Ledger::decode(b"{"), Load::Unreadable(_)));
    }
}
