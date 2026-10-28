//! A latest-value feed, updated only when the owner's cached projection
//! changes. Subscribers never start checks, reload profiles or run updates.

use serde_json::{Value, json};
use tokio::sync::watch;

use super::{HarnessHealth, HealthService, inventory};
use crate::no_panic::JsonExt;

#[derive(Clone)]
pub(crate) struct Snapshot {
    revision: u64,
    value: Value,
}

impl Snapshot {
    /// A full partial inventory; revision is scoped to this HealthService run.
    pub(crate) fn wire(&self) -> Value {
        let mut value = self.value.clone();
        value.set("revision", json!(self.revision));
        value
    }
}

pub(super) struct InventoryFeed(watch::Sender<Snapshot>);

impl Default for InventoryFeed {
    fn default() -> Self {
        Self(watch::channel(Snapshot { revision: 0, value: inventory::snapshot(&[]) }).0)
    }
}

impl InventoryFeed {
    fn publish(&self, rows: &[HarnessHealth]) {
        let value = inventory::snapshot(rows);
        self.0.send_if_modified(|known| {
            if known.value == value {
                return false;
            }
            let Some(revision) = known.revision.checked_add(1) else { return false };
            *known = Snapshot { revision, value };
            true
        });
    }
}

impl HealthService {
    /// Subscribes to sanitized cached snapshots. Only the newest value is
    /// retained, including when no consumer exists or a consumer is slow.
    pub(crate) fn inventory_changes(&self) -> watch::Receiver<Snapshot> {
        self.inventory.0.subscribe()
    }

    /// Serializes the cache write and its feed publication under the same lock.
    pub(super) fn replace_rows(&self, rows: Vec<HarnessHealth>) {
        self.update_rows(|current| *current = rows);
    }

    /// Mutates selected observations and publishes their projection in one
    /// critical section, preserving unrelated concurrent owner choices.
    pub(super) fn update_rows<T>(&self, update: impl FnOnce(&mut Vec<HarnessHealth>) -> T) -> T {
        let mut current = self.rows.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let result = update(&mut current);
        self.inventory.publish(&current);
        result
    }
}
