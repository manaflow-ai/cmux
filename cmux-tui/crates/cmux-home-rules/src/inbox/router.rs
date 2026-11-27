//! `HomeSourceRouter`'s bookkeeping as a step: which owner (this Mac's daemon or Cloud) each
//! conversation routes to, the merged connection, and the inbox revisions it stamps. Swift keeps
//! the payloads and the streams; an event names ids, and an effect tells Swift what to publish.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `ConversationSummary.Owner`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Owner {
    Local,
    Cloud,
}

/// The router's state (`HomeSourceRouter.State` without the continuations).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub owners: BTreeMap<String, Owner>,
    pub cloud_listed: BTreeSet<String>,
    pub inbox_rev: u64,
    pub cloud_account: Option<String>,
    pub cloud_account_seen: bool,
    pub local_participants: BTreeSet<String>,
    /// A `HomeConnection` as its case name (`online`, `connecting`, ...).
    pub local_connection: String,
    pub cloud_connection: Option<String>,
    pub last_connection: Option<String>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            owners: BTreeMap::new(),
            cloud_listed: BTreeSet::new(),
            inbox_rev: 0,
            cloud_account: None,
            cloud_account_seen: false,
            local_participants: BTreeSet::new(),
            local_connection: CONNECTING.to_owned(),
            cloud_connection: None,
            last_connection: None,
        }
    }
}

const ONLINE: &str = "online";
const CONNECTING: &str = "connecting";

/// A summary as the router reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Summary {
    pub id: String,
    /// Participant ids.
    pub participants: Vec<String>,
}

/// What happened (a child stream's event, or a call's answer).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Event {
    /// The daemon's `.connection`.
    LocalConnection { connection: String },
    /// The daemon's `.inbox`: its conversations and `me`, with Cloud's current ids.
    #[serde(rename_all = "camelCase")]
    LocalInbox { conversations: Vec<Summary>, me: String, cloud: Vec<String> },
    /// The daemon's `.conversationChanged`.
    LocalChanged { summary: Summary, owner: Owner },
    /// Any other daemon event.
    LocalOther,
    /// Cloud's own link.
    CloudConnection { connection: String },
    /// Cloud's `.inbox`, for the signed-in account.
    CloudInbox { ids: Vec<String>, account: Option<String> },
    /// Cloud's `.conversationChanged` on the inbox stream.
    CloudInboxChanged { id: String },
    /// Cloud's `.conversationRemoved`.
    CloudRemoved { id: String },
    /// Cloud's `.conversationChanged` on a conversation stream, or `.conversationPage`.
    CloudListed { id: String },
    /// Any other Cloud event.
    CloudOther,
    /// `inbox()`: the merged snapshot of both owners.
    Merge { local: Vec<String>, cloud: Vec<String> },
    /// `snapshot(of:)` read the page's owner.
    PageOwner { id: String, owner: Owner },
    /// Cloud's `submit` created this conversation.
    Created { id: String },
    /// `owner(of:)` with no known owner: Cloud's listing, then the answer.
    Lookup { id: String, listed: Vec<String> },
}

/// What Swift publishes (in order) or answers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Effect {
    /// `.connection(connection)`.
    Connection { connection: String },
    /// `.ownerRecovered`.
    OwnerRecovered,
    /// The merged `.inbox` (local then Cloud conversations) at `rev`.
    Inbox { rev: u64 },
    /// `.conversationRemoved(id, inboxRev: rev)`.
    Removed { id: String, rev: u64 },
    /// `.conversationChanged(summary, stream: .inbox, rev: rev)`.
    Changed { id: String, rev: u64 },
    /// The event as it came.
    PassThrough,
    /// `owner(of:)`'s answer.
    Owner { owner: Owner },
}

/// `HomeSourceRouter.merged(local:cloud:)`.
pub fn merged_connection(local: &str, cloud: Option<&str>) -> String {
    if local == ONLINE || cloud == Some(ONLINE) { ONLINE.to_owned() } else { local.to_owned() }
}

fn merged_event(state: &mut State) -> Option<Effect> {
    let connection = merged_connection(&state.local_connection, state.cloud_connection.as_deref());
    if state.last_connection.as_deref() == Some(connection.as_str()) {
        return None;
    }
    state.last_connection = Some(connection.clone());
    Some(Effect::Connection { connection })
}

fn merge(state: &mut State, local: &[String], cloud: &[String]) -> Effect {
    for id in local {
        state.owners.insert(id.clone(), Owner::Local);
    }
    for id in cloud {
        state.owners.insert(id.clone(), Owner::Cloud);
    }
    state.cloud_listed = cloud.iter().cloned().collect();
    state.inbox_rev += 1;
    Effect::Inbox { rev: state.inbox_rev }
}

fn changed(state: &mut State, id: &str) -> Effect {
    state.cloud_listed.insert(id.to_owned());
    state.owners.insert(id.to_owned(), Owner::Cloud);
    state.inbox_rev += 1;
    Effect::Changed { id: id.to_owned(), rev: state.inbox_rev }
}

