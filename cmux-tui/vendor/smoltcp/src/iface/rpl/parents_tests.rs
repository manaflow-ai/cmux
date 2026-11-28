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
