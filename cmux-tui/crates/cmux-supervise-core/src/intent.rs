//! An intentional stop (F17): a person's Quit, `stop`, `shutdown`. It is written down before
//! the stop, so the supervisor that sees the process go reads "meant", not "crashed", and never
//! starts it again. Only an explicit start clears it.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The record of a stop someone meant.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StopIntent {
    /// Who or what asked: "person quit", "acpmux daemon shutdown", ...
    pub reason: String,
    /// The owner record's epoch the stop was meant for; a newer start is not stopped by it.
    pub epoch: u64,
    pub at_ms: u64,
}

/// The intent file of one supervised thing.
#[derive(Clone, Debug)]
pub struct Intent {
    path: PathBuf,
}

impl Intent {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Write down that the owner of `epoch` is being stopped on purpose.
    pub fn record(&self, reason: &str, epoch: u64) -> std::io::Result<()> {
        self.record_with(reason, epoch, &crate::record::write_file)
    }

    /// [`Self::record`] through the caller's own atomic writer.
    pub fn record_with(
        &self,
        reason: &str,
        epoch: u64,
        write: crate::record::Writer<'_>,
    ) -> std::io::Result<()> {
        let intent =
            StopIntent { reason: reason.to_owned(), epoch, at_ms: crate::budget::now_ms() };
        let bytes = serde_json::to_vec(&intent).map_err(std::io::Error::other)?;
        write(&self.path, &bytes)
    }

    /// The standing intent, if any.
    pub fn read(&self) -> Option<StopIntent> {
        serde_json::from_slice(&std::fs::read(&self.path).ok()?).ok()
    }

    /// Whether the stop of the owner of `epoch` was meant. An intent file that is there but
    /// cannot be read or parsed counts as meant (fail closed): a stop someone asked for is never
    /// undone by a file this crate cannot read. Only an explicit start ([`Self::clear`]) ends it.
    pub fn meant(&self, epoch: u64) -> Option<StopIntent> {
        match std::fs::read(&self.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => Some(Self::unreadable(epoch, &e.to_string())),
            Ok(bytes) => match serde_json::from_slice::<StopIntent>(&bytes) {
                Ok(i) => Some(i).filter(|i| i.epoch >= epoch),
                Err(e) => Some(Self::unreadable(epoch, &e.to_string())),
            },
        }
    }

    fn unreadable(epoch: u64, why: &str) -> StopIntent {
        StopIntent { reason: format!("a stop intent that cannot be read ({why})"), epoch, at_ms: 0 }
    }

    /// An explicit start: the intent no longer stands.
    pub fn clear(&self) -> std::io::Result<()> {
        match std::fs::remove_file(&self.path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_intent_covers_its_epoch_and_older_never_a_newer_start() {
        let dir = std::env::temp_dir().join(format!("supervise-intent-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let intent = Intent::new(dir.join("stop-intent.json"));
        assert!(intent.meant(1).is_none());
        intent.record("person quit", 3).unwrap();
        assert_eq!(intent.meant(3).unwrap().reason, "person quit");
        assert!(intent.meant(2).is_some());
        assert!(intent.meant(4).is_none(), "a start after the quit is not covered");
        intent.clear().unwrap();
        intent.clear().unwrap();
        assert!(intent.read().is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_intent_file_that_does_not_parse_still_means_stop() {
        let dir =
            std::env::temp_dir().join(format!("supervise-intent-torn-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let intent = Intent::new(dir.join("stop-intent.json"));
        std::fs::write(intent.path(), b"{\"reason\": \"person q").unwrap();
        assert!(intent.meant(7).unwrap().reason.contains("cannot be read"));
        intent.clear().unwrap();
        assert!(intent.meant(7).is_none(), "an explicit start ends it");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
