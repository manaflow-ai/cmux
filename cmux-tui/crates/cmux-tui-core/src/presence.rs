//! Ephemeral collaboration presence: where each connected client points.
//!
//! The hub is deliberately small. It validates nothing about surfaces (the
//! server does that before calling in), it never touches the journal or the
//! registry lock, and it holds only the latest state per client. A daemon
//! restart forgets everything, which is correct for a "look here" signal.
//!
//! Frontends own the mapping from an anchor to pixels. The daemon only stores
//! and fans out anchors, so a new surface kind adds one `PresenceAnchor`
//! variant and nothing else here.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::SurfaceId;

/// Distinct pointer colors a frontend can render; the hub assigns one per client.
pub const PRESENCE_PALETTE_SIZE: u64 = 8;
/// Most updates one client may send inside one second before the hub rejects.
pub const PRESENCE_MAX_UPDATES_PER_SECOND: u32 = 240;
/// Clients that may hold presence state at once.
pub const PRESENCE_MAX_CLIENTS: usize = 256;
/// A pointer that has not moved for this long is dropped from snapshots.
pub const PRESENCE_POINTER_TTL: Duration = Duration::from_secs(60);

/// One point inside a surface, in the surface's own coordinate system.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum PresenceAnchor {
    /// A terminal grid cell. `row` counts from the top of the publisher's
    /// viewport; `scroll_offset` is how many rows that viewport sits above
    /// the live bottom, so a viewer at another offset can shift the row.
    Cell {
        row: u32,
        col: u32,
        #[serde(default)]
        scroll_offset: u64,
    },
    /// A browser or display point in CSS/document pixels.
    Point { x: f64, y: f64 },
}

/// How long a highlight should stay on screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PresenceHighlightMode {
    /// Fades after a couple of seconds; a frontend decides the exact timing.
    Laser,
    /// Stays until the client clears it or disconnects.
    Pin,
}

/// A region one client wants everybody to look at.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
pub struct PresenceHighlight {
    pub start: PresenceAnchor,
    pub end: PresenceAnchor,
    pub mode: PresenceHighlightMode,
}

/// The latest presence state of one client.
#[derive(Clone, Debug, PartialEq)]
pub struct PresenceEntry {
    pub client: u64,
    pub name: Option<String>,
    pub kind: Option<String>,
    /// Palette slot in `0..PRESENCE_PALETTE_SIZE`, stable for the connection.
    pub color: u64,
    /// `None` after a clear: the client is known but points nowhere.
    pub surface: Option<SurfaceId>,
    pub pointer: Option<PresenceAnchor>,
    pub highlight: Option<PresenceHighlight>,
    pub updated_at_ms: u64,
    /// Increments on every accepted change so late events can be discarded.
    pub generation: u64,
}

impl PresenceEntry {
    fn cleared(client: u64, color: u64, generation: u64) -> Self {
        Self {
            client,
            name: None,
            kind: None,
            color,
            surface: None,
            pointer: None,
            highlight: None,
            updated_at_ms: now_ms(),
            generation,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum PresenceUpdateError {
    RateLimited,
    TooManyClients,
}

impl std::fmt::Display for PresenceUpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RateLimited => write!(
                f,
                "rate limited: more than {PRESENCE_MAX_UPDATES_PER_SECOND} presence updates in one second"
            ),
            Self::TooManyClients => {
                write!(f, "too many presence clients (limit {PRESENCE_MAX_CLIENTS})")
            }
        }
    }
}

impl std::error::Error for PresenceUpdateError {}

struct PresenceSlot {
    entry: PresenceEntry,
    last_change: Instant,
    window_started: Instant,
    window_count: u32,
}

#[derive(Default)]
pub struct PresenceHub {
    slots: Mutex<BTreeMap<u64, PresenceSlot>>,
}

/// What one client wants to publish.
pub struct PresenceUpdate {
    pub name: Option<String>,
    pub kind: Option<String>,
    pub surface: SurfaceId,
    pub pointer: Option<PresenceAnchor>,
    pub highlight: Option<PresenceHighlight>,
}

impl PresenceHub {
    /// Replace one client's presence. Returns the entry to broadcast.
    pub fn update(
        &self,
        client: u64,
        update: PresenceUpdate,
    ) -> Result<PresenceEntry, PresenceUpdateError> {
        self.update_at(client, update, Instant::now())
    }

    fn update_at(
        &self,
        client: u64,
        update: PresenceUpdate,
        now: Instant,
    ) -> Result<PresenceEntry, PresenceUpdateError> {
        let mut slots = self.slots.lock().unwrap();
        if !slots.contains_key(&client) && slots.len() >= PRESENCE_MAX_CLIENTS {
            return Err(PresenceUpdateError::TooManyClients);
        }
        let slot = slots.entry(client).or_insert_with(|| PresenceSlot {
            entry: PresenceEntry::cleared(client, client % PRESENCE_PALETTE_SIZE, 0),
            last_change: now,
            window_started: now,
            window_count: 0,
        });
        if now.duration_since(slot.window_started) >= Duration::from_secs(1) {
            slot.window_started = now;
            slot.window_count = 0;
        }
        if slot.window_count >= PRESENCE_MAX_UPDATES_PER_SECOND {
            return Err(PresenceUpdateError::RateLimited);
        }
        slot.window_count += 1;
        slot.last_change = now;
        let entry = &mut slot.entry;
        entry.name = update.name;
        entry.kind = update.kind;
        entry.surface = Some(update.surface);
        entry.pointer = update.pointer;
        entry.highlight = update.highlight;
        entry.updated_at_ms = now_ms();
        entry.generation += 1;
        Ok(entry.clone())
    }

