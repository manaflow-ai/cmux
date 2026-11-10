use crate::phy::{self, Device, DeviceCapabilities};
use crate::time::Instant;
use alloc::vec::Vec;

// This could be fixed once associated consts are stable.
const MTU: usize = 1536;

/// Represents a fuzzer. It is expected to replace bytes in the packet with fuzzed data.
pub trait Fuzzer {
    /// Modify a single packet with fuzzed data.
    fn fuzz_packet(&mut self, packet_data: &mut [u8]);
}

/// A fuzz injector device.
///
/// A fuzz injector is a device that alters packets traversing through it according to the
/// directions of a guided fuzzer. It is designed to support fuzzing internal state machines inside
/// smoltcp, and is not for production use.
#[allow(unused)]
#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct FuzzInjector<D: Device, FTx: Fuzzer, FRx: Fuzzer> {
    inner: D,
    fuzz_tx: FTx,
    fuzz_rx: FRx,
}

#[allow(unused)]
impl<D: Device, FTx: Fuzzer, FRx: Fuzzer> FuzzInjector<D, FTx, FRx> {
    /// Create a fuzz injector device.
    pub fn new(inner: D, fuzz_tx: FTx, fuzz_rx: FRx) -> FuzzInjector<D, FTx, FRx> {
        FuzzInjector {
            inner,
            fuzz_tx,
            fuzz_rx,
        }
    }

    /// Return the underlying device, consuming the fuzz injector.
    pub fn into_inner(self) -> D {
        self.inner
    }
}

impl<D: Device, FTx, FRx> Device for FuzzInjector<D, FTx, FRx>
where
    FTx: Fuzzer,
    FRx: Fuzzer,
{
    type RxToken<'a>
        = RxToken<'a, D::RxToken<'a>, FRx>
    where
        Self: 'a;
    type TxToken<'a>
        = TxToken<'a, D::TxToken<'a>, FTx>
    where
        Self: 'a;

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = self.inner.capabilities();
        if caps.max_transmission_unit > MTU {
            caps.max_transmission_unit = MTU;
        }
        caps
    }

    fn receive(&mut self, timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        self.inner.receive(timestamp).map(|(rx_token, tx_token)| {
            let rx = RxToken {
                fuzzer: &mut self.fuzz_rx,
                token: rx_token,
            };
            let tx = TxToken {
                fuzzer: &mut self.fuzz_tx,
                token: tx_token,
            };
            (rx, tx)
        })
    }

    fn transmit(&mut self, timestamp: Instant) -> Option<Self::TxToken<'_>> {
        self.inner.transmit(timestamp).map(|token| TxToken {
            fuzzer: &mut self.fuzz_tx,
            token: token,
        })
    }
}

#[doc(hidden)]
pub struct RxToken<'a, Rx: phy::RxToken, F: Fuzzer + 'a> {
    fuzzer: &'a mut F,
    token: Rx,
}

impl<'a, Rx: phy::RxToken, FRx: Fuzzer> phy::RxToken for RxToken<'a, Rx, FRx> {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        self.token.consume(|buffer| {
            let mut new_buffer: Vec<u8> = buffer.to_vec();
            self.fuzzer.fuzz_packet(&mut new_buffer);
            f(&mut new_buffer)
        })
    }

    fn meta(&self) -> phy::PacketMeta {
        self.token.meta()
    }
}

#[doc(hidden)]
pub struct TxToken<'a, Tx: phy::TxToken, F: Fuzzer + 'a> {
    fuzzer: &'a mut F,
    token: Tx,
}

impl<'a, Tx: phy::TxToken, FTx: Fuzzer> phy::TxToken for TxToken<'a, Tx, FTx> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        self.token.consume(len, |buf| {
            let result = f(buf);
            self.fuzzer.fuzz_packet(buf);
            result
        })
    }

    fn set_meta(&mut self, meta: phy::PacketMeta) {
        self.token.set_meta(meta)
    }
}
