use super::*;

#[test]
fn wire_values_round_trip_and_stay_fixed() {
    for (class, wire) in Class::ALL.into_iter().zip(0u8..) {
        assert_eq!(class.wire(), wire);
        assert_eq!(Class::from_wire(wire), Ok(class));
    }
    assert_eq!(Class::from_wire(4), Err(WireClassError(4)));
}

#[test]
fn only_state_waits_for_one_percent_loss() {
    for class in Class::ALL {
        let mut asked = false;
        let repairs = class.repairs_at(|| {
            asked = true;
            false
        });
        assert_eq!(repairs, class != Class::State, "{class}");
        assert_eq!(asked, class == Class::State, "{class} folds loss only when it matters");
    }
    assert!(Class::State.repairs_at(|| true));
}

#[test]
fn class_rules_match_the_rfd_table() {
    assert!(Class::Input.duplicates());
    assert!(Class::ALL.iter().filter(|c| c.duplicates()).count() == 1);
    assert_eq!(Class::State.drop_rule(), DropRule::LatestWins);
    assert_eq!(Class::Bulk.drop_rule(), DropRule::DropOldest);
    assert_eq!(Class::Input.order(), Order::BySeq);
    assert_eq!(Class::Input.carried(), Carried::Datagram);
    assert_eq!(Class::State.carried(), Carried::Datagram);
    assert_eq!(Class::Ordered.carried(), Carried::Stream);
    assert_eq!(Class::Bulk.carried(), Carried::Stream);
}
