//! Presence over `cmux-sync`'s who's-here table (RFD 0141). Presence is a lease: it is read for the
//! picker and Session Info and never becomes forum history.

use serde::{Deserialize, Serialize};

use cmux_sync::presence::{Here, Kind, Status};

use crate::identity::PrincipalKind;

/// One person or agent who is here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Participant {
    pub principal_id: String,
    pub kind: PrincipalKind,
    pub name: String,
    pub status: Status,
    /// Typing (a person) or in a turn (an agent).
    pub working: bool,
}

pub fn kind_from_sync(kind: Kind) -> PrincipalKind {
    match kind {
        Kind::Person => PrincipalKind::Person,
        Kind::Agent => PrincipalKind::Agent,
    }
}

pub fn from_here(here: &Here) -> Participant {
    Participant {
        principal_id: here.member.id.clone(),
        kind: kind_from_sync(here.member.kind),
        name: here.member.name.clone(),
        status: here.status,
        working: here.working,
    }
}
