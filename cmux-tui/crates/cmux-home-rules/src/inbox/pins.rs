//! The person's pin order (`HomePins`): which rows sit pinned, in what order, and the Cloud
//! positions a drag numbered.

use super::model::{Row, RowKind};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

/// `HomePins` as Swift encodes it (`unpinned` is a set; it comes back sorted).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Pins {
    pub pinned: Vec<String>,
    pub unpinned: BTreeSet<String>,
    #[serde(default)]
    pub positions: BTreeMap<String, u64>,
}

impl Pins {
    /// `HomePins.isPinned`: the person's choice wins, else Chiefs and owner pins are pinned.
    pub fn is_pinned(&self, row: &Row) -> bool {
        if self.pinned.contains(&row.id) {
            return true;
        }
        if self.unpinned.contains(&row.id) {
            return false;
        }
        row.kind == RowKind::Chief || row.is_pinned
    }

    /// `HomePins.split`: pinned rows in pin order (unordered ones after, as given), the rest
    /// newest first, ties by id.
    pub fn split<'a>(&self, rows: &'a [Row]) -> (Vec<&'a Row>, Vec<&'a Row>) {
        let mut order: HashMap<&str, usize> = HashMap::new();
        for (index, id) in self.pinned.iter().enumerate() {
            order.entry(id.as_str()).or_insert(index);
        }
        let mut pinned: Vec<(usize, &Row)> =
            rows.iter().filter(|row| self.is_pinned(row)).enumerate().collect();
        pinned.sort_by_key(|(offset, row)| {
            (order.get(row.id.as_str()).copied().unwrap_or(usize::MAX), *offset)
        });
        let mut rest: Vec<&Row> = rows.iter().filter(|row| !self.is_pinned(row)).collect();
        rest.sort_by(|a, b| {
            b.timestamp
                .partial_cmp(&a.timestamp)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.id.cmp(&b.id))
        });
        (pinned.into_iter().map(|(_, row)| row).collect(), rest)
    }

    /// `HomePins.setPinned`.
    pub fn set_pinned(&mut self, on: bool, row: &Row) {
        if on && self.is_pinned(row) {
            return;
        }
        self.pinned.retain(|id| id != &row.id);
        self.unpinned.remove(&row.id);
        self.positions.remove(&row.id);
        if on {
            self.pinned.push(row.id.clone());
        } else if row.kind == RowKind::Chief || row.is_pinned {
            self.unpinned.insert(row.id.clone());
        }
    }

    /// `HomePins.place(_:at:shown:)`: a drag dropped `id` at `index` of the shown pinned rows.
    pub fn place(&mut self, id: &str, index: i64, shown: &[String]) {
        let mut order: Vec<String> = shown.iter().filter(|s| *s != id).cloned().collect();
        let at = index.clamp(0, order.len() as i64) as usize;
        order.insert(at, id.to_owned());
        self.arrange(&order, &[]);
    }

    /// `HomePins.arrange(_:positions:)`.
    pub fn arrange(&mut self, order: &[String], numbered: &[u64]) {
        let placed: HashSet<&String> = order.iter().collect();
        let mut pinned = order.to_vec();
        pinned.extend(self.pinned.iter().filter(|id| !placed.contains(id)).cloned());
        self.pinned = pinned;
        self.unpinned.retain(|id| !placed.contains(id));
        for (id, position) in order.iter().zip(numbered) {
            self.positions.insert(id.clone(), *position);
        }
    }

    /// `HomePins.leading`: the main Chief leads the pinned rows until the person places it.
    pub fn leading<'a>(&self, main: Option<&'a str>) -> Option<&'a str> {
        main.filter(|main| !self.pinned.iter().any(|id| id == main))
    }
}
