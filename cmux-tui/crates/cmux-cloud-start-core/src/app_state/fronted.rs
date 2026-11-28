//! A Cloud chat started from this Mac's tab shows in that tab, in place (cmux#47677; the app's
//! `CloudFrontedChats`). The chat runs in its own workspace on the Cloud machine, but that workspace
//! stays out of every window. Closing the Mac tab ends the Cloud chat's workspace (`CloseCloud`);
//! the Cloud tab going (its machine deleted) lets the Mac tab show its own page again (`Reshow`).
//! Kept across relaunches in the app's defaults (`cmux.cloud.frontedChats`) as [`Fronted::persisted`].

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// The defaults key the fronts are kept under.
pub const DEFAULTS_KEY: &str = "cmux.cloud.frontedChats";

/// An agent tab: its machine and its key there (`AgentTabKey`).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Tab {
    pub machine: String,
    pub key: String,
}

/// The Cloud chat a Mac tab shows: the Cloud tab and its workspace (`AgentTabCloudFront`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Front {
    pub machine: String,
    pub key: String,
    pub workspace: String,
}

impl Front {
    pub fn tab(&self) -> Tab {
        Tab { machine: self.machine.clone(), key: self.key.clone() }
    }
}

/// One Mac tab's front, as kept in the defaults.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub machine: String,
    pub key: String,
    pub front: Front,
}

impl Entry {
    fn mac(&self) -> Tab {
        Tab { machine: self.machine.clone(), key: self.key.clone() }
    }
}

/// What the app does when a tab went.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
pub enum Gone {
    /// Not a Mac tab with a front, nor a Cloud tab one shows.
    Nothing,
    /// A Mac tab went: its Cloud chat's workspace closes on its machine.
    CloseCloud { front: Front },
    /// A Cloud tab went: Mac tab `mac` shows its own page again.
    Reshow { mac: Tab, cloud: Tab },
}

/// The fronts and the workspaces a start is making for a Mac tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fronted {
    /// One per Mac tab, sorted by its machine and key.
    #[serde(default)]
    pub fronts: Vec<Entry>,
    /// Workspaces a start is making for a Mac tab, held before they list.
    #[serde(default)]
    pub making: BTreeSet<String>,
}

impl Fronted {
    pub fn is_empty(&self) -> bool {
        self.fronts.is_empty() && self.making.is_empty()
    }

    /// The Cloud workspaces no window may take: each front's, and each one a start is making.
    pub fn workspace_ids(&self) -> BTreeSet<String> {
        let mut ids = self.making.clone();
        ids.extend(self.fronts.iter().map(|entry| entry.front.workspace.clone()));
        ids
    }

    /// The Cloud chat Mac tab `mac` shows, if it shows one.
    pub fn front_of(&self, mac: &Tab) -> Option<&Front> {
        self.fronts.iter().find(|entry| entry.mac() == *mac).map(|entry| &entry.front)
    }

    /// The Mac tab that shows Cloud tab `cloud`.
    pub fn mac_showing(&self, cloud: &Tab) -> Option<Tab> {
        self.fronts.iter().find(|entry| entry.front.tab() == *cloud).map(Entry::mac)
    }

    /// The Mac tab that shows the chat of Cloud workspace `workspace`.
    pub fn mac_showing_workspace(&self, workspace: &str) -> Option<Tab> {
        self.fronts.iter().find(|entry| entry.front.workspace == workspace).map(Entry::mac)
    }

    /// Holds `workspace` out of every window while a start makes it. A start that fails keeps it
    /// held: its retry opens the same workspace, which never shows as a row.
    pub fn hold(&mut self, workspace: String) {
        self.making.insert(workspace);
    }

    /// Mac tab `mac` shows `front` from now on. Persist after.
    pub fn front(&mut self, mac: Tab, front: Front) {
        self.making.remove(&front.workspace);
        self.set(mac, front);
    }

    fn remove(&mut self, mac: &Tab) -> Option<Front> {
        let index = self.fronts.iter().position(|entry| entry.mac() == *mac)?;
        Some(self.fronts.remove(index).front)
    }

    /// A tab went (no store lists it): a Mac tab's Cloud chat ends with it; a Cloud tab's Mac tab
    /// shows its own page. Anything but `Nothing` changed the fronts: persist.
    pub fn gone(&mut self, tab: &Tab) -> Gone {
        if let Some(front) = self.remove(tab) {
            Gone::CloseCloud { front }
        } else if let Some(mac) = self.mac_showing(tab) {
            self.remove(&mac);
            Gone::Reshow { mac, cloud: tab.clone() }
        } else {
            Gone::Nothing
        }
    }

    /// What the defaults keep: the entries, sorted; none removes the key.
    pub fn persisted(&self) -> Option<&[Entry]> {
        (!self.fronts.is_empty()).then_some(self.fronts.as_slice())
    }

    /// The fronts kept by the last run (a later entry for the same Mac tab wins).
    pub fn restore(&mut self, entries: Vec<Entry>) {
        for entry in entries {
            let mac = entry.mac();
            self.set(mac, entry.front);
        }
    }

    fn set(&mut self, mac: Tab, front: Front) {
        self.remove(&mac);
        let entry = Entry { machine: mac.machine, key: mac.key, front };
        let at = self
            .fronts
            .partition_point(|other| (&other.machine, &other.key) < (&entry.machine, &entry.key));
        self.fronts.insert(at, entry);
    }
}

#[cfg(test)]
#[path = "fronted_tests.rs"]
mod tests;
