//! The app's ledgers for Cloud moves, kept in its user defaults as JSON: what Retry does for a
//! chat whose move stopped (by its daemon tab), the chats Move to Cloud moved (by their tab record
//! on the machine) and the copies a start made that wait for their session, and an agent's
//! persistent "Always move to Cloud" grants. The app reads and writes the defaults; here each
//! ledger is read leniently (an entry this version can't read drops alone, never the others) and
//! changed. The JSON keeps the spelling the app's Swift `Codable` types wrote before, so a ledger
//! from an earlier build reads the same.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// The entries of a stored ledger object that read as `T`; a ledger that is no object reads as none.
fn lenient<T: for<'de> Deserialize<'de>>(stored: Option<&str>) -> BTreeMap<String, T> {
    let Some(Ok(Value::Object(object))) = stored.map(serde_json::from_str::<Value>) else {
        return BTreeMap::new();
    };
    object
        .into_iter()
        .filter_map(|(key, value)| Some((key, serde_json::from_value(value).ok()?)))
        .collect()
}

fn encode<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_owned())
}

/// What Retry does for one chat whose Move to Cloud or Bring Back Local stopped.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Retry {
    /// The chat may not have moved: run the move again, to this machine.
    Move {
        #[serde(rename = "machineID")]
        machine_id: String,
    },
    /// The chat moved: only open its tab on the machine.
    Show {
        #[serde(rename = "_0")]
        shown: Shown,
    },
    /// Bring Back Local only: run the move again, narrowing the chat to an asking policy first.
    AskFirst {
        #[serde(rename = "machineID")]
        machine_id: String,
    },
    /// The machine's cmux-tui is too old for the move: "Update Machine", then the move again.
    Update {
        #[serde(rename = "machineID")]
        machine_id: String,
    },
}

/// A moved chat whose tab on the machine didn't open yet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shown {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(rename = "machineID")]
    pub machine_id: String,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub moved_session: Option<String>,
}

/// The retries a stored ledger holds, by daemon tab.
pub fn retries(stored: Option<&str>) -> BTreeMap<String, Retry> {
    lenient(stored)
}

/// The ledger after setting (or, with none, clearing) `tab`'s retry: none when nothing changed,
/// else the value to store (none: remove the defaults key, the ledger is empty).
pub fn set_retry(stored: Option<&str>, tab: &str, retry: Option<Retry>) -> Option<Option<String>> {
    let mut all = retries(stored);
    if all.get(tab) == retry.as_ref() {
        return None;
    }
    match retry {
        Some(retry) => all.insert(tab.to_owned(), retry),
        None => all.remove(tab),
    };
    Some((!all.is_empty()).then(|| encode(&all)))
}

/// One chat Move to Cloud moved (or a start copied), by its tab record on the machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Moved {
    #[serde(rename = "machineID")]
    pub machine_id: String,
    /// The tab record's host on the machine (`registry:<store>`).
    pub host: String,
    /// The chat's session on the machine.
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    pub local_root: String,
    pub local_chat: String,
    pub remote_folder: String,
    pub remote_chat: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Set once Bring Back Local moved the chat back, kept until that tab opened.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brought_back: Option<BroughtBack>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BroughtBack {
    pub session: String,
    pub key: String,
}

fn key(host: &str, session: &str) -> String {
    format!("{host}\n{session}")
}

/// The moved chats (`cmux.cloud.movedChats`) and the copies waiting for their session
/// (`cmux.cloud.startingChats`), as stored.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MovedChats {
    pub moved: Option<String>,
    pub starting: Option<String>,
}

/// A change to the moved-chat ledgers: each part present is what to store (its value none:
/// remove the defaults key).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MovedWrite {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub moved: Option<Stored>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub starting: Option<Stored>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Stored {
    pub value: Option<String>,
}

impl MovedChats {
    fn moved(&self) -> BTreeMap<String, Moved> {
        lenient(self.moved.as_deref())
    }

    fn starting(&self) -> BTreeMap<String, Moved> {
        lenient(self.starting.as_deref())
    }

    pub fn entry(&self, host: &str, session: &str) -> Option<Moved> {
        self.moved().remove(&key(host, session))
    }

    /// Every moved chat, in no particular order.
    pub fn all(&self) -> Vec<Moved> {
        self.moved().into_values().collect()
    }

    /// The moved ledger is written even when empty, as before.
    fn write_moved(all: &BTreeMap<String, Moved>) -> Stored {
        Stored { value: Some(encode(all)) }
    }

    fn write_starting(all: &BTreeMap<String, Moved>) -> Stored {
        Stored { value: (!all.is_empty()).then(|| encode(all)) }
    }

    pub fn record(&self, entry: Moved) -> MovedWrite {
        let mut all = self.moved();
        all.insert(key(&entry.host, &entry.session), entry);
        MovedWrite { moved: Some(Self::write_moved(&all)), starting: None }
    }

