// Tests that are valid with any combination of
// "proto-*" features.
use super::*;

#[test]
fn test_broadcast() {
    assert!(Address::BROADCAST.is_broadcast());
    assert!(!Address::BROADCAST.is_unicast());
    assert!(Address::BROADCAST.is_multicast());
    assert!(Address::BROADCAST.is_local());
}
