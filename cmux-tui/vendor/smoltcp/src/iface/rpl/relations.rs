use crate::time::Instant;
use crate::wire::Ipv6Address;

use crate::config::RPL_RELATIONS_BUFFER_COUNT;

#[derive(Debug)]
pub struct Relation {
    destination: Ipv6Address,
    next_hop: Ipv6Address,
    expiration: Instant,
}

#[derive(Default, Debug)]
pub struct Relations {
    relations: heapless::Vec<Relation, { RPL_RELATIONS_BUFFER_COUNT }>,
}

impl Relations {
    /// Add a new relation to the buffer. If there was already a relation in the buffer, then
    /// update it.
    pub fn add_relation(
        &mut self,
        destination: Ipv6Address,
        next_hop: Ipv6Address,
        expiration: Instant,
    ) {
        if let Some(r) = self
            .relations
            .iter_mut()
            .find(|r| r.destination == destination)
        {
            r.next_hop = next_hop;
            r.expiration = expiration;
        } else {
            let relation = Relation {
                destination,
                next_hop,
                expiration,
            };

            if let Err(e) = self.relations.push(relation) {
                net_debug!("Unable to add relation, buffer is full");
            }
        }
    }

    /// Remove all relation entries for a specific destination.
    pub fn remove_relation(&mut self, destination: Ipv6Address) {
        self.relations.retain(|r| r.destination != destination)
    }

    /// Return the next hop for a specific IPv6 address, if there is one.
    pub fn find_next_hop(&mut self, destination: Ipv6Address) -> Option<Ipv6Address> {
        self.relations.iter().find_map(|r| {
            if r.destination == destination {
                Some(r.next_hop)
            } else {
                None
            }
        })
    }

    /// Purge expired relations.
    pub fn purge(&mut self, now: Instant) {
        self.relations.retain(|r| r.expiration > now)
    }
}

#[cfg(test)]
mod tests {
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
}
