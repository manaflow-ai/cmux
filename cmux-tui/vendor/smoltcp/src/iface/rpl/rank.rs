//! Implementation of the Rank comparison in RPL.
//!
//! A Rank can be thought of as a fixed-point number, where the position of the radix point between
//! the integer part and the fractional part is determined by `MinHopRankIncrease`.
//! `MinHopRankIncrease` is the minimum increase in Rank between a node and any of its DODAG
//! parents.
//! This value is provisined by the DODAG root.
//!
//! When Rank is compared, the integer portion of the Rank is to be used.
//!
//! Meaning of the comparison:
//! - **Rank M is less than Rank N**: the position of M is closer to the DODAG root than the position
//! of N. Node M may safely be a DODAG parent for node N.
//! - **Ranks are equal**: the positions of both nodes within the DODAG and with respect to the DODAG
//! are similar or identical. Routing through a node with equal Rank may cause a routing loop.
//! - **Rank M is greater than Rank N**: the position of node M is farther from the DODAG root
//! than the position of N. Node M may in fact be in the sub-DODAG of node N. If node N selects
//! node M as a DODAG parent, there is a risk of creating a loop.

use super::consts::DEFAULT_MIN_HOP_RANK_INCREASE;

/// The Rank is the expression of the relative position within a DODAG Version with regard to
/// neighbors, and it is not necessarily a good indication or a proper expression of a distance or
/// a path cost to the root.
#[derive(Debug, Clone, Copy, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Rank {
    pub(super) value: u16,
    pub(super) min_hop_rank_increase: u16,
}

impl core::fmt::Display for Rank {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "Rank({})", self.dag_rank())
    }
}

impl Rank {
    pub const INFINITE: Self = Rank::new(0xffff, DEFAULT_MIN_HOP_RANK_INCREASE);

    /// The ROOT_RANK is the smallest rank possible.
    /// DAG_RANK(ROOT_RANK) should be 1. See RFC6550 § 17.
    pub const ROOT: Self = Rank::new(DEFAULT_MIN_HOP_RANK_INCREASE, DEFAULT_MIN_HOP_RANK_INCREASE);

    /// Create a new Rank from some value and a `MinHopRankIncrease`.
    /// The `MinHopRankIncrease` is used for calculating the integer part for comparing to other
    /// Ranks.
    pub const fn new(value: u16, min_hop_rank_increase: u16) -> Self {
        assert!(min_hop_rank_increase > 0);

        Self {
            value,
            min_hop_rank_increase,
        }
    }

    /// Return the integer part of the Rank.
    pub fn dag_rank(&self) -> u16 {
        self.value / self.min_hop_rank_increase
    }

    /// Return the raw Rank value.
    pub fn raw_value(&self) -> u16 {
        self.value
    }
}

impl PartialEq for Rank {
    fn eq(&self, other: &Self) -> bool {
        self.dag_rank() == other.dag_rank()
    }
}

impl PartialOrd for Rank {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        self.dag_rank().partial_cmp(&other.dag_rank())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calculate_rank() {
        let r = Rank::new(27, 16);
        assert_eq!(r.dag_rank(), 1)
    }

    #[test]
    fn comparison() {
        let r1 = Rank::ROOT;
        let r2 = Rank::new(16, 16);
        assert!(r1 == r2);

        let r1 = Rank::new(16, 16);
        let r2 = Rank::new(32, 16);
        assert!(r1 < r2);

        let r1 = Rank::ROOT;
        let r2 = Rank::INFINITE;
        assert!(r1 < r2);
    }
}
