//! The inbox: every device sends to an Auto chat through the Cloud, and the holder drains it.

use serde::{Deserialize, Serialize};

use super::{Holder, SessionView};

/// `POST /:id/inbox`: one message. The same `id` again answers the same and stores nothing new.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxPost {
    pub id: String,
    pub text: String,
}

/// Where a sent message is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Delivery {
    /// The holder acked it.
    Delivered,
    /// A machine is being started for it. The sender shows "Resuming".
    Resuming,
    /// It waits for the holder's next drain.
    Queued,
}

impl Delivery {
    pub const ALL: [Delivery; 3] = [Delivery::Delivered, Delivery::Resuming, Delivery::Queued];

    pub fn as_str(self) -> &'static str {
        match self {
            Delivery::Delivered => "delivered",
            Delivery::Resuming => "resuming",
            Delivery::Queued => "queued",
        }
    }
}

/// The answer to a sent message.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxPosted {
    pub state: Delivery,
    pub session: SessionView,
}

/// One inbox message as the holder reads it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxMessage {
    /// Its number in the chat's inbox, from 1.
    pub n: u64,
    /// The sender's id for it.
    pub id: String,
    pub text: String,
    /// When the store took it (epoch ms).
    pub at: u64,
}

/// `GET /:id/inbox`: the messages after a number, in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxPage {
    pub messages: Vec<InboxMessage>,
}

/// `POST /:id/inbox/ack`: the holder took every message up to `through`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxAck {
    pub holder: Holder,
    pub epoch: u64,
    pub through: u64,
}
