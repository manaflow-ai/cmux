//! The sidebar's destinations in shown order, moved from Swift's `SidebarModel+ItemOrder.swift` and
//! `SidebarItemOrder` (`SidebarItem.swift`, SIDEBAR-SELECTION-ONE-MODEL).
//!
//! The app lays the list out (`SidebarLayout.make`, the band's shown items) and passes the row keys in; these
//! rules decide which rows are stops (a selectable workspace, a link or app row, a shown block's items, a
//! collapsed group with selectable members standing for them), which band items count before the list, where a
//! workspace with no stop of its own draws among the stops, and what Cmd-1...9, a digit hint and Cmd-Ctrl-[ / ]
//! select. The app keeps the cache and the layout.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One destination (`SidebarItem`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Item {
    TopItem(String),
    Group(String),
    Workspace(String),
}

impl Item {
    fn is_top(&self) -> bool {
        matches!(self, Item::TopItem(_))
    }
}

/// The destinations in shown order (`SidebarItemOrder`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Order {
    #[serde(default)]
    pub top_items: Vec<Item>,
    #[serde(default)]
    pub rows: Vec<Item>,
    /// The stop that stands for a workspace without its own row (a member of a collapsed group).
    #[serde(default)]
    pub stops: BTreeMap<String, Item>,
}

/// Which items a walk counts (`SidebarNavigationSettings.Scope`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    #[default]
    AllItems,
    WorkspacesOnly,
}

/// What Cmd-9 picks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NinthKey {
    #[default]
    Last,
    Ninth,
}

/// `SidebarNavigationSettings`, with its defaults.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default)]
    pub numbering: Scope,
    #[serde(default)]
    pub cmd9: NinthKey,
    #[serde(default)]
    pub stepping: Scope,
    #[serde(default = "yes")]
    pub stepping_wraps: bool,
}

fn yes() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            numbering: Scope::AllItems,
            cmd9: NinthKey::Last,
            stepping: Scope::AllItems,
            stepping_wraps: true,
        }
    }
}

impl Order {
    /// Every item: the top items, then the rows.
    pub fn items(&self) -> Vec<Item> {
        self.top_items.iter().chain(&self.rows).cloned().collect()
    }

    /// The walked list: every item, or only the rows that are not top items.
    pub fn scoped(&self, scope: Scope) -> Vec<Item> {
        match scope {
            Scope::AllItems => self.items(),
            Scope::WorkspacesOnly => {
                self.rows.iter().filter(|item| !item.is_top()).cloned().collect()
            }
        }
    }

    /// The stop `item` is at (a workspace in a collapsed group: the group).
    pub fn stop(&self, item: Option<&Item>) -> Option<Item> {
        let item = item?;
        if self.top_items.contains(item) || self.rows.contains(item) {
            return Some(item.clone());
        }
        match item {
            Item::Workspace(id) => self.stops.get(id).cloned(),
            _ => None,
        }
    }

    /// Whether selecting `item` shows the list from its very top: a top item, or a row with only top items before it.
    pub fn reveals_top(&self, item: Option<&Item>) -> bool {
        let Some(stop) = self.stop(item) else { return false };
        if self.top_items.contains(&stop) {
            return true;
        }
        let Some(index) = self.rows.iter().position(|row| *row == stop) else { return false };
        self.rows.get(..index).unwrap_or_default().iter().all(Item::is_top)
    }

    /// The item Cmd-`number` selects: 1...8 count in order; 9 is the last or the ninth; past the end the last with
    /// `last`, nothing with `ninth`. Nil below 1 or for an empty order.
    pub fn pick(&self, number: i64, settings: Settings) -> Option<Item> {
        let list = self.scoped(settings.numbering);
        let last = list.last()?.clone();
        if number < 1 {
            return None;
        }
        if settings.cmd9 == NinthKey::Last && number >= 9 {
            return Some(last);
        }
        if let Some(item) = usize::try_from(number)
            .ok()
            .filter(|n| *n <= list.len())
            .and_then(|n| list.get(n - 1).cloned())
        {
            return Some(item);
        }
        (settings.cmd9 == NinthKey::Last).then_some(last)
    }

