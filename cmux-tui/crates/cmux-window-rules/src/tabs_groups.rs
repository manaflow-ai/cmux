//! A tab strip's groups and its local reducer: pinned tabs first and never grouped, each group's
//! members kept together at its first member, one chip before each group, the selection leaving a
//! collapsing group, and how every strip intent (select, close, reorder, new tab, duplicate, pin,
//! the group verbs) changes the strip. The macOS strip (`TabGroupOrdering`, `TabStripModel.apply`)
//! asks these over the JSON channel (ops `tab_groups_*`); the strip keeps its titles and icons and
//! sends only what the rules read.

use std::collections::{BTreeSet, HashMap, HashSet};

use serde::{Deserialize, Serialize};

/// A tab as the group rules see it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tab {
    pub id: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// `playing` or `muted`; none when the tab makes no sound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<Audio>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Audio {
    Playing,
    Muted,
}

/// A group as the rules see it. `tint` is the color's wire form, carried as the strip sent it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tint: Option<String>,
    #[serde(default)]
    pub collapsed: bool,
    #[serde(default)]
    pub saved: bool,
}

/// Pinned tabs first (group cleared), then unpinned tabs in order with each group's members moved
/// up to its first member. A tab naming a group not in `groups` becomes ungrouped.
pub fn normalized(tabs: &[Tab], groups: &HashSet<String>) -> Vec<Tab> {
    let mut pinned = Vec::new();
    let mut units: Vec<Vec<Tab>> = Vec::new();
    let mut unit_of_group: HashMap<String, usize> = HashMap::new();
    for tab in tabs {
        let mut tab = tab.clone();
        if tab.pinned || tab.group.as_ref().is_some_and(|group| !groups.contains(group)) {
            tab.group = None;
        }
        if tab.pinned {
            pinned.push(tab);
        } else if let Some(unit) = tab
            .group
            .as_ref()
            .and_then(|group| unit_of_group.get(group))
            .and_then(|&unit| units.get_mut(unit))
        {
            unit.push(tab);
        } else {
            if let Some(group) = &tab.group {
                unit_of_group.insert(group.clone(), units.len());
            }
            units.push(vec![tab]);
        }
    }
    pinned.into_iter().chain(units.into_iter().flatten()).collect()
}

/// One item of a strip's layout: a group's chip, or a tab.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LayoutItem {
    Chip {
        group: String,
    },
    #[serde(rename_all = "camelCase")]
    Tab {
        id: String,
        pinned: bool,
        selected: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        group: Option<String>,
        collapsed: bool,
    },
}

/// Layout items for `tabs` in display order, a chip before each group's first member; members of
/// collapsed groups are marked collapsed. The strip measures each chip's width itself.
pub fn layout_items(tabs: &[Tab], groups: &[Group], selected: Option<&str>) -> Vec<LayoutItem> {
    let by_id: HashMap<&str, &Group> =
        groups.iter().map(|group| (group.id.as_str(), group)).collect();
    let mut items = Vec::with_capacity(tabs.len().saturating_add(groups.len()));
    let mut previous: Option<&str> = None;
    let mut seen: HashSet<&str> = HashSet::new();
    for tab in tabs {
        let group = if tab.pinned {
            None
        } else {
            tab.group.as_deref().and_then(|id| by_id.get(id).copied())
        };
        if let Some(group) = group
            && previous != Some(group.id.as_str())
            && seen.insert(group.id.as_str())
        {
            items.push(LayoutItem::Chip { group: group.id.clone() });
        }
        items.push(LayoutItem::Tab {
            id: tab.id.clone(),
            pinned: tab.pinned,
            selected: Some(tab.id.as_str()) == selected,
            group: group.map(|group| group.id.clone()),
            collapsed: group.is_some_and(|group| group.collapsed),
        });
        previous = group.map(|group| group.id.as_str());
    }
    items
}

