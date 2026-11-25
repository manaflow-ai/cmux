use core::cmp::min;
#[cfg(feature = "async")]
use core::task::Waker;

use crate::iface::Context;
use crate::socket::PollAt;
#[cfg(feature = "async")]
use crate::socket::WakerRegistration;

use crate::storage::Empty;
use crate::wire::{IpProtocol, IpRepr, IpVersion};
#[cfg(feature = "proto-ipv4")]
use crate::wire::{Ipv4Packet, Ipv4Repr};
#[cfg(feature = "proto-ipv6")]
use crate::wire::{Ipv6Packet, Ipv6Repr};

/// Error returned by [`Socket::bind`]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum BindError {
    InvalidState,
    Unaddressable,
}

impl core::fmt::Display for BindError {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        match self {
            BindError::InvalidState => write!(f, "invalid state"),
            BindError::Unaddressable => write!(f, "unaddressable"),
        }
    }
}

impl core::error::Error for BindError {}

/// Error returned by [`Socket::send`]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum SendError {
    BufferFull,
}

impl core::fmt::Display for SendError {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        match self {
            SendError::BufferFull => write!(f, "buffer full"),
        }
    }
}

impl core::error::Error for SendError {}

/// Error returned by [`Socket::recv`]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum RecvError {
    Exhausted,
    Truncated,
}

impl core::fmt::Display for RecvError {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        match self {
            RecvError::Exhausted => write!(f, "exhausted"),
            RecvError::Truncated => write!(f, "truncated"),
        }
    }
}

impl core::error::Error for RecvError {}

/// A UDP packet metadata.
pub type PacketMetadata = crate::storage::PacketMetadata<()>;

/// A UDP packet ring buffer.
pub type PacketBuffer<'a> = crate::storage::PacketBuffer<'a, ()>;

/// A raw IP socket.
///
/// A raw socket may be bound to a specific IP protocol, and owns
/// transmit and receive packet buffers.
#[derive(Debug)]
pub struct Socket<'a> {
    ip_version: Option<IpVersion>,
    ip_protocol: Option<IpProtocol>,
    rx_buffer: PacketBuffer<'a>,
    tx_buffer: PacketBuffer<'a>,
    #[cfg(feature = "async")]
    rx_waker: WakerRegistration,
    #[cfg(feature = "async")]
    tx_waker: WakerRegistration,
}

