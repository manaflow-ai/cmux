//! `HomeMessageRequests` and `HomeMessageRequest`: the message requests
//! list, its coalesced reads and the optimistic Accept, Decline and Block.
//! The reads and answers stay in Swift (`HomeMessageRequestSource`).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

/// One message request (`HomeMessageRequest`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub conversation: String,
    pub inviter: String,
    #[serde(default)]
    pub is_group: bool,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub preview: String,
    /// As the caller encodes its `Date` (passed through).
    #[serde(default)]
    pub created_at: Option<Value>,
    #[serde(default)]
    pub trusted: bool,
}

/// The read loop (`reading` and `again`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reads {
    #[serde(default)]
    pub reading: bool,
    #[serde(default)]
    pub again: bool,
}

/// An event of the read loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReadEvent {
    /// `refresh()` (or `reload()`).
    Refresh,
    /// One read answered (or failed).
    ReadEnded,
}

/// What the loop does after an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadStep {
    pub state: Reads,
    /// Start one read now.
    pub read: bool,
}

/// `refresh()` and `readLoop()`: one read at a time; calls while a read
/// runs coalesce into one more read.
pub fn read_step(state: Reads, event: ReadEvent) -> ReadStep {
    match event {
        ReadEvent::Refresh if state.reading => {
            ReadStep { state: Reads { reading: true, again: true }, read: false }
        }
        ReadEvent::Refresh => ReadStep { state: Reads { reading: true, again: false }, read: true },
        ReadEvent::ReadEnded if state.again => {
            ReadStep { state: Reads { reading: true, again: false }, read: true }
        }
        ReadEvent::ReadEnded => ReadStep { state: Reads::default(), read: false },
    }
}

/// A read's list as shown: answers in flight stay off it.
pub fn listed(listed: Vec<Request>, answering: &BTreeSet<String>) -> Vec<Request> {
    listed.into_iter().filter(|r| !answering.contains(&r.conversation)).collect()
}

/// `answer`'s first half: the request comes off the list at once.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Taken {
    pub items: Vec<Request>,
    /// Where it was, to put it back on a refusal.
    pub index: Option<usize>,
    pub request: Option<Request>,
}

/// Takes `conversation` off `items`.
pub fn take(mut items: Vec<Request>, conversation: &str) -> Taken {
    let index = items.iter().position(|r| r.conversation == conversation);
    let request = index.and_then(|i| (i < items.len()).then(|| items.remove(i)));
    Taken { items, index, request }
}

/// `answer`'s refusal: the request shows again where it was, unless a read
/// meanwhile listed it.
pub fn restore(
    mut items: Vec<Request>,
    index: Option<usize>,
    request: Option<Request>,
) -> Vec<Request> {
    if let (Some(request), Some(index)) = (request, index)
        && !items.iter().any(|r| r.conversation == request.conversation)
    {
        let at = index.min(items.len());
        items.insert(at, request);
    }
    items
}