/// One step: `forwardLocal`, `forwardCloud`, `inbox()`, `snapshot`, `submit` and `owner(of:)`'s
/// state changes.
pub fn step(state: &mut State, event: &Event) -> Vec<Effect> {
    match event {
        Event::LocalConnection { connection } => {
            let was = std::mem::replace(&mut state.local_connection, connection.clone());
            if let Some(merged) = merged_event(state) {
                return vec![merged];
            }
            if connection == ONLINE && was != ONLINE {
                vec![Effect::OwnerRecovered]
            } else {
                Vec::new()
            }
        }
        Event::LocalInbox { conversations, me, cloud } => {
            state.local_participants = conversations
                .iter()
                .flat_map(|c| c.participants.iter().cloned())
                .chain(std::iter::once(me.clone()))
                .collect();
            let local: Vec<String> = conversations.iter().map(|c| c.id.clone()).collect();
            vec![merge(state, &local, cloud)]
        }
        Event::LocalChanged { summary, owner } => {
            state.owners.insert(summary.id.clone(), *owner);
            state.local_participants.extend(summary.participants.iter().cloned());
            vec![Effect::PassThrough]
        }
        Event::LocalOther | Event::CloudOther => vec![Effect::PassThrough],
        Event::CloudConnection { connection } => {
            state.cloud_connection = Some(connection.clone());
            merged_event(state).into_iter().collect()
        }
        Event::CloudInbox { ids, account } => {
            let listed: BTreeSet<&String> = ids.iter().collect();
            if state.cloud_account_seen && state.cloud_account != *account {
                state.owners.retain(|id, owner| *owner == Owner::Local || listed.contains(id));
            }
            state.cloud_account = account.clone();
            state.cloud_account_seen = true;
            let removed: Vec<String> =
                state.cloud_listed.iter().filter(|id| !listed.contains(id)).cloned().collect();
            let mut effects = Vec::new();
            for id in removed {
                state.cloud_listed.remove(&id);
                state.inbox_rev += 1;
                effects.push(Effect::Removed { id, rev: state.inbox_rev });
            }
            for id in ids {
                effects.push(changed(state, id));
            }
            effects
        }
        Event::CloudInboxChanged { id } => vec![changed(state, id)],
        Event::CloudRemoved { id } => {
            state.cloud_listed.remove(id);
            state.inbox_rev += 1;
            vec![Effect::Removed { id: id.clone(), rev: state.inbox_rev }]
        }
        Event::CloudListed { id } => {
            state.cloud_listed.insert(id.clone());
            state.owners.insert(id.clone(), Owner::Cloud);
            vec![Effect::PassThrough]
        }
        Event::Merge { local, cloud } => vec![merge(state, local, cloud)],
        Event::PageOwner { id, owner } => {
            state.owners.insert(id.clone(), *owner);
            Vec::new()
        }
        Event::Created { id } => {
            state.owners.insert(id.clone(), Owner::Cloud);
            Vec::new()
        }
        Event::Lookup { id, listed } => {
            for listed in listed {
                state.owners.entry(listed.clone()).or_insert(Owner::Cloud);
            }
            vec![Effect::Owner { owner: state.owners.get(id).copied().unwrap_or(Owner::Local) }]
        }
    }
}

/// A `HomeIntent.op` as `submit` reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Intent {
    CreateGroup {
        ids: Vec<String>,
        #[serde(default)]
        invites: Vec<String>,
    },
    StartConversation,
    Invite,
    OpenDirect,
    CreateChief,
    /// Any other op, with its conversation if it has one.
    Other {
        #[serde(default)]
        conversation: Option<String>,
    },
}

/// Where `submit` sends an intent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Route {
    Local,
    Cloud,
    /// Ask `owner(of:)` (a `lookup` step); Cloud's when the answer is `cloud`.
    ByOwner {
        conversation: String,
    },
}

/// `submit`'s routing; `chief` is `DaemonHomeSource.chief.id`.
pub fn route(state: &State, intent: &Intent, chief: &str) -> Route {
    match intent {
        Intent::CreateGroup { ids, invites } => {
            let local = ids.iter().all(|id| state.local_participants.contains(id) || id == chief);
            if !invites.is_empty() || !local { Route::Cloud } else { Route::Local }
        }
        Intent::StartConversation | Intent::Invite | Intent::OpenDirect => Route::Cloud,
        Intent::CreateChief => Route::Local,
        Intent::Other { conversation } => match conversation {
            None => Route::Local,
            Some(id) => match state.owners.get(id) {
                Some(Owner::Cloud) => Route::Cloud,
                Some(Owner::Local) => Route::Local,
                None => Route::ByOwner { conversation: id.clone() },
            },
        },
    }
}

/// `upload`'s rejection: Cloud's "attachments unsupported" becomes the code the composer words.
pub fn upload_rejection(owner: Owner, reason: &str) -> String {
    if owner == Owner::Cloud && reason == "attachments unsupported" {
        "cloud_attachments_unsupported".to_owned()
    } else {
        reason.to_owned()
    }
}