impl<'a> Socket<'a> {
    /// Create a raw IP socket bound to the given IP version and datagram protocol,
    /// with the given buffers.
    pub fn new(
        ip_version: Option<IpVersion>,
        ip_protocol: Option<IpProtocol>,
        rx_buffer: PacketBuffer<'a>,
        tx_buffer: PacketBuffer<'a>,
    ) -> Socket<'a> {
        Socket {
            ip_version,
            ip_protocol,
            rx_buffer,
            tx_buffer,
            #[cfg(feature = "async")]
            rx_waker: WakerRegistration::new(),
            #[cfg(feature = "async")]
            tx_waker: WakerRegistration::new(),
        }
    }

    /// Register a waker for receive operations.
    ///
    /// The waker is woken on state changes that might affect the return value
    /// of `recv` method calls, such as receiving data, or the socket closing.
    ///
    /// Notes:
    ///
    /// - Only one waker can be registered at a time. If another waker was previously registered,
    ///   it is overwritten and will no longer be woken.
    /// - The Waker is woken only once. Once woken, you must register it again to receive more wakes.
    /// - "Spurious wakes" are allowed: a wake doesn't guarantee the result of `recv` has
    ///   necessarily changed.
    #[cfg(feature = "async")]
    pub fn register_recv_waker(&mut self, waker: &Waker) {
        self.rx_waker.register(waker)
    }

    /// Register a waker for send operations.
    ///
    /// The waker is woken on state changes that might affect the return value
    /// of `send` method calls, such as space becoming available in the transmit
    /// buffer, or the socket closing.
    ///
    /// Notes:
    ///
    /// - Only one waker can be registered at a time. If another waker was previously registered,
    ///   it is overwritten and will no longer be woken.
    /// - The Waker is woken only once. Once woken, you must register it again to receive more wakes.
    /// - "Spurious wakes" are allowed: a wake doesn't guarantee the result of `send` has
    ///   necessarily changed.
    #[cfg(feature = "async")]
    pub fn register_send_waker(&mut self, waker: &Waker) {
        self.tx_waker.register(waker)
    }

    /// Return the IP version the socket is bound to.
    #[inline]
    pub fn ip_version(&self) -> Option<IpVersion> {
        self.ip_version
    }

    /// Return the IP protocol the socket is bound to.
    #[inline]
    pub fn ip_protocol(&self) -> Option<IpProtocol> {
        self.ip_protocol
    }

    /// Check whether the transmit buffer is full.
    #[inline]
    pub fn can_send(&self) -> bool {
        !self.tx_buffer.is_full()
    }

    /// Check whether the receive buffer is not empty.
    #[inline]
    pub fn can_recv(&self) -> bool {
        !self.rx_buffer.is_empty()
    }

    /// Return the maximum number packets the socket can receive.
    #[inline]
    pub fn packet_recv_capacity(&self) -> usize {
        self.rx_buffer.packet_capacity()
    }

    /// Return the maximum number packets the socket can transmit.
    #[inline]
    pub fn packet_send_capacity(&self) -> usize {
        self.tx_buffer.packet_capacity()
    }

    /// Return the maximum number of bytes inside the recv buffer.
    #[inline]
    pub fn payload_recv_capacity(&self) -> usize {
        self.rx_buffer.payload_capacity()
    }

    /// Return the maximum number of bytes inside the transmit buffer.
    #[inline]
    pub fn payload_send_capacity(&self) -> usize {
        self.tx_buffer.payload_capacity()
    }

    /// Enqueue a packet to send, and return a pointer to its payload.
    ///
    /// This function returns `Err(Error::Exhausted)` if the transmit buffer is full,
    /// and `Err(Error::Truncated)` if there is not enough transmit buffer capacity
    /// to ever send this packet.
    ///
    /// If the buffer is filled in a way that does not match the socket's
    /// IP version or protocol, the packet will be silently dropped.
    ///
    /// **Note:** The IP header is parsed and re-serialized, and may not match
    /// the header actually transmitted bit for bit.
    pub fn send(&mut self, size: usize) -> Result<&mut [u8], SendError> {
        let packet_buf = self
            .tx_buffer
            .enqueue(size, ())
            .map_err(|_| SendError::BufferFull)?;

        net_trace!(
            "raw:{:?}:{:?}: buffer to send {} octets",
            self.ip_version,
            self.ip_protocol,
            packet_buf.len()
        );
        Ok(packet_buf)
    }

    /// Enqueue a packet to be send and pass the buffer to the provided closure.
    /// The closure then returns the size of the data written into the buffer.
    ///
    /// Also see [send](#method.send).
    pub fn send_with<F>(&mut self, max_size: usize, f: F) -> Result<usize, SendError>
    where
        F: FnOnce(&mut [u8]) -> usize,
    {
        let size = self
            .tx_buffer
            .enqueue_with_infallible(max_size, (), f)
            .map_err(|_| SendError::BufferFull)?;

        net_trace!(
            "raw:{:?}:{:?}: buffer to send {} octets",
            self.ip_version,
            self.ip_protocol,
            size
        );

        Ok(size)
    }

    /// Enqueue a packet to send, and fill it from a slice.
    ///
    /// See also [send](#method.send).
    pub fn send_slice(&mut self, data: &[u8]) -> Result<(), SendError> {
        self.send(data.len())?.copy_from_slice(data);
        Ok(())
    }

    /// Dequeue a packet, and return a pointer to the payload.
    ///
    /// This function returns `Err(Error::Exhausted)` if the receive buffer is empty.
    ///
    /// **Note:** The IP header is parsed and re-serialized, and may not match
    /// the header actually received bit for bit.
    pub fn recv(&mut self) -> Result<&[u8], RecvError> {
        let ((), packet_buf) = self.rx_buffer.dequeue().map_err(|_| RecvError::Exhausted)?;

        net_trace!(
            "raw:{:?}:{:?}: receive {} buffered octets",
            self.ip_version,
            self.ip_protocol,
            packet_buf.len()
        );
        Ok(packet_buf)
    }

    /// Dequeue a packet, and copy the payload into the given slice.
    ///
    /// **Note**: when the size of the provided buffer is smaller than the size of the payload,
    /// the packet is dropped and a `RecvError::Truncated` error is returned.
    ///
    /// See also [recv](#method.recv).
    pub fn recv_slice(&mut self, data: &mut [u8]) -> Result<usize, RecvError> {
        let buffer = self.recv()?;
        if data.len() < buffer.len() {
            return Err(RecvError::Truncated);
        }

        let length = min(data.len(), buffer.len());
        data[..length].copy_from_slice(&buffer[..length]);
        Ok(length)
    }

    /// Peek at a packet in the receive buffer and return a pointer to the
    /// payload without removing the packet from the receive buffer.
    /// This function otherwise behaves identically to [recv](#method.recv).
    ///
    /// It returns `Err(Error::Exhausted)` if the receive buffer is empty.
    pub fn peek(&mut self) -> Result<&[u8], RecvError> {
        let ((), packet_buf) = self.rx_buffer.peek().map_err(|_| RecvError::Exhausted)?;

        net_trace!(
            "raw:{:?}:{:?}: receive {} buffered octets",
            self.ip_version,
            self.ip_protocol,
            packet_buf.len()
        );

        Ok(packet_buf)
    }

    /// Peek at a packet in the receive buffer, copy the payload into the given slice,
    /// and return the amount of octets copied without removing the packet from the receive buffer.
    /// This function otherwise behaves identically to [recv_slice](#method.recv_slice).
    ///
    /// **Note**: when the size of the provided buffer is smaller than the size of the payload,
    /// no data is copied into the provided buffer and a `RecvError::Truncated` error is returned.
    ///
    /// See also [peek](#method.peek).
    pub fn peek_slice(&mut self, data: &mut [u8]) -> Result<usize, RecvError> {
        let buffer = self.peek()?;
        if data.len() < buffer.len() {
            return Err(RecvError::Truncated);
        }

        let length = min(data.len(), buffer.len());
        data[..length].copy_from_slice(&buffer[..length]);
        Ok(length)
    }

    /// Return the amount of octets queued in the transmit buffer.
    pub fn send_queue(&self) -> usize {
        self.tx_buffer.payload_bytes_count()
    }

    /// Return the amount of octets queued in the receive buffer.
    pub fn recv_queue(&self) -> usize {
        self.rx_buffer.payload_bytes_count()
    }

    pub(crate) fn accepts(&self, ip_repr: &IpRepr) -> bool {
        if self
            .ip_version
            .is_some_and(|version| version != ip_repr.version())
        {
            return false;
        }

        if self
            .ip_protocol
            .is_some_and(|next_header| next_header != ip_repr.next_header())
        {
            return false;
        }

        true
    }

    pub(crate) fn process(&mut self, cx: &mut Context, ip_repr: &IpRepr, payload: &[u8]) {
        debug_assert!(self.accepts(ip_repr));

        let header_len = ip_repr.header_len();
        let total_len = header_len + payload.len();

        net_trace!(
            "raw:{:?}:{:?}: receiving {} octets",
            self.ip_version,
            self.ip_protocol,
            total_len
        );

        match self.rx_buffer.enqueue(total_len, ()) {
            Ok(buf) => {
                ip_repr.emit(&mut buf[..header_len], &cx.checksum_caps());
                buf[header_len..].copy_from_slice(payload);
            }
            Err(_) => net_trace!(
                "raw:{:?}:{:?}: buffer full, dropped incoming packet",
                self.ip_version,
                self.ip_protocol
            ),
        }

        #[cfg(feature = "async")]
        self.rx_waker.wake();
    }

    pub(crate) fn dispatch<F, E>(&mut self, cx: &mut Context, emit: F) -> Result<(), E>
    where
        F: FnOnce(&mut Context, (IpRepr, &[u8])) -> Result<(), E>,
    {
        let ip_protocol = self.ip_protocol;
        let ip_version = self.ip_version;
        let _checksum_caps = &cx.checksum_caps();
        let res = self.tx_buffer.dequeue_with(|&mut (), buffer| {
            match IpVersion::of_packet(buffer) {
                #[cfg(feature = "proto-ipv4")]
                Ok(IpVersion::Ipv4) => {
                    let mut packet = match Ipv4Packet::new_checked(buffer) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!("raw: malformed ipv6 packet in queue, dropping.");
                            return Ok(());
                        }
                    };
                    if ip_protocol.is_some_and(|next_header| next_header != packet.next_header()) {
                        net_trace!("raw: sent packet with wrong ip protocol, dropping.");
                        return Ok(());
                    }
                    if _checksum_caps.ipv4.tx() {
                        packet.fill_checksum();
                    } else {
                        // make sure we get a consistently zeroed checksum,
                        // since implementations might rely on it
                        packet.set_checksum(0);
                    }

                    let packet = Ipv4Packet::new_unchecked(&*packet.into_inner());
                    let ipv4_repr = match Ipv4Repr::parse(&packet, _checksum_caps) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!("raw: malformed ipv4 packet in queue, dropping.");
                            return Ok(());
                        }
                    };
                    net_trace!("raw:{:?}:{:?}: sending", ip_version, ip_protocol);
                    emit(cx, (IpRepr::Ipv4(ipv4_repr), packet.payload()))
                }
                #[cfg(feature = "proto-ipv6")]
                Ok(IpVersion::Ipv6) => {
                    let packet = match Ipv6Packet::new_checked(buffer) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!("raw: malformed ipv6 packet in queue, dropping.");
                            return Ok(());
                        }
                    };
                    if ip_protocol.is_some_and(|next_header| next_header != packet.next_header()) {
                        net_trace!("raw: sent ipv6 packet with wrong ip protocol, dropping.");
                        return Ok(());
                    }
                    let packet = Ipv6Packet::new_unchecked(&*packet.into_inner());
                    let ipv6_repr = match Ipv6Repr::parse(&packet) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!("raw: malformed ipv6 packet in queue, dropping.");
                            return Ok(());
                        }
                    };

                    net_trace!("raw:{:?}:{:?}: sending", ip_version, ip_protocol);
                    emit(cx, (IpRepr::Ipv6(ipv6_repr), packet.payload()))
                }
                Err(_) => {
                    net_trace!("raw: sent packet with invalid IP version, dropping.");
                    Ok(())
                }
            }
        });
        match res {
            Err(Empty) => Ok(()),
            Ok(Err(e)) => Err(e),
            Ok(Ok(())) => {
                #[cfg(feature = "async")]
                self.tx_waker.wake();
                Ok(())
            }
        }
    }

    pub(crate) fn poll_at(&self, _cx: &mut Context) -> PollAt {
        if self.tx_buffer.is_empty() {
            PollAt::Ingress
        } else {
            PollAt::Now
        }
    }
}

