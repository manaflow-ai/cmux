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
#[path = "of0_tests.rs"]
mod tests;
