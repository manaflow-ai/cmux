//! `HomeCloudChiefs` (+Tab, +Placement): the user's two cloud Chiefs in
//! Home, which one the Chief tab shows, how the tab moves, and the decisions
//! of `ensureHosted` (the API calls and `UserDefaults` stay in Swift).

use super::reach::CloudChief;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::HashSet;

/// The Hosted Chief and the placed one (`HomeCloudChiefs`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chiefs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hosted: Option<CloudChief>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placed: Option<CloudChief>,
}

/// The Chief the user picked (`HomeChiefChoice`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Choice {
    #[default]
    Hosted,
    Placed,
}

/// `ChiefList.hosted`: the default chief with no machine placed and a main
/// conversation, else the first such.
pub fn hosted_in(chiefs: &[CloudChief]) -> Option<&CloudChief> {
    let mut hosted =
        chiefs.iter().filter(|c| c.brain_place.is_none() && c.main_conversation.is_some());
    let first = hosted.clone().next();
    hosted.find(|c| c.is_default).or(first)
}

/// `ChiefList.placed`: the default placed chief, else the first placed one.
pub fn placed_in(chiefs: &[CloudChief]) -> Option<&CloudChief> {
    let mut placed = chiefs.iter().filter(|c| c.brain_place.is_some());
    let first = placed.clone().next();
    placed.find(|c| c.is_default).or(first)
}

impl Chiefs {
    /// `shown(choice:)`: the placed one only when picked and present; else
    /// the hosted one, else the placed one.
    pub fn shown(&self, choice: Choice) -> Option<&CloudChief> {
        if choice == Choice::Placed
            && let Some(placed) = &self.placed
        {
            return Some(placed);
        }
        self.hosted.as_ref().or(self.placed.as_ref())
    }

    /// `chief(for:)`: the one whose main conversation is `conversation`.
    pub fn chief_for(&self, conversation: &str) -> Option<&CloudChief> {
        [self.hosted.as_ref(), self.placed.as_ref()]
            .into_iter()
            .flatten()
            .find(|c| c.main_conversation.as_deref() == Some(conversation))
    }

    /// `canSwitch`: both have a main conversation.
    pub fn can_switch(&self) -> bool {
        let has =
            |c: &Option<CloudChief>| c.as_ref().is_some_and(|c| c.main_conversation.is_some());
        has(&self.hosted) && has(&self.placed)
    }

    /// `otherHost(of:)`: the other Chief the card offers on `conversation`.
    pub fn other_host(&self, conversation: &str) -> Option<Choice> {
        if !self.can_switch() {
            return None;
        }
        let main = |c: &Option<CloudChief>| c.as_ref().and_then(|c| c.main_conversation.clone());
        if main(&self.hosted).as_deref() == Some(conversation) {
            return Some(Choice::Placed);
        }
        if main(&self.placed).as_deref() == Some(conversation) {
            return Some(Choice::Hosted);
        }
        None
    }

    /// `chiefTab(local:localHasHistory:choice:prefersLocal:)`.
    pub fn chief_tab(
        &self,
        local: Option<&str>,
        local_has_history: bool,
        choice: Choice,
        prefers_local: bool,
    ) -> Option<String> {
        if prefers_local {
            return local.map(str::to_owned);
        }
        if self.hosted.is_none()
            && let Some(local) = local
            && local_has_history
        {
            return Some(local.to_owned());
        }
        self.shown(choice)
            .and_then(|c| c.main_conversation.clone())
            .or_else(|| local.map(str::to_owned))
    }

    /// `placement(of:records:)`: the Chief's agent id and whether a server
    /// runs it, from these Chiefs, else from the directory's records.
    pub fn placement(&self, conversation: &str, records: &[Record]) -> Option<Placement> {
        if let Some(chief) = self.chief_for(conversation) {
            return Some(Placement { id: chief.id.clone(), placed: chief.brain_place.is_some() });
        }
        records
            .iter()
            .find(|r| r.main_conversation.as_deref() == Some(conversation))
            .map(|r| Placement { id: r.id.clone(), placed: r.placed })
    }
}

/// `read(call:hostedBrains: false)`'s result: no Hosted Chief, and the
/// placed chief only when it has a main conversation.
pub fn placed_only(chiefs: &[CloudChief]) -> Chiefs {
    Chiefs {
        hosted: None,
        placed: placed_in(chiefs).filter(|c| c.main_conversation.is_some()).cloned(),
    }
}

/// A directory record (`HomeChiefRecord`), the fields placement reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default)]
    pub rev: i64,
    #[serde(default)]
    pub main_conversation: Option<String>,
    #[serde(default)]
    pub placed: bool,
}

/// `placement(of:records:)`'s reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placement {
    pub id: String,
    pub placed: bool,
}

/// One pane of Home's workspaces as the tab rules read it: its handle and
/// its tabs (a conversation tab names its conversation; any other tab
/// leaves it out).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pane {
    pub pane: String,
    #[serde(default)]
    pub tabs: Vec<Tab>,
}

