//! The checkpoint record (`GitCheckpoint` in the catalog), what the store
//! keeps beside it, and the retention rule.

use serde::{Deserialize, Serialize};

/// Unpinned records older than this become eligible for pruning.
pub(super) const RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// A repository keeps at most this many records when unpinned ones can go.
pub(super) const RETAINED_PER_REPOSITORY: usize = 50;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Skip {
    pub path: String,
    pub code: SkipCode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum SkipCode {
    NotSelected,
    OverLimit,
    Excluded,
    Credential,
    Ignored,
    NestedRepository,
    Submodule,
    UnsupportedType,
    Unreadable,
}

impl SkipCode {
    /// Whether the path could not be stored at all, rather than being left
    /// out by a rule.
    pub(super) fn unavailable(self) -> bool {
        matches!(
            self,
            Self::NestedRepository | Self::Submodule | Self::UnsupportedType | Self::Unreadable
        )
    }

    /// Whether the skip leaves an eligible path out, so the record is not
    /// complete. Ignored and credential paths were never eligible.
    pub(super) fn breaks_completeness(self) -> bool {
        !matches!(self, Self::Ignored | Self::Credential)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Pin {
    pub pin_id: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Base {
    pub head: Option<String>,
    pub branch: Option<String>,
    pub detached: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Coverage {
    pub included: u32,
    pub omitted: u32,
    pub unavailable: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Included {
    pub tracked: u32,
    pub untracked: u32,
    pub staged_entries: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Bytes {
    pub logical: u32,
    pub newly_stored: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Limits {
    pub max_bytes: u32,
    pub max_files: u32,
    pub max_untracked_file_bytes: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self { max_bytes: 128 * 1024 * 1024, max_files: 1000, max_untracked_file_bytes: 10_000_000 }
    }
}

/// The public record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Checkpoint {
    pub checkpoint_id: String,
    pub repository_id: String,
    pub worktree_id: String,
    #[serde(rename = "ref")]
    pub reference: String,
    pub object_id: String,
    pub revision: String,
    pub complete: bool,
    pub skipped: Vec<Skip>,
    pub skipped_total: u32,
    pub created_at: String,
    pub expires_at: Option<String>,
    pub base: Base,
    pub coverage: Coverage,
    pub included: Included,
    pub bytes: Bytes,
    pub limits: Limits,
    pub pins: Vec<Pin>,
}

/// One stored checkpoint: the public record and the owner's own fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Stored {
    pub record: Checkpoint,
    pub created_at_ms: u64,
    pub revision: u64,
}

impl Stored {
    /// Sets the record's revision and expiry from the stored fields.
    pub(super) fn settle(&mut self) {
        self.record.revision = self.revision.to_string();
        self.record.expires_at = self
            .record
            .pins
            .is_empty()
            .then(|| rfc3339(self.created_at_ms.saturating_add(RETENTION_MS)));
    }

    pub(super) fn pinned(&self) -> bool {
        !self.record.pins.is_empty()
    }

    /// The list order: newest first, ties by id.
    pub(super) fn order_key(&self) -> (u64, String) {
        (self.created_at_ms, self.record.checkpoint_id.clone())
    }
}

/// Which of a repository's records retention removes now: unpinned records
/// older than [`RETENTION_MS`], then the oldest unpinned ones while the
/// repository holds more than [`RETAINED_PER_REPOSITORY`]. Pins are never
/// pruned, even when they keep the repository over its target.
pub(super) fn prunable(records: &[Stored], now_ms: u64) -> Vec<String> {
    let mut oldest_first = records.iter().collect::<Vec<_>>();
    oldest_first.sort_by_key(|stored| stored.order_key());
    let mut remaining = oldest_first.len();
    let mut pruned = Vec::new();
    for stored in oldest_first {
        if stored.pinned() {
            continue;
        }
        let expired = now_ms.saturating_sub(stored.created_at_ms) > RETENTION_MS;
        if expired || remaining > RETAINED_PER_REPOSITORY {
            pruned.push(stored.record.checkpoint_id.clone());
            remaining -= 1;
        }
    }
    pruned
}

pub(super) fn saturate(value: u64) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// Milliseconds since the Unix epoch.
pub(super) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// RFC 3339 in UTC with milliseconds, for example 2026-10-02T12:00:00.000Z.
pub(super) fn rfc3339(ms: u64) -> String {
    let seconds = ms / 1000;
    let days = i64::try_from(seconds / 86_400).unwrap_or(i64::MAX / 2);
    let of_day = seconds % 86_400;
    // Howard Hinnant's civil_from_days.
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        of_day / 3600,
        of_day % 3600 / 60,
        of_day % 60,
        ms % 1000
    )
}