/// When `group` collapses over the selection: the nearest tab to the right outside it (and not in
/// another collapsed group), else to the left. The selection itself when it is not in `group`;
/// none when every visible tab is in it (the strip opens a new tab).
pub fn selection_after_collapsing(
    group: &str,
    ordered: &[Tab],
    collapsed: &BTreeSet<String>,
    selected: Option<&str>,
) -> Option<String> {
    let selected = selected?;
    let Some(index) = ordered.iter().position(|tab| tab.id == selected) else {
        return Some(selected.to_owned());
    };
    if ordered.get(index).and_then(|tab| tab.group.as_deref()) != Some(group) {
        return Some(selected.to_owned());
    }
    let visible = |tab: &&Tab| match tab.group.as_deref() {
        None => true,
        Some(other) => other != group && !collapsed.contains(other),
    };
    if let Some(right) = ordered.iter().skip(index.saturating_add(1)).find(visible) {
        return Some(right.id.clone());
    }
    ordered.iter().take(index).rev().find(visible).map(|tab| tab.id.clone())
}

/// The tab to select before `group` collapses over `selected`, for a strip that cannot open a new
/// tab: the nearest visible one, else the first tab outside the group (selecting it expands its own
/// collapsed group). None when nothing changes or every tab is in `group`.
pub fn selection_before_collapsing(
    group: &str,
    ordered: &[Tab],
    collapsed: &BTreeSet<String>,
    selected: Option<&str>,
) -> Option<String> {
    let selected = selected?;
    if ordered.iter().find(|tab| tab.id == selected)?.group.as_deref() != Some(group) {
        return None;
    }
    selection_after_collapsing(group, ordered, collapsed, Some(selected)).or_else(|| {
        ordered.iter().find(|tab| tab.group.as_deref() != Some(group)).map(|tab| tab.id.clone())
    })
}

/// A strip's tabs, groups and selection.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Strip {
    pub tabs: Vec<Tab>,
    #[serde(default)]
    pub groups: Vec<Group>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
}

/// What the local reducer applies. `made` is the tab the strip makes for an intent that opens
/// one; when an intent needs one and none came, the reply asks for it (`needsTab`) and changes
/// nothing. The close intents carry what the close rules chose: `successor` (the tab selected
/// after closing the selected one) and `closed` (the tabs Close Other Tabs / Close Tabs to the
/// Right closes).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Intent {
    Select { id: String },
    Close { id: String, successor: Option<String> },
    CloseOthers { keep: String, closed: Vec<String> },
    CloseToRight { id: String, closed: Vec<String> },
    Reorder { id: String, to: i64 },
    ReorderTabs { order: Vec<String> },
    NewTab { after: Option<String>, made: Option<Tab> },
    Duplicate { id: String, made: Option<Tab> },
    ToggleAudioMute { id: String },
    Pin { id: String },
    Unpin { id: String },
    ToggleGroupCollapsed { group: String, made: Option<Tab> },
    MoveGroup { group: String, to: i64 },
    AddToGroup { id: String, group: String, index: Option<i64> },
    RemoveFromGroup { id: String, index: Option<i64> },
    CreateGroup { group: Group, ids: Vec<String> },
    RenameGroup { group: String, name: String },
    SetGroupColor { group: String, tint: Option<String> },
    SaveGroup { group: String },
    UnsaveGroup { group: String },
    GroupNewTab { group: String, made: Option<Tab> },
    Ungroup { group: String },
    CloseGroup { group: String },
    MoveGroupToNewWindow { group: String },
    GroupDragBegan,
}

/// The reducer's answer: whether it applied the intent, the strip after it, and whether it stopped
/// for want of a made tab.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub applied: bool,
    #[serde(default)]
    pub needs_tab: bool,
    pub strip: Strip,
}

struct NeedsTab;

fn clamp(value: i64, low: usize, high: usize) -> usize {
    usize::try_from(value.max(i64::try_from(low).unwrap_or(i64::MAX)))
        .unwrap_or(usize::MAX)
        .min(high)
}

impl Strip {
    fn group_ids(&self) -> HashSet<String> {
        self.groups.iter().map(|group| group.id.clone()).collect()
    }

    /// The tabs in display order.
    pub fn ordered(&self) -> Vec<Tab> {
        normalized(&self.tabs, &self.group_ids())
    }

