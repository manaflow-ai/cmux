use byteorder::{ByteOrder, NativeEndian};
use core::cell::RefCell;
use phy::Medium;
#[cfg(feature = "std")]
use std::io::Write;

use crate::phy::{self, Device, DeviceCapabilities};
use crate::time::Instant;

enum_with_unknown! {
    /// Captured packet header type.
    pub enum PcapLinkType(u32) {
        /// Ethernet frames
        Ethernet =   1,
        /// IPv4 or IPv6 packets (depending on the version field)
        Ip       = 101,
        /// IEEE 802.15.4 packets without FCS.
        Ieee802154WithoutFcs = 230,
    }
}

/// Packet capture mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum PcapMode {
    /// Capture both received and transmitted packets.
    Both,
    /// Capture only received packets.
    RxOnly,
    /// Capture only transmitted packets.
    TxOnly,
}

/// A packet capture sink.
pub trait PcapSink {
    /// Write data into the sink.
    fn write(&mut self, data: &[u8]);

    /// Flush data written into the sync.
    fn flush(&mut self) {}

    /// Write an `u16` into the sink, in native byte order.
    fn write_u16(&mut self, value: u16) {
        let mut bytes = [0u8; 2];
        NativeEndian::write_u16(&mut bytes, value);
        self.write(&bytes[..])
    }

    /// Write an `u32` into the sink, in native byte order.
    fn write_u32(&mut self, value: u32) {
        let mut bytes = [0u8; 4];
        NativeEndian::write_u32(&mut bytes, value);
        self.write(&bytes[..])
    }

    /// Write the libpcap global header into the sink.
    ///
    /// This method may be overridden e.g. if special synchronization is necessary.
    fn global_header(&mut self, link_type: PcapLinkType) {
        self.write_u32(0xa1b2c3d4); // magic number
        self.write_u16(2); // major version
        self.write_u16(4); // minor version
        self.write_u32(0); // timezone (= UTC)
        self.write_u32(0); // accuracy (not used)
        self.write_u32(self.max_packet_size()); // maximum packet length
        self.write_u32(link_type.into()); // link-layer header type
    }

    /// Write the libpcap packet header into the sink.
    ///
    /// See also the note for [global_header](#method.global_header).
    ///
    /// # Panics
    /// This function panics if `length` is greater than [u32::MAX].
    fn packet_header(&mut self, timestamp: Instant, length: usize) {
        let original_length = length.try_into().unwrap();

        self.write_u32(timestamp.secs() as u32); // timestamp seconds
        self.write_u32(timestamp.micros() as u32); // timestamp microseconds
        self.write_u32(self.max_packet_size().min(original_length)); // captured length
        self.write_u32(original_length);
    }

    /// Write the libpcap packet header followed by packet data into the sink.
    ///
    /// The default implementation truncates packets that are larger than [Self::max_packet_size].
    ///
    /// See also the note for [global_header](#method.global_header).
    fn packet(&mut self, timestamp: Instant, packet: &[u8]) {
        let packet_len = packet.len();
        let max_packet_size = usize::try_from(self.max_packet_size()).unwrap();

        self.packet_header(timestamp, packet_len);
        self.write(&packet[..max_packet_size.min(packet_len)]);
        self.flush();
    }

    /// Return the maximum size for captured packets.
    ///
    /// The captures of packets larger than this size will be truncated by default. Excessively
    /// large values may cause the software reading the captures to allocate unnecessarily large
    /// buffers.
    fn max_packet_size(&self) -> u32 {
        // Use the default value used by [libpcap] and [Wireshark].
        // [Wireshark]: https://gitlab.com/wireshark/wireshark/-/blob/v3.5.0/wiretap/wtap.h#L334
        // [libpcap]: https://github.com/the-tcpdump-group/libpcap/blob/libpcap-1.6.0-bp/pcap-int.h#L106
        262144
    }
}

#[cfg(feature = "std")]
impl<T: Write> PcapSink for T {
    fn write(&mut self, data: &[u8]) {
        T::write_all(self, data).expect("cannot write")
    }

    fn flush(&mut self) {
        T::flush(self).expect("cannot flush")
    }
}

