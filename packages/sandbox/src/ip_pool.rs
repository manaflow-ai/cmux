use crate::errors::{SandboxError, SandboxResult};
use std::collections::HashSet;
use std::net::Ipv4Addr;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IpLease {
    pub host: Ipv4Addr,
    pub sandbox: Ipv4Addr,
    pub cidr: u8,
    pub lease_id: u32,
}

#[derive(Debug)]
pub struct IpPool {
    base: Ipv4Addr,
    next_block: u32,
    allocated: HashSet<Ipv4Addr>,
}

impl IpPool {
    pub fn new(base: Ipv4Addr) -> Self {
        Self {
            base,
            next_block: 0,
            allocated: HashSet::new(),
        }
    }

    pub fn allocate(&mut self) -> SandboxResult<IpLease> {
        const BLOCK_SIZE: u32 = 4;
        for _ in 0..u32::MAX {
            let block = self.next_block;
            self.next_block = self.next_block.saturating_add(1);

            let host_offset = block
                .checked_mul(BLOCK_SIZE)
                .and_then(|value| value.checked_add(1))
                .ok_or(SandboxError::IpPoolExhausted)?;
            let sandbox_offset = block
                .checked_mul(BLOCK_SIZE)
                .and_then(|value| value.checked_add(2))
                .ok_or(SandboxError::IpPoolExhausted)?;

            let host_ip = ip_from_offset(self.base, host_offset)?;
            let sandbox_ip = ip_from_offset(self.base, sandbox_offset)?;

            if self.allocated.contains(&host_ip) || self.allocated.contains(&sandbox_ip) {
                continue;
            }

            self.allocated.insert(host_ip);
            self.allocated.insert(sandbox_ip);

            return Ok(IpLease {
                host: host_ip,
                sandbox: sandbox_ip,
                cidr: 30,
                lease_id: block,
            });
        }

        Err(SandboxError::IpPoolExhausted)
    }

    pub fn release(&mut self, lease: &IpLease) {
        self.allocated.remove(&lease.host);
        self.allocated.remove(&lease.sandbox);
        self.next_block = self.next_block.min(lease.lease_id);
    }
}

fn ip_from_offset(base: Ipv4Addr, offset: u32) -> SandboxResult<Ipv4Addr> {
    let base_value = u32::from_be_bytes(base.octets());
    let combined = base_value
        .checked_add(offset)
        .ok_or(SandboxError::IpPoolExhausted)?;
    Ok(Ipv4Addr::from(combined))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocates_unique_pairs_and_releases() {
        let mut pool = IpPool::new(Ipv4Addr::new(10, 200, 0, 0));
        let first = pool.allocate().unwrap();
        let second = pool.allocate().unwrap();
        assert_ne!(first.host, second.host);
        assert_ne!(first.sandbox, second.sandbox);

        // Release the first lease and ensure it can be reused.
        pool.release(&first);
        let third = pool.allocate().unwrap();
        assert_eq!(first.host, third.host);
        assert_eq!(first.sandbox, third.sandbox);
    }
}
