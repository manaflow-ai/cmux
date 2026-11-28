use super::*;
use crate::time::Duration;

fn addresses(count: usize) -> Vec<Ipv6Address> {
    (0..count)
        .map(|i| Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, i as _))
        .collect()
}

#[test]
fn add_relation() {
    let addrs = addresses(2);

    let mut relations = Relations::default();
    relations.add_relation(addrs[0], addrs[1], Instant::now());
    assert_eq!(relations.relations.len(), 1);
}

#[test]
fn add_relations_full_buffer() {
    let addrs = addresses(crate::config::RPL_RELATIONS_BUFFER_COUNT + 1);

    // Try to add RPL_RELATIONS_BUFFER_COUNT + 1 to the buffer.
    // The size of the buffer should still be RPL_RELATIONS_BUFFER_COUNT.
    let mut relations = Relations::default();
    for a in addrs {
        relations.add_relation(a, a, Instant::now());
    }

    assert_eq!(relations.relations.len(), RPL_RELATIONS_BUFFER_COUNT);
}

#[test]
fn update_relation() {
    let addrs = addresses(3);

    let mut relations = Relations::default();
    relations.add_relation(addrs[0], addrs[1], Instant::now());
    assert_eq!(relations.relations.len(), 1);

    relations.add_relation(addrs[0], addrs[2], Instant::now());
    assert_eq!(relations.relations.len(), 1);

    assert_eq!(relations.find_next_hop(addrs[0]), Some(addrs[2]));
}

#[test]
fn find_next_hop() {
    let addrs = addresses(3);

    let mut relations = Relations::default();
    relations.add_relation(addrs[0], addrs[1], Instant::now());
    assert_eq!(relations.relations.len(), 1);
    assert_eq!(relations.find_next_hop(addrs[0]), Some(addrs[1]));

    relations.add_relation(addrs[0], addrs[2], Instant::now());
    assert_eq!(relations.relations.len(), 1);
    assert_eq!(relations.find_next_hop(addrs[0]), Some(addrs[2]));

    // Find the next hop of a destination not in the buffer.
    assert_eq!(relations.find_next_hop(addrs[1]), None);
}

#[test]
fn remove_relation() {
    let addrs = addresses(2);

    let mut relations = Relations::default();
    relations.add_relation(addrs[0], addrs[1], Instant::now());
    assert_eq!(relations.relations.len(), 1);

    relations.remove_relation(addrs[0]);
    assert!(relations.relations.is_empty());
}

#[test]
fn purge_relation() {
    let addrs = addresses(2);

    let mut relations = Relations::default();
    relations.add_relation(addrs[0], addrs[1], Instant::now() - Duration::from_secs(1));

    assert_eq!(relations.relations.len(), 1);

    relations.purge(Instant::now());
    assert!(relations.relations.is_empty());
}
