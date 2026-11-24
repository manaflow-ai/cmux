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


// TAILSDBG temporary instrumentation
fn seglog(dir: &str, p: &[u8]) {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if !*ON.get_or_init(|| std::env::var_os("CMUX_TCP_DBG").is_some()) { return; }
    if p.is_empty() { return; }
    let (proto, off, total) = match p[0] >> 4 {
        4 if p.len() >= 20 => (p[9], usize::from(p[0] & 15) * 4, usize::from(u16::from_be_bytes([p[2], p[3]]))),
        6 if p.len() >= 40 => (p[6], 40, 40 + usize::from(u16::from_be_bytes([p[4], p[5]]))),
        _ => return,
    };
    if proto != 6 || p.len() < off + 20 { return; }
    let t = &p[off..];
    let sp = u16::from_be_bytes([t[0], t[1]]);
    let dp = u16::from_be_bytes([t[2], t[3]]);
    let seq = u32::from_be_bytes([t[4], t[5], t[6], t[7]]);
    let ack = u32::from_be_bytes([t[8], t[9], t[10], t[11]]);
    let doff = usize::from(t[12] >> 4) * 4;
    let fl = t[13];
    let len = total.min(p.len()).saturating_sub(off + doff);
    let mut sack = String::new();
    let mut i = 20;
    while i < doff.min(t.len()) {
        match t[i] { 0 => break, 1 => { i += 1; continue; }
            5 => { let l = usize::from(t[i+1]); let mut j = i + 2; while j + 8 <= i + l { sack.push_str(&format!(" sack={}-{}", u32::from_be_bytes([t[j],t[j+1],t[j+2],t[j+3]]), u32::from_be_bytes([t[j+4],t[j+5],t[j+6],t[j+7]]))); j += 8; } i += l; }
            _ => { if i + 1 >= t.len() || t[i+1] < 2 { break; } i += usize::from(t[i+1]); } }
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_micros();
    eprintln!("SEG {now} {dir} {sp}>{dp} seq={seq} ack={ack} len={len} fl={fl:02x}{sack}");
}

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
        seglog("rx", &packet);
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
        seglog("tx", &packet);
        self.queue.push_back(packet);
        result
    }
}