/// A packet capture writer device.
///
/// Every packet transmitted or received through this device is timestamped
/// and written (in the [libpcap] format) using the provided [sink].
/// Note that writes are fine-grained, and buffering is recommended.
///
/// [libpcap]: https://wiki.wireshark.org/Development/LibpcapFileFormat
/// [sink]: trait.PcapSink.html
#[derive(Debug)]
pub struct PcapWriter<D, S>
where
    D: Device,
    S: PcapSink,
{
    lower: D,
    sink: RefCell<S>,
    mode: PcapMode,
}

impl<D: Device, S: PcapSink> PcapWriter<D, S> {
    /// Creates a packet capture writer.
    pub fn new(lower: D, mut sink: S, mode: PcapMode) -> PcapWriter<D, S> {
        let medium = lower.capabilities().medium;
        let link_type = match medium {
            #[cfg(feature = "medium-ip")]
            Medium::Ip => PcapLinkType::Ip,
            #[cfg(feature = "medium-ethernet")]
            Medium::Ethernet => PcapLinkType::Ethernet,
            #[cfg(feature = "medium-ieee802154")]
            Medium::Ieee802154 => PcapLinkType::Ieee802154WithoutFcs,
        };
        sink.global_header(link_type);
        PcapWriter {
            lower,
            sink: RefCell::new(sink),
            mode,
        }
    }

    /// Get a reference to the underlying device.
    ///
    /// Even if the device offers reading through a standard reference, it is inadvisable to
    /// directly read from the device as doing so will circumvent the packet capture.
    pub fn get_ref(&self) -> &D {
        &self.lower
    }

    /// Get a mutable reference to the underlying device.
    ///
    /// It is inadvisable to directly read from the device as doing so will circumvent the packet capture.
    pub fn get_mut(&mut self) -> &mut D {
        &mut self.lower
    }
}

impl<D: Device, S> Device for PcapWriter<D, S>
where
    S: PcapSink,
{
    type RxToken<'a>
        = RxToken<'a, D::RxToken<'a>, S>
    where
        Self: 'a;
    type TxToken<'a>
        = TxToken<'a, D::TxToken<'a>, S>
    where
        Self: 'a;

    fn capabilities(&self) -> DeviceCapabilities {
        self.lower.capabilities()
    }

    fn receive(&mut self, timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let sink = &self.sink;
        let mode = self.mode;
        self.lower
            .receive(timestamp)
            .map(move |(rx_token, tx_token)| {
                let rx = RxToken {
                    token: rx_token,
                    sink,
                    mode,
                    timestamp,
                };
                let tx = TxToken {
                    token: tx_token,
                    sink,
                    mode,
                    timestamp,
                };
                (rx, tx)
            })
    }

    fn transmit(&mut self, timestamp: Instant) -> Option<Self::TxToken<'_>> {
        let sink = &self.sink;
        let mode = self.mode;
        self.lower.transmit(timestamp).map(move |token| TxToken {
            token,
            sink,
            mode,
            timestamp,
        })
    }
}

#[doc(hidden)]
pub struct RxToken<'a, Rx: phy::RxToken, S: PcapSink> {
    token: Rx,
    sink: &'a RefCell<S>,
    mode: PcapMode,
    timestamp: Instant,
}

impl<'a, Rx: phy::RxToken, S: PcapSink> phy::RxToken for RxToken<'a, Rx, S> {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        self.token.consume(|buffer| {
            match self.mode {
                PcapMode::Both | PcapMode::RxOnly => self
                    .sink
                    .borrow_mut()
                    .packet(self.timestamp, buffer.as_ref()),
                PcapMode::TxOnly => (),
            }
            f(buffer)
        })
    }

    fn meta(&self) -> phy::PacketMeta {
        self.token.meta()
    }
}

#[doc(hidden)]
pub struct TxToken<'a, Tx: phy::TxToken, S: PcapSink> {
    token: Tx,
    sink: &'a RefCell<S>,
    mode: PcapMode,
    timestamp: Instant,
}

impl<'a, Tx: phy::TxToken, S: PcapSink> phy::TxToken for TxToken<'a, Tx, S> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        self.token.consume(len, |buffer| {
            let result = f(buffer);
            match self.mode {
                PcapMode::Both | PcapMode::TxOnly => {
                    self.sink.borrow_mut().packet(self.timestamp, buffer)
                }
                PcapMode::RxOnly => (),
            };
            result
        })
    }

    fn set_meta(&mut self, meta: phy::PacketMeta) {
        self.token.set_meta(meta)
    }
}
