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
mod tests {
    use super::*;

    #[test]
    fn add_parent() {
        let mut set = ParentSet::default();
        set.add(
            Ipv6Address::UNSPECIFIED,
            Parent::new(0, Rank::ROOT, Default::default(), Ipv6Address::UNSPECIFIED),
        );

        assert_eq!(
            set.find(&Ipv6Address::UNSPECIFIED),
            Some(&Parent::new(
                0,
                Rank::ROOT,
                Default::default(),
                Ipv6Address::UNSPECIFIED
            ))
        );
    }

    #[test]
    fn add_more_parents() {
        use super::super::consts::DEFAULT_MIN_HOP_RANK_INCREASE;
        let mut set = ParentSet::default();

        let mut last_address = Ipv6Address::UNSPECIFIED;
        for i in 0..RPL_PARENTS_BUFFER_COUNT {
            let i = i as u16;
            let address = Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, i as _);
            last_address = address;

            set.add(
                address,
                Parent::new(
                    0,
                    Rank::new(256 * i, DEFAULT_MIN_HOP_RANK_INCREASE),
                    Default::default(),
                    address,
                ),
            );

            assert_eq!(
                set.find(&address),
                Some(&Parent::new(
                    0,
                    Rank::new(256 * i, DEFAULT_MIN_HOP_RANK_INCREASE),
                    Default::default(),
                    address,
                ))
            );
        }

        // This one is not added to the set, because its Rank is worse than any other parent in the
        // set.
        let address = Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 8);
        set.add(
            address,
            Parent::new(
                0,
                Rank::new(256 * 8, DEFAULT_MIN_HOP_RANK_INCREASE),
                Default::default(),
                address,
            ),
        );
        assert_eq!(set.find(&address), None);

        /// This Parent has a better rank than the last one in the set.
        let address = Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 9);
        set.add(
            address,
            Parent::new(
                0,
                Rank::new(0, DEFAULT_MIN_HOP_RANK_INCREASE),
                Default::default(),
                address,
            ),
        );
        assert_eq!(
            set.find(&address),
            Some(&Parent::new(
                0,
                Rank::new(0, DEFAULT_MIN_HOP_RANK_INCREASE),
                Default::default(),
                address
            ))
        );
        assert_eq!(set.find(&last_address), None);
    }
}
