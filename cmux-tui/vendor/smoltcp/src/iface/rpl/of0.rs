use super::parents::*;
use super::rank::Rank;

pub struct ObjectiveFunction0;

pub(crate) trait ObjectiveFunction {
    const OCP: u16;

    /// Return the new calculated Rank, based on information from the parent.
    fn rank(current_rank: Rank, parent_rank: Rank) -> Rank;

    /// Return the preferred parent from a given parent set.
    fn preferred_parent(parent_set: &ParentSet) -> Option<&Parent>;
}

impl ObjectiveFunction0 {
    const OCP: u16 = 0;

    const RANK_STRETCH: u16 = 0;
    const RANK_FACTOR: u16 = 1;
    const RANK_STEP: u16 = 3;

    fn rank_increase(parent_rank: Rank) -> u16 {
        (Self::RANK_FACTOR * Self::RANK_STEP + Self::RANK_STRETCH)
            * parent_rank.min_hop_rank_increase
    }
}

impl ObjectiveFunction for ObjectiveFunction0 {
    const OCP: u16 = 0;

    fn rank(_: Rank, parent_rank: Rank) -> Rank {
        assert_ne!(parent_rank, Rank::INFINITE);

        Rank::new(
            parent_rank.value + Self::rank_increase(parent_rank),
            parent_rank.min_hop_rank_increase,
        )
    }

    fn preferred_parent(parent_set: &ParentSet) -> Option<&Parent> {
        let mut pref_parent: Option<&Parent> = None;

        for (_, parent) in parent_set.parents() {
            if pref_parent.is_none() || parent.rank() < pref_parent.unwrap().rank() {
                pref_parent = Some(parent);
            }
        }

        pref_parent
    }
}

#[cfg(test)]
mod tests {
    use crate::iface::rpl::consts::DEFAULT_MIN_HOP_RANK_INCREASE;

    use super::*;

    #[test]
    fn rank_increase() {
        // 256 (root) + 3 * 256
        assert_eq!(
            ObjectiveFunction0::rank(Rank::INFINITE, Rank::ROOT),
            Rank::new(256 + 3 * 256, DEFAULT_MIN_HOP_RANK_INCREASE)
        );

        // 1024 + 3 * 256
        assert_eq!(
            ObjectiveFunction0::rank(
                Rank::INFINITE,
                Rank::new(1024, DEFAULT_MIN_HOP_RANK_INCREASE)
            ),
            Rank::new(1024 + 3 * 256, DEFAULT_MIN_HOP_RANK_INCREASE)
        );
    }

    #[test]
    #[should_panic]
    fn rank_increase_infinite() {
        assert_eq!(
            ObjectiveFunction0::rank(Rank::INFINITE, Rank::INFINITE),
            Rank::INFINITE
        );
    }

    #[test]
    fn empty_set() {
        assert_eq!(
            ObjectiveFunction0::preferred_parent(&ParentSet::default()),
            None
        );
    }

    #[test]
    fn non_empty_set() {
        use crate::wire::Ipv6Address;

        let mut parents = ParentSet::default();

        parents.add(
            Ipv6Address::UNSPECIFIED,
            Parent::new(0, Rank::ROOT, Default::default(), Ipv6Address::UNSPECIFIED),
        );

        let address = Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 1);

        parents.add(
            address,
            Parent::new(
                0,
                Rank::new(1024, DEFAULT_MIN_HOP_RANK_INCREASE),
                Default::default(),
                Ipv6Address::UNSPECIFIED,
            ),
        );

        assert_eq!(
            ObjectiveFunction0::preferred_parent(&parents),
            Some(&Parent::new(
                0,
                Rank::ROOT,
                Default::default(),
                Ipv6Address::UNSPECIFIED,
            ))
        );
    }
}