    /// Keeps a committed copy until the opened tab's first send creates its session. Pending
    /// copies never appear in menus or access triage; a relaunch can finish the same first send.
    pub fn copied(&self, entry: Moved) -> MovedWrite {
        let mut copies = self.starting();
        copies.insert(key(&entry.host, &entry.remote_chat), entry);
        MovedWrite { moved: None, starting: Some(Self::write_starting(&copies)) }
    }

    /// Completes a Cloud start with the session its daemon actually created: whether a copy was
    /// recorded, and the change. Ordinary remote chats and no-project starts have no copy and
    /// never acquire a local-folder mapping. A chat already recorded (a committed bring-back) is
    /// never overwritten by a replayed copy.
    pub fn started(
        &self,
        host: &str,
        session: &str,
        remote_chat: Option<&str>,
        harness: Option<&str>,
    ) -> (bool, MovedWrite) {
        let Some(remote_chat) = remote_chat else { return (false, MovedWrite::default()) };
        let mut copies = self.starting();
        let Some(mut entry) = copies.remove(&key(host, remote_chat)) else {
            return (false, MovedWrite::default());
        };
        entry.session = session.to_owned();
        if let Some(harness) = harness {
            entry.harness = Some(harness.to_owned());
        }
        // Recorded first: a crash between these writes can replay this completion harmlessly.
        let mut moved = self.moved();
        let recorded = match moved.entry(key(host, session)) {
            std::collections::btree_map::Entry::Occupied(_) => None,
            std::collections::btree_map::Entry::Vacant(slot) => {
                slot.insert(entry);
                Some(Self::write_moved(&moved))
            }
        };
        (true, MovedWrite { moved: recorded, starting: Some(Self::write_starting(&copies)) })
    }

    pub fn forget(&self, host: &str, session: &str) -> MovedWrite {
        let mut all = self.moved();
        let moved = all.remove(&key(host, session)).map(|_| Self::write_moved(&all));
        MovedWrite { moved, starting: None }
    }
}

/// Who an "Always move to Cloud" grant belongs to: the signed-in user, selected team and Cloud
/// API origin. A different account, team or backend must ask the person again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Scope<'a> {
    pub user_id: &'a str,
    pub team_id: &'a str,
    pub cloud_origin: &'a str,
}

impl<'a> Scope<'a> {
    /// None unless each part is there: an unsigned scope never grants anything.
    pub fn new(
        user_id: Option<&'a str>,
        team_id: Option<&'a str>,
        cloud_origin: &'a str,
    ) -> Option<Self> {
        let user_id = user_id.filter(|id| !id.is_empty())?;
        let team_id = team_id.filter(|id| !id.is_empty())?;
        (!cloud_origin.is_empty()).then_some(Self { user_id, team_id, cloud_origin })
    }

    pub fn grant(&self, folder: &str) -> Grant {
        Grant {
            user_id: self.user_id.to_owned(),
            team_id: self.team_id.to_owned(),
            cloud_origin: self.cloud_origin.to_owned(),
            folder: folder.to_owned(),
        }
    }
}

/// One stored grant (`cmux.cloud.moveAlwaysGrants.v2`). The old `cmux.cloud.moveAlwaysFolders`
/// array holds only paths: it is deliberately never read or migrated, since the account and team
/// that approved those paths cannot be recovered.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Grant {
    #[serde(rename = "userID")]
    pub user_id: String,
    #[serde(rename = "teamID")]
    pub team_id: String,
    #[serde(rename = "cloudOrigin")]
    pub cloud_origin: String,
    pub folder: String,
}

/// Every grant stored; a missing or damaged preference reads as none.
pub fn grants(stored: Option<&str>) -> Vec<Grant> {
    stored.and_then(|stored| serde_json::from_str(stored).ok()).unwrap_or_default()
}

/// The grants to store, unique, in a stable order.
pub fn store_grants(grants: impl IntoIterator<Item = Grant>) -> String {
    encode(&grants.into_iter().collect::<BTreeSet<_>>().into_iter().collect::<Vec<_>>())
}

pub fn granted(stored: Option<&str>, scope: Option<&Scope<'_>>, folder: &str) -> bool {
    scope.is_some_and(|scope| grants(stored).contains(&scope.grant(folder)))
}

/// The grants after "Always" (`always`) or "Ask first next time" for `folder` in `scope`; none
/// for no scope (nothing changes).
pub fn remember(
    stored: Option<&str>,
    scope: Option<&Scope<'_>>,
    folder: &str,
    always: bool,
) -> Option<String> {
    let grant = scope?.grant(folder);
    let mut all: BTreeSet<Grant> = grants(stored).into_iter().collect();
    if always {
        all.insert(grant);
    } else {
        all.remove(&grant);
    }
    Some(store_grants(all))
}

#[cfg(test)]
mod tests;