    /// Forget one client. Returns a cleared entry to broadcast when the
    /// client had published anything.
    pub fn clear(&self, client: u64) -> Option<PresenceEntry> {
        let mut slots = self.slots.lock().unwrap();
        let slot = slots.remove(&client)?;
        Some(PresenceEntry::cleared(client, slot.entry.color, slot.entry.generation + 1))
    }

    /// Every client that still points somewhere. Stale pointers are dropped
    /// here rather than by a timer so the hub needs no thread.
    pub fn snapshot(&self) -> Vec<PresenceEntry> {
        self.snapshot_at(Instant::now())
    }

    fn snapshot_at(&self, now: Instant) -> Vec<PresenceEntry> {
        let mut slots = self.slots.lock().unwrap();
        slots.retain(|_, slot| {
            let pinned = slot.entry.highlight.is_some_and(|h| h.mode == PresenceHighlightMode::Pin);
            pinned || now.duration_since(slot.last_change) < PRESENCE_POINTER_TTL
        });
        slots
            .values()
            .filter(|slot| slot.entry.surface.is_some())
            .map(|slot| slot.entry.clone())
            .collect()
    }

    /// Drop every entry that points at a surface that no longer exists.
    /// Returns the cleared entries to broadcast.
    pub fn forget_surface(&self, surface: SurfaceId) -> Vec<PresenceEntry> {
        let mut slots = self.slots.lock().unwrap();
        let mut cleared = Vec::new();
        for slot in slots.values_mut() {
            if slot.entry.surface == Some(surface) {
                slot.entry.surface = None;
                slot.entry.pointer = None;
                slot.entry.highlight = None;
                slot.entry.updated_at_ms = now_ms();
                slot.entry.generation += 1;
                cleared.push(slot.entry.clone());
            }
        }
        cleared
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn update(surface: SurfaceId, row: u32, col: u32) -> PresenceUpdate {
        PresenceUpdate {
            name: Some("ada".into()),
            kind: Some("mac".into()),
            surface,
            pointer: Some(PresenceAnchor::Cell { row, col, scroll_offset: 0 }),
            highlight: None,
        }
    }

    #[test]
    fn update_assigns_a_stable_color_and_bumps_generation() {
        let hub = PresenceHub::default();
        let first = hub.update(11, update(3, 1, 2)).unwrap();
        let second = hub.update(11, update(3, 4, 5)).unwrap();
        assert_eq!(first.color, 11 % PRESENCE_PALETTE_SIZE);
        assert_eq!(second.color, first.color);
        assert_eq!(first.generation, 1);
        assert_eq!(second.generation, 2);
        assert_eq!(second.pointer, Some(PresenceAnchor::Cell { row: 4, col: 5, scroll_offset: 0 }));
        assert_eq!(hub.snapshot().len(), 1);
    }

    #[test]
    fn clear_returns_a_cleared_entry_and_removes_the_slot() {
        let hub = PresenceHub::default();
        hub.update(7, update(3, 0, 0)).unwrap();
        let cleared = hub.clear(7).unwrap();
        assert_eq!(cleared.surface, None);
        assert_eq!(cleared.generation, 2);
        assert!(hub.snapshot().is_empty());
        assert!(hub.clear(7).is_none());
    }

    #[test]
    fn rate_limit_resets_after_one_second() {
        let hub = PresenceHub::default();
        let start = Instant::now();
        for _ in 0..PRESENCE_MAX_UPDATES_PER_SECOND {
            hub.update_at(1, update(3, 0, 0), start).unwrap();
        }
        assert_eq!(
            hub.update_at(1, update(3, 0, 0), start).unwrap_err(),
            PresenceUpdateError::RateLimited
        );
        hub.update_at(1, update(3, 0, 0), start + Duration::from_secs(1)).unwrap();
    }

    #[test]
    fn snapshot_drops_idle_pointers_but_keeps_pins() {
        let hub = PresenceHub::default();
        let start = Instant::now();
        hub.update_at(1, update(3, 0, 0), start).unwrap();
        let mut pinned = update(3, 0, 0);
        pinned.highlight = Some(PresenceHighlight {
            start: PresenceAnchor::Cell { row: 0, col: 0, scroll_offset: 0 },
            end: PresenceAnchor::Cell { row: 0, col: 9, scroll_offset: 0 },
            mode: PresenceHighlightMode::Pin,
        });
        hub.update_at(2, pinned, start).unwrap();
        let later = start + PRESENCE_POINTER_TTL + Duration::from_secs(1);
        let live = hub.snapshot_at(later);
        assert_eq!(live.iter().map(|e| e.client).collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn forget_surface_clears_only_pointers_on_that_surface() {
        let hub = PresenceHub::default();
        hub.update(1, update(3, 0, 0)).unwrap();
        hub.update(2, update(4, 0, 0)).unwrap();
        let cleared = hub.forget_surface(3);
        assert_eq!(cleared.len(), 1);
        assert_eq!(cleared[0].client, 1);
        assert_eq!(cleared[0].surface, None);
        assert_eq!(hub.snapshot().iter().map(|e| e.client).collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn anchors_round_trip_as_tagged_json() {
        let cell: PresenceAnchor =
            serde_json::from_value(serde_json::json!({"kind": "cell", "row": 2, "col": 7}))
                .unwrap();
        assert_eq!(cell, PresenceAnchor::Cell { row: 2, col: 7, scroll_offset: 0 });
        let point: PresenceAnchor =
            serde_json::from_value(serde_json::json!({"kind": "point", "x": 1.5, "y": 2.0}))
                .unwrap();
        assert_eq!(point, PresenceAnchor::Point { x: 1.5, y: 2.0 });
        assert_eq!(
            serde_json::to_value(PresenceHighlightMode::Laser).unwrap(),
            serde_json::json!("laser")
        );
    }
}