    fn tab(&self, id: &str) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.id == id)
    }

    fn group(&self, id: &str) -> Option<&Group> {
        self.groups.iter().find(|group| group.id == id)
    }

    fn set_collapsed(&mut self, group: &str, collapsed: bool) {
        if let Some(item) = self.groups.iter_mut().find(|item| item.id == group) {
            item.collapsed = collapsed;
        }
    }

    fn select(&mut self, tab: &Tab) {
        self.selected = Some(tab.id.clone());
        if let Some(group) = &tab.group {
            self.set_collapsed(group, false);
        }
    }

    /// Keeps the tabs in display order and drops groups with no members.
    fn normalize(&mut self) {
        self.tabs = self.ordered();
        let used: HashSet<&str> = self.tabs.iter().filter_map(|tab| tab.group.as_deref()).collect();
        self.groups.retain(|group| used.contains(group.id.as_str()));
    }

    /// Applies `intent` to this strip.
    pub fn apply(&self, intent: &Intent) -> Outcome {
        let mut strip = self.clone();
        match strip.reduce(intent) {
            Ok(applied) => Outcome { applied, needs_tab: false, strip },
            Err(NeedsTab) => Outcome { applied: false, needs_tab: true, strip: self.clone() },
        }
    }

    fn reduce(&mut self, intent: &Intent) -> Result<bool, NeedsTab> {
        if let Some(handled) = self.reduce_group(intent)? {
            self.normalize();
            return Ok(handled);
        }
        let mut ordered = self.ordered();
        match intent {
            Intent::Select { id } => {
                let Some(tab) = self.tab(id).cloned() else { return Ok(false) };
                self.selected = Some(id.clone());
                if let Some(group) = &tab.group {
                    self.set_collapsed(group, false);
                }
            }
            Intent::Close { id, successor } => {
                let next = if self.selected.as_deref() == Some(id)
                    && ordered.iter().any(|tab| &tab.id == id)
                {
                    successor.clone()
                } else {
                    self.selected.clone()
                };
                ordered.retain(|tab| &tab.id != id);
                self.tabs = ordered;
                self.selected = next;
            }
            Intent::CloseOthers { keep, closed } => {
                ordered.retain(|tab| !closed.contains(&tab.id));
                self.tabs = ordered;
                self.selected = Some(keep.clone());
            }
            Intent::CloseToRight { id, closed } => {
                if !ordered.iter().any(|tab| &tab.id == id) {
                    return Ok(false);
                }
                ordered.retain(|tab| !closed.contains(&tab.id));
                self.tabs = ordered;
                // Close Tabs to the Right selects the tab it acted on (Chrome).
                self.selected = Some(id.clone());
            }
            Intent::Reorder { id, to } => {
                let Some(from) = ordered.iter().position(|tab| &tab.id == id) else {
                    return Ok(false);
                };
                let item = ordered.remove(from);
                let at = clamp(*to, 0, ordered.len());
                ordered.insert(at, item);
                self.tabs = ordered;
            }
            Intent::ReorderTabs { order } => {
                let mut by_id: HashMap<&str, &Tab> = HashMap::new();
                for tab in &ordered {
                    by_id.entry(tab.id.as_str()).or_insert(tab);
                }
                let wanted: HashSet<&str> = order.iter().map(String::as_str).collect();
                if wanted != by_id.keys().copied().collect() {
                    return Ok(false);
                }
                self.tabs = order
                    .iter()
                    .filter_map(|id| by_id.get(id.as_str()).map(|tab| (*tab).clone()))
                    .collect();
            }
            Intent::NewTab { after, made } => {
                let mut item = made.clone().ok_or(NeedsTab)?;
                match after
                    .as_ref()
                    .and_then(|after| ordered.iter().position(|tab| &tab.id == after))
                {
                    Some(index) => {
                        // A new tab opened from a grouped tab joins its group.
                        item.group = ordered.get(index).and_then(|tab| tab.group.clone());
                        ordered.insert(index.saturating_add(1), item.clone());
                    }
                    None => ordered.push(item.clone()),
                }
                self.tabs = ordered;
                self.select(&item);
            }
            Intent::Duplicate { id, made } => {
                let Some(index) = ordered.iter().position(|tab| &tab.id == id) else {
                    return Ok(false);
                };
                let mut copy = made.clone().ok_or(NeedsTab)?;
                if let Some(source) = ordered.get(index) {
                    copy.pinned = source.pinned;
                    copy.group = source.group.clone();
                }
                ordered.insert(index.saturating_add(1), copy.clone());
                self.tabs = ordered;
                self.select(&copy);
            }
            Intent::ToggleAudioMute { id } => {
                // The demo's speaker: playing and muted swap (the app mutes the page instead).
                let Some(tab) = self.tabs.iter_mut().find(|tab| &tab.id == id) else {
                    return Ok(false);
                };
                let Some(audio) = tab.audio else { return Ok(false) };
                tab.audio = Some(if audio == Audio::Muted { Audio::Playing } else { Audio::Muted });
                return Ok(true);
            }
            Intent::Pin { id } | Intent::Unpin { id } => {
                if self.tab(id).is_none() {
                    return Ok(false);
                }
                // Rebase on display order first so the tab lands at the end of the pinned tabs
                // (pin) or the start of the unpinned ones (unpin).
                self.tabs = ordered;
                let Some(tab) = self.tabs.iter_mut().find(|tab| &tab.id == id) else {
                    return Ok(false);
                };
                if matches!(intent, Intent::Pin { .. }) {
                    tab.pinned = true;
                    tab.group = None;
                } else {
                    tab.pinned = false;
                }
            }
            _ => return Ok(false),
        }
        self.normalize();
        Ok(true)
    }

    /// The group intents: none when `intent` is not one, else whether it applied.
    fn reduce_group(&mut self, intent: &Intent) -> Result<Option<bool>, NeedsTab> {
        let applied = match intent {
            Intent::ToggleGroupCollapsed { group, made } => {
                self.toggle_collapsed(group, made.as_ref())?
            }
            Intent::MoveGroup { group, to } => {
                let mut ordered = self.ordered();
                let members: Vec<Tab> = ordered
                    .iter()
                    .filter(|tab| tab.group.as_deref() == Some(group))
                    .cloned()
                    .collect();
                if members.is_empty() {
                    return Ok(Some(false));
                }
                ordered.retain(|tab| tab.group.as_deref() != Some(group));
                let pinned = ordered.iter().filter(|tab| tab.pinned).count();
                let at = clamp(*to, pinned, ordered.len());
                ordered.splice(at..at, members);
                self.tabs = ordered;
                true
            }
            Intent::AddToGroup { id, group, index } => {
                let Some(tab) = self.tab(id).cloned() else { return Ok(Some(false)) };
                if self.group(group).is_none() || tab.pinned {
                    return Ok(Some(false));
                }
                let mut ordered = self.ordered();
                ordered.retain(|tab| &tab.id != id);
                let mut moved = tab;
                moved.group = Some(group.clone());
                let last_member =
                    ordered.iter().rposition(|tab| tab.group.as_deref() == Some(group));
                let target = index.unwrap_or_else(|| {
                    let end = last_member.map_or(ordered.len(), |last| last.saturating_add(1));
                    i64::try_from(end).unwrap_or(i64::MAX)
                });
                let at = clamp(target, 0, ordered.len());
                ordered.insert(at, moved);
                self.tabs = ordered;
                true
            }
            Intent::RemoveFromGroup { id, index } => {
                let Some(tab) = self.tab(id).cloned() else { return Ok(Some(false)) };
                let Some(group) = tab.group.clone() else { return Ok(Some(false)) };
                let mut ordered = self.ordered();
                ordered.retain(|tab| &tab.id != id);
                let mut moved = tab;
                moved.group = None;
                let after_group =
                    ordered.iter().rposition(|tab| tab.group.as_ref() == Some(&group));
                let target = index.unwrap_or_else(|| {
                    let end = after_group.map_or(ordered.len(), |last| last.saturating_add(1));
                    i64::try_from(end).unwrap_or(i64::MAX)
                });
                let at = clamp(target, 0, ordered.len());
                ordered.insert(at, moved);
                self.tabs = ordered;
                true
            }
            Intent::CreateGroup { group, ids } => {
                let members: HashSet<&str> = ids.iter().map(String::as_str).collect();
                if self.group(&group.id).is_some()
                    || !self.tabs.iter().any(|tab| members.contains(tab.id.as_str()) && !tab.pinned)
                {
                    return Ok(Some(false));
                }
                self.groups.push(group.clone());
                for tab in &mut self.tabs {
                    if members.contains(tab.id.as_str()) && !tab.pinned {
                        tab.group = Some(group.id.clone());
                    }
                }
                true
            }
            Intent::RenameGroup { group, .. }
            | Intent::SetGroupColor { group, .. }
            | Intent::SaveGroup { group }
            | Intent::UnsaveGroup { group }
            | Intent::GroupNewTab { group, .. }
            | Intent::Ungroup { group }
            | Intent::CloseGroup { group }
            | Intent::MoveGroupToNewWindow { group } => self.group_command(group, intent)?,
            Intent::GroupDragBegan => false,
            _ => return Ok(None),
        };
        Ok(Some(applied))
    }

    fn toggle_collapsed(&mut self, group: &str, made: Option<&Tab>) -> Result<bool, NeedsTab> {
        let Some(item) = self.group(group) else { return Ok(false) };
        if item.collapsed {
            self.set_collapsed(group, false);
            return Ok(true);
        }
        // Collapsing moves the selection out of the group first.
        let ordered = self.ordered();
        let collapsed: BTreeSet<String> = self
            .groups
            .iter()
            .filter(|group| group.collapsed)
            .map(|group| group.id.clone())
            .collect();
        let selected_group =
            self.tab(self.selected.as_deref().unwrap_or("")).and_then(|tab| tab.group.as_deref());
        if selected_group == Some(group) {
            match selection_after_collapsing(group, &ordered, &collapsed, self.selected.as_deref())
            {
                Some(next) => self.selected = Some(next),
                None => {
                    // Every visible tab is in the group: open a new tab.
                    let fresh = made.cloned().ok_or(NeedsTab)?;
                    self.selected = Some(fresh.id.clone());
                    self.tabs = ordered.into_iter().chain([fresh]).collect();
                }
            }
        }
        self.set_collapsed(group, true);
        Ok(true)
    }

    fn group_command(&mut self, id: &str, intent: &Intent) -> Result<bool, NeedsTab> {
        let Some(index) = self.groups.iter().position(|group| group.id == id) else {
            return Ok(false);
        };
        match intent {
            Intent::RenameGroup { name, .. } => {
                if let Some(group) = self.groups.get_mut(index) {
                    group.name = name.clone();
                }
            }
            Intent::SetGroupColor { tint, .. } => {
                if let Some(group) = self.groups.get_mut(index) {
                    group.tint = tint.clone();
                }
            }
            Intent::SaveGroup { .. } => {
                if let Some(group) = self.groups.get_mut(index) {
                    group.saved = true;
                }
            }
            Intent::UnsaveGroup { .. } => {
                if let Some(group) = self.groups.get_mut(index) {
                    group.saved = false;
                }
            }
            Intent::GroupNewTab { made, .. } => {
                let mut ordered = self.ordered();
                let mut item = made.clone().ok_or(NeedsTab)?;
                item.group = Some(id.to_owned());
                let target = ordered
                    .iter()
                    .rposition(|tab| tab.group.as_deref() == Some(id))
                    .map_or(ordered.len(), |last| last.saturating_add(1));
                ordered.insert(target, item.clone());
                self.tabs = ordered;
                self.select(&item);
            }
            Intent::Ungroup { .. } => {
                for tab in &mut self.tabs {
                    if tab.group.as_deref() == Some(id) {
                        tab.group = None;
                    }
                }
            }
            Intent::CloseGroup { .. } => {
                let ordered = self.ordered();
                let remaining: Vec<Tab> = ordered
                    .iter()
                    .filter(|tab| tab.group.as_deref() != Some(id))
                    .cloned()
                    .collect();
                if let Some(selected) = self.selected.clone()
                    && !remaining.iter().any(|tab| tab.id == selected)
                {
                    let start = ordered.iter().position(|tab| tab.id == selected).unwrap_or(0);
                    self.selected = ordered
                        .get(start..)
                        .unwrap_or_default()
                        .iter()
                        .find(|tab| tab.group.as_deref() != Some(id))
                        .or(remaining.last())
                        .map(|tab| tab.id.clone());
                }
                self.tabs = remaining;
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
}

#[cfg(test)]
#[path = "tabs_groups_tests.rs"]
mod tests;
