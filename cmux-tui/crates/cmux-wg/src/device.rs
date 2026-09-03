//! The virtual network device smoltcp polls.
//!
//! smoltcp wants a device that hands it received IP packets and accepts the
//! packets it wants to send. Here both directions are plain queues: the driver
//! fills `rx` with packets decrypted by WireGuard and drains `tx` into
//! WireGuard for encryption. There is no link layer, so the medium is `Ip`.

use std::collections::VecDeque;

use smoltcp::phy::{self, Checksum, Device, DeviceCapabilities, Medium};
use smoltcp::time::Instant;

/// Packets smoltcp may queue before the driver drains them. Backpressure past
/// this point comes from smoltcp itself: `transmit` returns `None` and TCP
/// waits for the next poll.
const MAX_TX_QUEUE: usize = 256;

pub(crate) struct VirtualDevice {
    rx: VecDeque<Vec<u8>>,
    tx: VecDeque<Vec<u8>>,
    mtu: usize,
}

impl VirtualDevice {
    pub(crate) fn new(mtu: u16) -> Self {
        Self { rx: VecDeque::new(), tx: VecDeque::new(), mtu: usize::from(mtu) }
    }

    /// Queue a decrypted packet for smoltcp to receive on the next poll.
    pub(crate) fn push_rx(&mut self, packet: Vec<u8>) {
        self.rx.push_back(packet);
    }

    /// Take the next packet smoltcp wants sent.
    pub(crate) fn pop_tx(&mut self) -> Option<Vec<u8>> {
        self.tx.pop_front()
    }

    pub(crate) fn has_rx(&self) -> bool {
        !self.rx.is_empty()
    }
}

impl Device for VirtualDevice {
    type RxToken<'a>
        = RxToken
    where
        Self: 'a;
    type TxToken<'a>
        = TxToken<'a>
    where
        Self: 'a;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let packet = self.rx.pop_front()?;
        Some((RxToken(packet), TxToken { queue: &mut self.tx }))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        if self.tx.len() >= MAX_TX_QUEUE {
            return None;
        }
        Some(TxToken { queue: &mut self.tx })
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut capabilities = DeviceCapabilities::default();
        capabilities.medium = Medium::Ip;
        capabilities.max_transmission_unit = self.mtu;
        // Every packet that reaches this device was authenticated by
        // WireGuard's AEAD, so IP and transport checksums add no integrity.
        // Linux treats decrypted WireGuard packets the same way
        // (`CHECKSUM_UNNECESSARY`). Verifying them here is worse than useless:
        // a router in the private network that rewrites IPv4 headers without
        // fixing the header checksum makes IPv6 work and IPv4 time out, which
        // is exactly what a kernel peer would never notice. Checksums are
        // still computed on transmit so the far side can verify them.
        capabilities.checksum.ipv4 = Checksum::Tx;
        capabilities.checksum.tcp = Checksum::Tx;
        capabilities.checksum.udp = Checksum::Tx;
        capabilities.checksum.icmpv4 = Checksum::Tx;
        capabilities.checksum.icmpv6 = Checksum::Tx;
        capabilities
    }
}

pub(crate) struct RxToken(Vec<u8>);

impl phy::RxToken for RxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.0)
    }
}

pub(crate) struct TxToken<'a> {
    queue: &'a mut VecDeque<Vec<u8>>,
}

impl phy::TxToken for TxToken<'_> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut packet = vec![0u8; len];
        let result = f(&mut packet);
        self.queue.push_back(packet);
        result
    }
}
