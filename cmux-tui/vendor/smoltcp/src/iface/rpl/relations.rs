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
#[path = "relations_tests.rs"]
mod tests;