#[cfg(test)]
mod test {
    use crate::phy::Medium;
    use crate::tests::setup;
    use rstest::*;

    use super::*;
    use crate::wire::IpRepr;
    #[cfg(feature = "proto-ipv4")]
    use crate::wire::{Ipv4Address, Ipv4Repr};
    #[cfg(feature = "proto-ipv6")]
    use crate::wire::{Ipv6Address, Ipv6Repr};

    fn buffer(packets: usize) -> PacketBuffer<'static> {
        PacketBuffer::new(vec![PacketMetadata::EMPTY; packets], vec![0; 48 * packets])
    }

    #[cfg(feature = "proto-ipv4")]
    mod ipv4_locals {
        use super::*;

        pub fn socket(
            rx_buffer: PacketBuffer<'static>,
            tx_buffer: PacketBuffer<'static>,
        ) -> Socket<'static> {
            Socket::new(
                Some(IpVersion::Ipv4),
                Some(IpProtocol::Unknown(IP_PROTO)),
                rx_buffer,
                tx_buffer,
            )
        }

        pub const IP_PROTO: u8 = 63;
        pub const HEADER_REPR: IpRepr = IpRepr::Ipv4(Ipv4Repr {
            src_addr: Ipv4Address::new(10, 0, 0, 1),
            dst_addr: Ipv4Address::new(10, 0, 0, 2),
            next_header: IpProtocol::Unknown(IP_PROTO),
            payload_len: 4,
            hop_limit: 64,
        });
        pub const PACKET_BYTES: [u8; 24] = [
            0x45, 0x00, 0x00, 0x18, 0x00, 0x00, 0x40, 0x00, 0x40, 0x3f, 0x00, 0x00, 0x0a, 0x00,
            0x00, 0x01, 0x0a, 0x00, 0x00, 0x02, 0xaa, 0x00, 0x00, 0xff,
        ];
        pub const PACKET_PAYLOAD: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];
    }

    #[cfg(feature = "proto-ipv6")]
    mod ipv6_locals {
        use super::*;

        pub fn socket(
            rx_buffer: PacketBuffer<'static>,
            tx_buffer: PacketBuffer<'static>,
        ) -> Socket<'static> {
            Socket::new(
                Some(IpVersion::Ipv6),
                Some(IpProtocol::Unknown(IP_PROTO)),
                rx_buffer,
                tx_buffer,
            )
        }

        pub const IP_PROTO: u8 = 63;
        pub const HEADER_REPR: IpRepr = IpRepr::Ipv6(Ipv6Repr {
            src_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            dst_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2),
            next_header: IpProtocol::Unknown(IP_PROTO),
            payload_len: 4,
            hop_limit: 64,
        });

        pub const PACKET_BYTES: [u8; 44] = [
            0x60, 0x00, 0x00, 0x00, 0x00, 0x04, 0x3f, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xfe, 0x80, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xaa, 0x00,
            0x00, 0xff,
        ];

        pub const PACKET_PAYLOAD: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];
    }

    macro_rules! reusable_ip_specific_tests {
        ($module:ident, $socket:path, $hdr:path, $packet:path, $payload:path) => {
            mod $module {
                use super::*;

                #[test]
                fn test_send_truncated() {
                    let mut socket = $socket(buffer(0), buffer(1));
                    assert_eq!(socket.send_slice(&[0; 56][..]), Err(SendError::BufferFull));
                }

                #[rstest]
                #[case::ip(Medium::Ip)]
                #[cfg(feature = "medium-ip")]
                #[case::ethernet(Medium::Ethernet)]
                #[cfg(feature = "medium-ethernet")]
                #[case::ieee802154(Medium::Ieee802154)]
                #[cfg(feature = "medium-ieee802154")]
                fn test_send_dispatch(#[case] medium: Medium) {
                    let (mut iface, _, _) = setup(medium);
                    let mut cx = iface.context();
                    let mut socket = $socket(buffer(0), buffer(1));

                    assert!(socket.can_send());
                    assert_eq!(
                        socket.dispatch(&mut cx, |_, _| unreachable!()),
                        Ok::<_, ()>(())
                    );

                    assert_eq!(socket.send_slice(&$packet[..]), Ok(()));
                    assert_eq!(socket.send_slice(b""), Err(SendError::BufferFull));
                    assert!(!socket.can_send());

                    assert_eq!(
                        socket.dispatch(&mut cx, |_, (ip_repr, ip_payload)| {
                            assert_eq!(ip_repr, $hdr);
                            assert_eq!(ip_payload, &$payload);
                            Err(())
                        }),
                        Err(())
                    );
                    assert!(!socket.can_send());

                    assert_eq!(
                        socket.dispatch(&mut cx, |_, (ip_repr, ip_payload)| {
                            assert_eq!(ip_repr, $hdr);
                            assert_eq!(ip_payload, &$payload);
                            Ok::<_, ()>(())
                        }),
                        Ok(())
                    );
                    assert!(socket.can_send());
                }

                #[rstest]
                #[case::ip(Medium::Ip)]
                #[cfg(feature = "medium-ip")]
                #[case::ethernet(Medium::Ethernet)]
                #[cfg(feature = "medium-ethernet")]
                #[case::ieee802154(Medium::Ieee802154)]
                #[cfg(feature = "medium-ieee802154")]
                fn test_recv_truncated_slice(#[case] medium: Medium) {
                    let (mut iface, _, _) = setup(medium);
                    let mut cx = iface.context();
                    let mut socket = $socket(buffer(1), buffer(0));

                    assert!(socket.accepts(&$hdr));
                    socket.process(&mut cx, &$hdr, &$payload);

                    let mut slice = [0; 4];
                    assert_eq!(socket.recv_slice(&mut slice[..]), Err(RecvError::Truncated));
                }

                #[rstest]
                #[case::ip(Medium::Ip)]
                #[cfg(feature = "medium-ip")]
                #[case::ethernet(Medium::Ethernet)]
                #[cfg(feature = "medium-ethernet")]
                #[case::ieee802154(Medium::Ieee802154)]
                #[cfg(feature = "medium-ieee802154")]
                fn test_recv_truncated_packet(#[case] medium: Medium) {
                    let (mut iface, _, _) = setup(medium);
                    let mut cx = iface.context();
                    let mut socket = $socket(buffer(1), buffer(0));

                    let mut buffer = vec![0; 128];
                    buffer[..$packet.len()].copy_from_slice(&$packet[..]);

                    assert!(socket.accepts(&$hdr));
                    socket.process(&mut cx, &$hdr, &buffer);
                }

                #[rstest]
                #[case::ip(Medium::Ip)]
                #[cfg(feature = "medium-ip")]
                #[case::ethernet(Medium::Ethernet)]
                #[cfg(feature = "medium-ethernet")]
                #[case::ieee802154(Medium::Ieee802154)]
                #[cfg(feature = "medium-ieee802154")]
                fn test_peek_truncated_slice(#[case] medium: Medium) {
                    let (mut iface, _, _) = setup(medium);
                    let mut cx = iface.context();
                    let mut socket = $socket(buffer(1), buffer(0));

                    assert!(socket.accepts(&$hdr));
                    socket.process(&mut cx, &$hdr, &$payload);

                    let mut slice = [0; 4];
                    assert_eq!(socket.peek_slice(&mut slice[..]), Err(RecvError::Truncated));
                    assert_eq!(socket.recv_slice(&mut slice[..]), Err(RecvError::Truncated));
                    assert_eq!(socket.peek_slice(&mut slice[..]), Err(RecvError::Exhausted));
                }
            }
        };
    }

    #[cfg(feature = "proto-ipv4")]
    reusable_ip_specific_tests!(
        ipv4,
        ipv4_locals::socket,
        ipv4_locals::HEADER_REPR,
        ipv4_locals::PACKET_BYTES,
        ipv4_locals::PACKET_PAYLOAD
    );

    #[cfg(feature = "proto-ipv6")]
    reusable_ip_specific_tests!(
        ipv6,
        ipv6_locals::socket,
        ipv6_locals::HEADER_REPR,
        ipv6_locals::PACKET_BYTES,
        ipv6_locals::PACKET_PAYLOAD
    );

    #[rstest]
    #[case::ip(Medium::Ip)]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    #[case::ieee802154(Medium::Ieee802154)]
    #[cfg(feature = "medium-ieee802154")]
    fn test_send_illegal(#[case] medium: Medium) {
        #[cfg(feature = "proto-ipv4")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();
            let mut socket = ipv4_locals::socket(buffer(0), buffer(2));

            let mut wrong_version = ipv4_locals::PACKET_BYTES;
            Ipv4Packet::new_unchecked(&mut wrong_version).set_version(6);

            assert_eq!(socket.send_slice(&wrong_version[..]), Ok(()));
            assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));

            let mut wrong_protocol = ipv4_locals::PACKET_BYTES;
            Ipv4Packet::new_unchecked(&mut wrong_protocol).set_next_header(IpProtocol::Tcp);

            assert_eq!(socket.send_slice(&wrong_protocol[..]), Ok(()));
            assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));
        }
        #[cfg(feature = "proto-ipv6")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();
            let mut socket = ipv6_locals::socket(buffer(0), buffer(2));

            let mut wrong_version = ipv6_locals::PACKET_BYTES;
            Ipv6Packet::new_unchecked(&mut wrong_version[..]).set_version(4);

            assert_eq!(socket.send_slice(&wrong_version[..]), Ok(()));
            assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));

            let mut wrong_protocol = ipv6_locals::PACKET_BYTES;
            Ipv6Packet::new_unchecked(&mut wrong_protocol[..]).set_next_header(IpProtocol::Tcp);

            assert_eq!(socket.send_slice(&wrong_protocol[..]), Ok(()));
            assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));
        }
    }

    #[rstest]
    #[case::ip(Medium::Ip)]
    #[cfg(feature = "medium-ip")]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    #[case::ieee802154(Medium::Ieee802154)]
    #[cfg(feature = "medium-ieee802154")]
    fn test_recv_process(#[case] medium: Medium) {
        #[cfg(feature = "proto-ipv4")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();
            let mut socket = ipv4_locals::socket(buffer(1), buffer(0));
            assert!(!socket.can_recv());

            let mut cksumd_packet = ipv4_locals::PACKET_BYTES;
            Ipv4Packet::new_unchecked(&mut cksumd_packet).fill_checksum();

            assert_eq!(socket.recv(), Err(RecvError::Exhausted));
            assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
            socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);
            assert!(socket.can_recv());

            assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
            socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);
            assert_eq!(socket.recv(), Ok(&cksumd_packet[..]));
            assert!(!socket.can_recv());
        }
        #[cfg(feature = "proto-ipv6")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();
            let mut socket = ipv6_locals::socket(buffer(1), buffer(0));
            assert!(!socket.can_recv());

            assert_eq!(socket.recv(), Err(RecvError::Exhausted));
            assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
            socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);
            assert!(socket.can_recv());

            assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
            socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);
            assert_eq!(socket.recv(), Ok(&ipv6_locals::PACKET_BYTES[..]));
            assert!(!socket.can_recv());
        }
    }

    #[rstest]
    #[case::ip(Medium::Ip)]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    #[case::ieee802154(Medium::Ieee802154)]
    #[cfg(feature = "medium-ieee802154")]
    fn test_peek_process(#[case] medium: Medium) {
        #[cfg(feature = "proto-ipv4")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();
            let mut socket = ipv4_locals::socket(buffer(1), buffer(0));

            let mut cksumd_packet = ipv4_locals::PACKET_BYTES;
            Ipv4Packet::new_unchecked(&mut cksumd_packet).fill_checksum();

            assert_eq!(socket.peek(), Err(RecvError::Exhausted));
            assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
            socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);

            assert!(socket.accepts(&ipv4_locals::HEADER_REPR));
            socket.process(cx, &ipv4_locals::HEADER_REPR, &ipv4_locals::PACKET_PAYLOAD);
            assert_eq!(socket.peek(), Ok(&cksumd_packet[..]));
            assert_eq!(socket.recv(), Ok(&cksumd_packet[..]));
            assert_eq!(socket.peek(), Err(RecvError::Exhausted));
        }
        #[cfg(feature = "proto-ipv6")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();
            let mut socket = ipv6_locals::socket(buffer(1), buffer(0));

            assert_eq!(socket.peek(), Err(RecvError::Exhausted));
            assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
            socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);

            assert!(socket.accepts(&ipv6_locals::HEADER_REPR));
            socket.process(cx, &ipv6_locals::HEADER_REPR, &ipv6_locals::PACKET_PAYLOAD);
            assert_eq!(socket.peek(), Ok(&ipv6_locals::PACKET_BYTES[..]));
            assert_eq!(socket.recv(), Ok(&ipv6_locals::PACKET_BYTES[..]));
            assert_eq!(socket.peek(), Err(RecvError::Exhausted));
        }
    }

    #[test]
    fn test_doesnt_accept_wrong_proto() {
        #[cfg(feature = "proto-ipv4")]
        {
            let socket = Socket::new(
                Some(IpVersion::Ipv4),
                Some(IpProtocol::Unknown(ipv4_locals::IP_PROTO + 1)),
                buffer(1),
                buffer(1),
            );
            assert!(!socket.accepts(&ipv4_locals::HEADER_REPR));
            #[cfg(feature = "proto-ipv6")]
            assert!(!socket.accepts(&ipv6_locals::HEADER_REPR));
        }
        #[cfg(feature = "proto-ipv6")]
        {
            let socket = Socket::new(
                Some(IpVersion::Ipv6),
                Some(IpProtocol::Unknown(ipv6_locals::IP_PROTO + 1)),
                buffer(1),
                buffer(1),
            );
            assert!(!socket.accepts(&ipv6_locals::HEADER_REPR));
            #[cfg(feature = "proto-ipv4")]
            assert!(!socket.accepts(&ipv4_locals::HEADER_REPR));
        }
    }

    fn check_dispatch(socket: &mut Socket<'_>, cx: &mut Context) {
        // Check dispatch returns Ok(()) and calls the emit closure
        let mut emitted = false;
        assert_eq!(
            socket.dispatch(cx, |_, _| {
                emitted = true;
                Ok(())
            }),
            Ok::<_, ()>(())
        );
        assert!(emitted);
    }

    #[rstest]
    #[case::ip(Medium::Ip)]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    #[case::ieee802154(Medium::Ieee802154)]
    #[cfg(feature = "medium-ieee802154")]
    fn test_unfiltered_sends_all(#[case] medium: Medium) {
        // Test a single unfiltered socket can send packets with different IP versions and next
        // headers
        let mut socket = Socket::new(None, None, buffer(0), buffer(2));
        #[cfg(feature = "proto-ipv4")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();

            let mut udp_packet = ipv4_locals::PACKET_BYTES;
            Ipv4Packet::new_unchecked(&mut udp_packet).set_next_header(IpProtocol::Udp);

            assert_eq!(socket.send_slice(&udp_packet), Ok(()));
            check_dispatch(&mut socket, cx);

            let mut tcp_packet = ipv4_locals::PACKET_BYTES;
            Ipv4Packet::new_unchecked(&mut tcp_packet).set_next_header(IpProtocol::Tcp);

            assert_eq!(socket.send_slice(&tcp_packet[..]), Ok(()));
            check_dispatch(&mut socket, cx);
        }
        #[cfg(feature = "proto-ipv6")]
        {
            let (mut iface, _, _) = setup(medium);
            let cx = iface.context();

            let mut udp_packet = ipv6_locals::PACKET_BYTES;
            Ipv6Packet::new_unchecked(&mut udp_packet).set_next_header(IpProtocol::Udp);

            assert_eq!(socket.send_slice(&ipv6_locals::PACKET_BYTES), Ok(()));
            check_dispatch(&mut socket, cx);

            let mut tcp_packet = ipv6_locals::PACKET_BYTES;
            Ipv6Packet::new_unchecked(&mut tcp_packet).set_next_header(IpProtocol::Tcp);

            assert_eq!(socket.send_slice(&tcp_packet[..]), Ok(()));
            check_dispatch(&mut socket, cx);
        }
    }

    #[rstest]
    #[case::proto(IpProtocol::Icmp)]
    #[case::proto(IpProtocol::Tcp)]
    #[case::proto(IpProtocol::Udp)]
    fn test_unfiltered_accepts_all(#[case] proto: IpProtocol) {
        // Test an unfiltered socket can accept packets with different IP versions and next headers
        let socket = Socket::new(None, None, buffer(0), buffer(0));
        #[cfg(feature = "proto-ipv4")]
        {
            let header_repr = IpRepr::Ipv4(Ipv4Repr {
                src_addr: Ipv4Address::new(10, 0, 0, 1),
                dst_addr: Ipv4Address::new(10, 0, 0, 2),
                next_header: proto,
                payload_len: 4,
                hop_limit: 64,
            });
            assert!(socket.accepts(&header_repr));
        }
        #[cfg(feature = "proto-ipv6")]
        {
            let header_repr = IpRepr::Ipv6(Ipv6Repr {
                src_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                dst_addr: Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2),
                next_header: proto,
                payload_len: 4,
                hop_limit: 64,
            });
            assert!(socket.accepts(&header_repr));
        }
    }
}
