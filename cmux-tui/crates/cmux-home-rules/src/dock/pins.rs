//! Pins and order: `HomePinMigration` (CmuxNextHomeEngine/HomePinMigration.swift), the one-time move
//! of this Mac's pins to the inbox owners, and the pin, order and hide rules of `HomeSidebarSource`
//! (CmuxNextHomeEngine/HomeSidebarSource.swift). The app keeps the stores and makes the owner calls.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// A row an owner lists, and whether it is pinned there.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinRow {
    pub id: String,
    #[serde(default)]
    pub pinned: bool,
}

/// What one `run(inbox)` does.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationRun {
    /// This Mac's pins to drop now: already pinned at the owner.
    pub drop: Vec<String>,
    /// The pins to send (`inbox.adopt(pins:)`); empty: send nothing.
    pub send: Vec<String>,
    /// The ids in flight after this run.
    pub sending: BTreeSet<String>,
}

/// `HomePinMigration.run`: for an inbox reply (`cloud`, `rows`), this Mac's kept pins in order.
pub fn migration_run(
    cloud: Option<&str>,
    rows: &[PinRow],
    kept: &[String],
    sending: &BTreeSet<String>,
    refused: &BTreeSet<String>,
) -> MigrationRun {
    let mut run = MigrationRun { sending: sending.clone(), ..MigrationRun::default() };
    if cloud == Some("unavailable") || rows.is_empty() {
        return run;
    }
    let mut listed: HashMap<&str, bool> = HashMap::new();
    for row in rows {
        listed.entry(row.id.as_str()).or_insert(row.pinned);
    }
    for id in kept {
        if sending.contains(id) || refused.contains(id) {
            continue;
        }
        match listed.get(id.as_str()) {
            Some(true) => run.drop.push(id.clone()),
            Some(false) => run.send.push(id.clone()),
            None => {}
        }
    }
    run.sending.extend(run.send.iter().cloned());
    run
}

/// What an owner's answer to `adopt(pins:)` does.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationAdopted {
    pub sending: BTreeSet<String>,
    pub refused: BTreeSet<String>,
    /// This Mac's pins to drop: the owner took them.
    pub drop: Vec<String>,
}

/// The owner answered the send of `ids` with `accepted`.
pub fn migration_adopted(
    ids: &[String],
    accepted: &[String],
    sending: &BTreeSet<String>,
    refused: &BTreeSet<String>,
) -> MigrationAdopted {
    let mut out = MigrationAdopted {
        sending: sending.clone(),
        refused: refused.clone(),
        drop: accepted.to_vec(),
    };
    for id in ids {
        out.sending.remove(id);
        if !accepted.contains(id) {
            out.refused.insert(id.clone());
        }
    }
    out
}

/// This Mac's pins (`HomePins`' stored part).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Pins {
    pub pinned: Vec<String>,
    pub positions: BTreeMap<String, u64>,
}

/// `drop(_:account:)`: the pins without `gone`.
pub fn drop_pins(mut pins: Pins, gone: &[String]) -> Pins {
    pins.pinned.retain(|id| !gone.contains(id));
    pins.positions.retain(|id, _| !gone.contains(id));
    pins
}

/// A listed row's id and last sequence.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeqRow {
    pub id: String,
    #[serde(default)]
    pub last_seq: u64,
}

/// `shows(_:)`: a hidden row shows again once a message came after it was hidden.
pub fn shows(row: &SeqRow, hidden: &BTreeMap<String, u64>) -> bool {
    hidden.get(&row.id).is_none_or(|&seq| row.last_seq > seq)
}

/// `hide(_:)`: the hidden map with `id` hidden at its row's last sequence; none: the row is not listed.
pub fn hide(
    id: &str,
    rows: &[SeqRow],
    mut hidden: BTreeMap<String, u64>,
) -> Option<BTreeMap<String, u64>> {
    let row = rows.iter().find(|row| row.id == id)?;
    hidden.insert(id.to_owned(), row.last_seq);
    Some(hidden)
}

/// `owner(of:)`: the index of the first inbox whose rows list `id` (an inbox with no reply lists nothing).
pub fn owner_of(id: &str, inboxes: &[Option<Vec<String>>]) -> Option<usize> {
    inboxes
        .iter()
        .position(|rows| rows.as_ref().is_some_and(|rows| rows.iter().any(|row| row == id)))
}

/// A pin's new position.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Placed {
    pub id: String,
    pub position: u64,
}

/// What `place(_:at:)` does.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacePlan {
    /// Per inbox (by index), the positions it keeps (`inbox.place`); an empty list sends nothing.
    pub inboxes: Vec<Vec<Placed>>,
    /// The positions only this Mac keeps (rows no owner lists), in order (`pins.arrange`).
    pub local: Vec<Placed>,
}

/// `place(_:at:)`: `id` moves to `index` of the pinned order (`pinned`, as shown), numbered from `base` (now).
pub fn place(
    pinned: &[String],
    id: &str,
    index: i64,
    base: u64,
    inboxes: &[Option<Vec<String>>],
) -> PlacePlan {
    let mut order: Vec<&str> = pinned.iter().map(String::as_str).filter(|&pin| pin != id).collect();
    let at = usize::try_from(index.max(0)).unwrap_or(usize::MAX).min(order.len());
    order.insert(at, id);
    let mut plan = PlacePlan { inboxes: vec![Vec::new(); inboxes.len()], local: Vec::new() };
    for (offset, pin) in (0u64..).zip(order) {
        let placed = Placed { id: pin.to_owned(), position: base + offset };
        match owner_of(pin, inboxes) {
            Some(inbox) => plan.inboxes[inbox].push(placed),
            None => plan.local.push(placed),
        }
    }
    plan
}

/// `setMarkedUnread` on a row no owner lists: the marks after, or none when nothing changes.
pub fn mark_unread(on: bool, id: &str, marks: &BTreeSet<String>) -> Option<BTreeSet<String>> {
    if marks.contains(id) == on {
        return None;
    }
    let mut marks = marks.clone();
    if on {
        marks.insert(id.to_owned());
    } else {
        marks.remove(id);
    }
    Some(marks)
}
