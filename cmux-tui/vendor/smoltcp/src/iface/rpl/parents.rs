use crate::wire::Ipv6Address;

use super::{lollipop::SequenceCounter, rank::Rank};
use crate::config::RPL_PARENTS_BUFFER_COUNT;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Parent {
    rank: Rank,
    preference: u8,
    version_number: SequenceCounter,
    dodag_id: Ipv6Address,
}

impl Parent {
    /// Create a new parent.
    pub(crate) fn new(
        preference: u8,
        rank: Rank,
        version_number: SequenceCounter,
        dodag_id: Ipv6Address,
    ) -> Self {
        Self {
            rank,
            preference,
            version_number,
            dodag_id,
        }
    }

    /// Return the Rank of the parent.
    pub(crate) fn rank(&self) -> &Rank {
        &self.rank
    }
}

#[derive(Debug, Default)]
pub(crate) struct ParentSet {
    parents: heapless::LinearMap<Ipv6Address, Parent, { RPL_PARENTS_BUFFER_COUNT }>,
}

impl ParentSet {
    /// Add a new parent to the parent set. The Rank of the new parent should be lower than the
    /// Rank of the node that holds this parent set.
    pub(crate) fn add(&mut self, address: Ipv6Address, parent: Parent) {
        if let Some(p) = self.parents.get_mut(&address) {
            *p = parent;
        } else if let Err(p) = self.parents.insert(address, parent) {
            if let Some((w_a, w_p)) = self.worst_parent() {
                if w_p.rank.dag_rank() > parent.rank.dag_rank() {
                    self.parents.remove(&w_a.clone()).unwrap();
                    self.parents.insert(address, parent).unwrap();
                } else {
                    net_debug!("could not add {} to parent set, buffer is full", address);
                }
            } else {
                unreachable!()
            }
        }
    }

    /// Find a parent based on its address.
    pub(crate) fn find(&self, address: &Ipv6Address) -> Option<&Parent> {
        self.parents.get(address)
    }

    /// Find a mutable parent based on its address.
    pub(crate) fn find_mut(&mut self, address: &Ipv6Address) -> Option<&mut Parent> {
        self.parents.get_mut(address)
    }

    /// Return a slice to the parent set.
    pub(crate) fn parents(&self) -> impl Iterator<Item = (&Ipv6Address, &Parent)> {
        self.parents.iter()
    }

    /// Find the worst parent that is currently in the parent set.
    fn worst_parent(&self) -> Option<(&Ipv6Address, &Parent)> {
        self.parents.iter().max_by_key(|(k, v)| v.rank.dag_rank())
    }
}

#[cfg(test)]
#[path = "parents_tests.rs"]
mod tests;
