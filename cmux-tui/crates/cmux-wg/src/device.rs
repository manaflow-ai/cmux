//! The virtual network device smoltcp polls.
//!
//! smoltcp wants a device that hands it received IP packets and accepts the
//! packets it wants to send. Here both directions are plain queues: the driver
//! fills `rx` with packets decrypted by WireGuard and drains `tx` into
//! WireGuard for encryption. There is no link layer, so the medium is `Ip`.

use std::collections::VecDeque;

use smoltcp::phy::{self, Device, DeviceCapabilities, Medium};
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
        syntrace("rx", &packet);
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
        syntrace("tx", &packet);
        self.queue.push_back(packet);
        result
    }
}

// MEASUREMENT ONLY (mfr spurious-SYN count): not for commit.
fn syntrace(dir: &str, p: &[u8]) {
    use std::sync::OnceLock;
    static START: OnceLock<std::time::Instant> = OnceLock::new();
    let start = *START.get_or_init(std::time::Instant::now);
    let (src, dst, tcp) = match p.first().map(|b| b >> 4) {
        Some(4) if p.len() >= 20 && p[9] == 6 => {
            let ihl = usize::from(p[0] & 0x0f) * 4;
            let a = std::net::Ipv4Addr::new(p[12], p[13], p[14], p[15]).to_string();
            let b = std::net::Ipv4Addr::new(p[16], p[17], p[18], p[19]).to_string();
            (a, b, ihl)
        }
        Some(6) if p.len() >= 40 && p[6] == 6 => {
            let mut a = [0u8; 16];
            a.copy_from_slice(&p[8..24]);
            let mut b = [0u8; 16];
            b.copy_from_slice(&p[24..40]);
            (std::net::Ipv6Addr::from(a).to_string(), std::net::Ipv6Addr::from(b).to_string(), 40)
        }
        _ => return,
    };
    if p.len() < tcp + 14 {
        return;
    }
    let flags = p[tcp + 13];
    if flags & 0x02 == 0 {
        return;
    }
    let kind = if flags & 0x10 != 0 { "synack" } else { "syn" };
    let sport = u16::from_be_bytes([p[tcp], p[tcp + 1]]);
    let dport = u16::from_be_bytes([p[tcp + 2], p[tcp + 3]]);
    let seq = u32::from_be_bytes([p[tcp + 4], p[tcp + 5], p[tcp + 6], p[tcp + 7]]);
    eprintln!(
        "SYNTRACE {dir} {kind} {src}:{sport}>{dst}:{dport} seq={seq} len={} t_us={}",
        p.len(),
        start.elapsed().as_micros()
    );
}