/// One tab of a [`Pane`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tab {
    pub surface: String,
    #[serde(default)]
    pub conversation: Option<String>,
}

/// `HomeChiefTabKey.isOpen`: a conversation tab shows `chief`.
pub fn is_open(chief: &str, panes: &[Pane]) -> bool {
    panes.iter().flat_map(|p| &p.tabs).any(|t| t.conversation.as_deref() == Some(chief))
}

/// `move(from:chief:in:)`'s reply.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Move {
    pub close: Vec<String>,
    #[serde(default)]
    pub pane: Option<String>,
}

/// `move(from:chief:in:)`: the tabs still showing one of `from` close and
/// the Chief opens in the first one's pane; nothing while the Chief already
/// has its tab.
pub fn move_tab(from: &[String], chief: &str, panes: &[Pane]) -> Move {
    let from: HashSet<&str> = from.iter().map(String::as_str).filter(|f| *f != chief).collect();
    if from.is_empty() || is_open(chief, panes) {
        return Move::default();
    }
    let mut out = Move::default();
    for pane in panes {
        for tab in &pane.tabs {
            if tab.conversation.as_deref().is_some_and(|c| from.contains(c)) {
                out.close.push(tab.surface.clone());
                if out.pane.is_none() {
                    out.pane = Some(pane.pane.clone());
                }
            }
        }
    }
    out
}

/// `staleChiefTabs(stale:chief:in:)`: the tabs showing another cloud
/// Chief's conversation.
pub fn stale_tabs(stale: &[String], chief: &str, panes: &[Pane]) -> Vec<String> {
    let stale: HashSet<&str> = stale.iter().map(String::as_str).filter(|s| *s != chief).collect();
    if stale.is_empty() {
        return Vec::new();
    }
    panes
        .iter()
        .flat_map(|p| &p.tabs)
        .filter(|t| t.conversation.as_deref().is_some_and(|c| stale.contains(c)))
        .map(|t| t.surface.clone())
        .collect()
}

/// `okValue`: the ops envelope's value, or its refusal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Envelope {
    Value(Value),
    Refused { code: String, message: String },
}

/// `okValue(_:)`: a reply with `_tag` and a string `code` is a refusal.
pub fn ok_value(reply: &Map<String, Value>) -> Envelope {
    if reply.contains_key("_tag")
        && let Some(code) = reply.get("code").and_then(Value::as_str)
    {
        let message = reply.get("message").and_then(Value::as_str).unwrap_or(code).to_owned();
        return Envelope::Refused { code: code.to_owned(), message };
    }
    Envelope::Value(reply.get("value").cloned().unwrap_or(Value::Null))
}

/// One `chief.update` `ensureHosted` sends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Update {
    /// The op's idempotency key.
    pub idempotency_key: String,
    /// The op's params (`chief`, `expected_rev`, and the change).
    pub params: Value,
}

/// What `ensureHosted` does next for the latest `chief.list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ensure {
    /// No Hosted Chief yet: `chief.create` under the next key.
    pub needs_hosted: bool,
    /// The placed chief still has a plain name: this rename.
    pub rename: Option<Update>,
    /// The Hosted Chief is not the default: this update.
    pub make_default: Option<Update>,
    /// The Chiefs now (what `ensureHosted` returns once nothing is left).
    pub chiefs: Chiefs,
}

/// `ensureHosted`'s rules for one list: the create, the rename of a placed
/// chief still named `chief_name`, `Chief` or empty to `placed_name`, and
/// the default flag of the Hosted Chief.
pub fn ensure(chiefs: &[CloudChief], chief_name: &str, placed_name: &str) -> Ensure {
    let hosted = hosted_in(chiefs);
    let placed = placed_in(chiefs);
    let rename = placed
        .filter(|mini| [chief_name, "Chief", ""].contains(&mini.display_name.as_str()))
        .map(|mini| Update {
            idempotency_key: format!("chief-placed-rename-{}-{}", mini.id, mini.rev),
            params: serde_json::json!({
                "chief": mini.id, "expected_rev": mini.rev, "display_name": placed_name,
            }),
        });
    let make_default = hosted.filter(|c| !c.is_default).map(|c| Update {
        idempotency_key: format!("chief-hosted-default-{}-{}", c.id, c.rev),
        params: serde_json::json!({ "chief": c.id, "expected_rev": c.rev, "is_default": true }),
    });
    Ensure {
        needs_hosted: hosted.is_none(),
        rename,
        make_default,
        chiefs: Chiefs { hosted: hosted.cloned(), placed: placed.cloned() },
    }
}

/// After a `chief.create` reply: whether this Mac made the chief (its
/// brain is turned on here). A replay counts only when this Mac sent the
/// same key before without a reply.
pub fn created_here(replayed: bool, sent_before: bool) -> bool {
    !replayed || sent_before
}