    /// The digit whose Cmd-digit selects `item` (the inverse of [`Order::pick`]).
    pub fn number(&self, item: &Item, settings: Settings) -> Option<i64> {
        let list = self.scoped(settings.numbering);
        let index = list.iter().position(|entry| entry == item)?;
        if index < 8 || (index == 8 && settings.cmd9 == NinthKey::Ninth) {
            return i64::try_from(index + 1).ok();
        }
        (settings.cmd9 == NinthKey::Last && index == list.len() - 1).then_some(9)
    }

    /// The item `offset` steps from `selected`. From outside the walked list (or none), +1 starts at the first and -1
    /// at the last. Past an end: wraps, or none when wrapping is off. `place`, for a workspace drawn away from its
    /// stop: the index in `rows` it draws before, so the walk goes on from there.
    pub fn step(
        &self,
        selected: Option<&Item>,
        offset: i64,
        settings: Settings,
        place: Option<usize>,
    ) -> Option<Item> {
        let mut list = self.scoped(settings.stepping);
        if list.is_empty() || offset == 0 {
            return None;
        }
        let next: i64 = match (selected, place) {
            (Some(Item::Workspace(id)), Some(place)) => {
                let own = Item::Workspace(id.clone());
                list.retain(|item| *item != own);
                if list.is_empty() {
                    return None;
                }
                let walked = |item: &Item| -> bool {
                    if *item == own {
                        return false;
                    }
                    settings.stepping == Scope::AllItems || !item.is_top()
                };
                let top =
                    if settings.stepping == Scope::AllItems { self.top_items.len() } else { 0 };
                let before = top
                    + self
                        .rows
                        .get(..place.min(self.rows.len()))
                        .unwrap_or_default()
                        .iter()
                        .filter(|item| walked(item))
                        .count();
                let before = i64::try_from(before).unwrap_or(i64::MAX);
                if offset > 0 { before + offset - 1 } else { before + offset }
            }
            _ => match self
                .stop(selected)
                .and_then(|current| list.iter().position(|item| *item == current))
            {
                Some(index) => i64::try_from(index).unwrap_or(i64::MAX).saturating_add(offset),
                None => {
                    return if offset > 0 { list.first().cloned() } else { list.last().cloned() };
                }
            },
        };
        let count = i64::try_from(list.len()).unwrap_or(i64::MAX);
        if (0..count).contains(&next) {
            return usize::try_from(next).ok().and_then(|n| list.get(n).cloned());
        }
        if !settings.stepping_wraps {
            return None;
        }
        usize::try_from(next.rem_euclid(count)).ok().and_then(|n| list.get(n).cloned())
    }
}

/// A row key of the laid-out list (`SidebarLayout` row `key`): `workspace`, `item`, `block`, `group`, or any other
/// kind (headers, folds), which is no stop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RowKey {
    pub kind: String,
    #[serde(default)]
    pub id: String,
}

/// A group the rows may name: whether it is collapsed and its workspaces in order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    #[serde(default)]
    pub collapsed: bool,
    #[serde(default)]
    pub members: Vec<String>,
}

/// What the order is made of: the laid-out row keys, the band's shown top items and the blocks they draw in.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct Source {
    #[serde(default)]
    pub rows: Vec<RowKey>,
    #[serde(default)]
    pub selectable: BTreeSet<String>,
    /// Collapsed document sections (their block draws no stops).
    #[serde(default)]
    pub collapsed_blocks: BTreeSet<String>,
    #[serde(default)]
    pub groups: BTreeMap<String, Group>,
    /// The band's shown items, in order.
    #[serde(default)]
    pub top: Vec<String>,
    /// The band items by the section they are placed in.
    #[serde(default)]
    pub in_block: BTreeMap<String, Vec<String>>,
    /// The document sections the list draws (their items are stops where the block draws).
    #[serde(default)]
    pub listed: BTreeSet<String>,
}

