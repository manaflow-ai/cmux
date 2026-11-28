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
