//! What a principal may do in a space.
//!
//! Team and space membership intersect with the principal's home-team grants (RFD 0018, RFD 0115):
//! the effective grants are the host team's policy, intersected with the principal's own grants, for
//! a member of the space only. An agent is further bounded by its owner's effective grants in the
//! same space, so an agent never does more than the person it acts for. A bridge author holds none.
//!
//! `wake` is not a sender grant. It is a property of (space, agent) set by the agent's owner
//! ([`wake_allowed`]); a team policy, a customization or a sender cannot grant it.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::identity::{self, PrincipalKind};
use crate::model::{Principal, Space, Team};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Capability {
    /// Read the space's threads.
    Read,
    /// Post messages and start threads.
    Post,
    /// Comment and vote.
    Feedback,
    /// Link a thread to an RFD, session or another thread.
    Link,
}

impl Capability {
    pub const ALL: [Capability; 4] = [Self::Read, Self::Post, Self::Feedback, Self::Link];
}

/// A set of capabilities.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Grants(pub BTreeSet<Capability>);

impl Grants {
    pub fn none() -> Self {
        Self::default()
    }

    pub fn all() -> Self {
        Self(Capability::ALL.into_iter().collect())
    }

    pub fn of(caps: &[Capability]) -> Self {
        Self(caps.iter().copied().collect())
    }

    pub fn has(&self, c: Capability) -> bool {
        self.0.contains(&c)
    }

    pub fn intersect(&self, other: &Grants) -> Grants {
        Grants(self.0.intersection(&other.0).copied().collect())
    }

    pub fn is_subset(&self, other: &Grants) -> bool {
        self.0.is_subset(&other.0)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// `principal`'s effective grants in `space` of `team`. `owner` is the agent's owner principal, and
/// is required for an agent: an agent with no resolvable owner gets nothing.
pub fn effective(
    principal: &Principal,
    owner: Option<&Principal>,
    team: &Team,
    space: &Space,
) -> Grants {
    if space.team_id != team.id
        || identity::require_rights(principal).is_err()
        || identity::validate(principal).is_err()
        || !space.is_member(&principal.id)
    {
        return Grants::none();
    }
    let own = team.policy.intersect(&principal.capabilities);
    match principal.kind {
        PrincipalKind::Person => own,
        PrincipalKind::Agent => {
            let Some(owner) = owner else { return Grants::none() };
            if owner.kind != PrincipalKind::Person
                || principal.owner_person_id.as_deref() != Some(owner.id.as_str())
            {
                return Grants::none();
            }
            // The owner's own reach in this space bounds the agent, member or not: an agent
            // admitted to a space its owner cannot read gets nothing there.
            own.intersect(&effective(owner, None, team, space))
        }
    }
}

/// Whether a `wake` message in `space` may start `agent`'s turn: only when the agent is a member and
/// its owner (no one else) granted wake there.
pub fn wake_allowed(space: &Space, agent: &Principal) -> bool {
    if agent.kind != PrincipalKind::Agent || !space.is_member(&agent.id) {
        return false;
    }
    let Some(owner) = agent.owner_person_id.as_deref() else { return false };
    space.agent_policy.get(&agent.id).is_some_and(|g| g.wake && g.granted_by == owner)
}