/// The list's selectable rows in drawn order, and the stop that stands for each collapsed group's members.
pub fn order_rows(source: &Source) -> (Vec<Item>, BTreeMap<String, Item>) {
    let mut rows = Vec::new();
    let mut stops = BTreeMap::new();
    for row in &source.rows {
        match row.kind.as_str() {
            "workspace" if source.selectable.contains(&row.id) => {
                rows.push(Item::Workspace(row.id.clone()));
            }
            "item" => rows.push(Item::TopItem(row.id.clone())),
            "block" if !source.collapsed_blocks.contains(&row.id) => {
                let items = source.in_block.get(&row.id).into_iter().flatten();
                rows.extend(items.map(|item| Item::TopItem(item.clone())));
            }
            "group" => {
                let Some(group) = source.groups.get(&row.id).filter(|group| group.collapsed) else {
                    continue;
                };
                let members: Vec<&String> = group
                    .members
                    .iter()
                    .filter(|member| source.selectable.contains(*member))
                    .collect();
                if members.is_empty() {
                    continue;
                }
                rows.push(Item::Group(row.id.clone()));
                for member in members {
                    stops.insert(member.clone(), Item::Group(row.id.clone()));
                }
            }
            _ => {}
        }
    }
    (rows, stops)
}

/// The band items that count before the list: those whose block the list does not draw.
pub fn top_items(source: &Source) -> Vec<Item> {
    source
        .top
        .iter()
        .filter(|item| {
            let block = source
                .in_block
                .iter()
                .find(|(_, items)| items.contains(item))
                .map_or("", |(id, _)| id.as_str());
            !source.listed.contains(block)
        })
        .map(|item| Item::TopItem(item.clone()))
        .collect()
}

/// The order (`makeItemOrder`).
pub fn make(source: &Source) -> Order {
    let (rows, stops) = order_rows(source);
    Order { top_items: top_items(source), rows, stops }
}

/// Where `id` draws among `order_rows` when it is active: the index after the last stop drawn before it in `drawn`
/// (the rows laid out with it active), 0 when none is. None when even then it draws nowhere.
pub fn drawn_place(order_rows: &[Item], drawn: &[Item], id: &str) -> Option<usize> {
    let own = Item::Workspace(id.to_owned());
    let at = drawn.iter().position(|item| *item == own)?;
    let mut index: HashMap<&Item, usize> = HashMap::new();
    for (i, item) in order_rows.iter().enumerate() {
        index.entry(item).or_insert(i);
    }
    Some(
        drawn
            .get(..at)
            .unwrap_or_default()
            .iter()
            .rev()
            .find_map(|item| index.get(item))
            .map_or(0, |i| i + 1),
    )
}

/// A request to the `sidebar_item_order` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{top_items, rows, stops}`.
    Make {
        #[serde(flatten)]
        source: Source,
    },
    /// `{place}` (null: drawn nowhere).
    DrawnPlace {
        #[serde(default)]
        order_rows: Vec<Item>,
        #[serde(default)]
        drawn: Vec<Item>,
        id: String,
    },
    /// `{item}`.
    Pick {
        order: Order,
        number: i64,
        #[serde(default)]
        settings: Settings,
    },
    /// `{number}`.
    Number {
        order: Order,
        item: Item,
        #[serde(default)]
        settings: Settings,
    },
    /// `{item}`.
    Step {
        order: Order,
        #[serde(default)]
        selected: Option<Item>,
        offset: i64,
        #[serde(default)]
        settings: Settings,
        #[serde(default)]
        place: Option<usize>,
    },
    /// `{stop, reveals_top}`.
    Stop {
        order: Order,
        #[serde(default)]
        item: Option<Item>,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::Make { source } => json!(make(&source)),
        Request::DrawnPlace { order_rows, drawn, id } => {
            json!({"place": drawn_place(&order_rows, &drawn, &id)})
        }
        Request::Pick { order, number, settings } => json!({"item": order.pick(number, settings)}),
        Request::Number { order, item, settings } => {
            json!({"number": order.number(&item, settings)})
        }
        Request::Step { order, selected, offset, settings, place } => {
            json!({"item": order.step(selected.as_ref(), offset, settings, place)})
        }
        Request::Stop { order, item } => {
            json!({"stop": order.stop(item.as_ref()), "reveals_top": order.reveals_top(item.as_ref())})
        }
    }
}

#[cfg(test)]
#[path = "sidebar_item_order_tests.rs"]
mod tests;
