//! Moving a chat by hand: `POST /:id/move` (the person's wish), what a chat's view and a lease
//! answer say of it, and the codes the two routes refuse with. The holder answers a wish with
//! `POST /:id/give`, whose body is a [`Fence`](super::Fence).

use std::fmt;

use serde::{Deserialize, Serialize};

use super::Holder;

/// Where the person wants a chat to run now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MoveTo {
    /// The owner's Cloud machine. The chat is then kept in the Cloud.
    Cloud,
    /// A laptop. The chat is then no longer kept in the Cloud.
    Local,
}

impl MoveTo {
    pub const ALL: [MoveTo; 2] = [MoveTo::Cloud, MoveTo::Local];

    pub fn as_str(self) -> &'static str {
        match self {
            MoveTo::Cloud => "cloud",
            MoveTo::Local => "local",
        }
    }

    /// The place a word names; None for any other word.
    pub fn parse(text: &str) -> Option<MoveTo> {
        MoveTo::ALL.into_iter().find(|to| to.as_str() == text)
    }
}

impl fmt::Display for MoveTo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// `POST /:id/move` (owner): move the chat now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveRequest {
    pub to: MoveTo,
    /// With `to: local`, the laptop to move the chat to (`device:<id>`). It has to stand by.
    /// None: the laptop that stands by, the one that renewed last when there are several.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<Holder>,
}

impl MoveRequest {
    /// To the Cloud machine.
    pub fn cloud() -> MoveRequest {
        MoveRequest { to: MoveTo::Cloud, device: None }
    }

    /// To the laptop that stands by.
    pub fn local() -> MoveRequest {
        MoveRequest { to: MoveTo::Local, device: None }
    }

    /// To the laptop `device`, which has to stand by.
    pub fn laptop(device: Holder) -> MoveRequest {
        MoveRequest { to: MoveTo::Local, device: Some(device) }
    }
}

/// `session.move`: the person asked to move the chat and its holder has not given it yet. The
/// store drops it at any change of holder, and after
/// [`MOVE_MS`](crate::consts::MOVE_MS) with no give.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveWish {
    pub to: MoveTo,
    /// The laptop that was named, if one was.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<Holder>,
    /// When it was asked (epoch milliseconds).
    #[serde(default)]
    pub at: u64,
}

/// The codes `move` and `give` refuse with, beside the codes every holder write has
/// ([`ErrorCode`](super::ErrorCode)). An error carries one as its raw code:
/// [`AutoCloudError::move_refusal`](crate::cloud::AutoCloudError::move_refusal) reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MoveRefusal {
    /// `move`: the chat is not an Auto chat.
    #[serde(rename = "auto.off")]
    Off,
    /// `move` to a laptop, or the `give` that answers one: no laptop stands by, or the one that
    /// was named does not.
    #[serde(rename = "auto.no_laptop")]
    NoLaptop,
    /// `give`: nobody asked to move the chat, or the wish is over.
    #[serde(rename = "auto.no_move")]
    NoMove,
    /// The Cloud copy is behind the chat. `give`: store the events and a snapshot that covers
    /// the last one, then give again. `move` of a parked chat to the Cloud: it has no snapshot.
    #[serde(rename = "auto.not_copied")]
    NotCopied,
}

impl MoveRefusal {
    pub const ALL: [MoveRefusal; 4] =
        [MoveRefusal::Off, MoveRefusal::NoLaptop, MoveRefusal::NoMove, MoveRefusal::NotCopied];

    pub fn as_str(self) -> &'static str {
        match self {
            MoveRefusal::Off => "auto.off",
            MoveRefusal::NoLaptop => "auto.no_laptop",
            MoveRefusal::NoMove => "auto.no_move",
            MoveRefusal::NotCopied => "auto.not_copied",
        }
    }

    /// The code a string names; None for any other code.
    pub fn parse(code: &str) -> Option<MoveRefusal> {
        MoveRefusal::ALL.into_iter().find(|known| known.as_str() == code)
    }

    /// The HTTP status the store answers this code with.
    pub fn status(self) -> u16 {
        409
    }
}

impl fmt::Display for MoveRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
