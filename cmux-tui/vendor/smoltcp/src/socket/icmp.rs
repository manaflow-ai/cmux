use core::cmp;
#[cfg(feature = "async")]
use core::task::Waker;

use crate::phy::ChecksumCapabilities;
#[cfg(feature = "async")]
use crate::socket::WakerRegistration;
use crate::socket::{Context, PollAt};

use crate::storage::Empty;
use crate::wire::IcmpRepr;
#[cfg(feature = "proto-ipv4")]
use crate::wire::{Icmpv4Packet, Icmpv4Repr, Ipv4Repr};
#[cfg(feature = "proto-ipv6")]
use crate::wire::{Icmpv6Packet, Icmpv6Repr, Ipv6Repr};
use crate::wire::{IpAddress, IpListenEndpoint, IpProtocol, IpRepr};
use crate::wire::{TcpPacket, TcpRepr};
use crate::wire::{UdpPacket, UdpRepr};

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
    Unaddressable,
    BufferFull,
}

impl core::fmt::Display for SendError {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        match self {
            SendError::Unaddressable => write!(f, "unaddressable"),
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

/// Type of endpoint to bind the ICMP socket to. See [IcmpSocket::bind] for
/// more details.
///
/// [IcmpSocket::bind]: struct.IcmpSocket.html#method.bind
#[derive(Debug, Default, PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum Endpoint {
    #[default]
    Unspecified,
    Ident(u16),
    Tcp(IpListenEndpoint),
    Udp(IpListenEndpoint),
}

impl Endpoint {
    pub fn is_specified(&self) -> bool {
        match *self {
            Endpoint::Unspecified => false,
            Endpoint::Ident(_) => true,
            Endpoint::Tcp(endpoint) => endpoint.port != 0,
            Endpoint::Udp(endpoint) => endpoint.port != 0,
        }
    }
}

/// An ICMP packet metadata.
pub type PacketMetadata = crate::storage::PacketMetadata<IpAddress>;

/// An ICMP packet ring buffer.
pub type PacketBuffer<'a> = crate::storage::PacketBuffer<'a, IpAddress>;

/// A ICMP socket
///
/// An ICMP socket is bound to a specific [IcmpEndpoint] which may
/// be a specific UDP port to listen for ICMP error messages related
/// to the port or a specific ICMP identifier value. See [bind] for
/// more details.
///
/// [IcmpEndpoint]: enum.IcmpEndpoint.html
/// [bind]: #method.bind
#[derive(Debug)]
pub struct Socket<'a> {
    rx_buffer: PacketBuffer<'a>,
    tx_buffer: PacketBuffer<'a>,
    /// The endpoint this socket is communicating with
    endpoint: Endpoint,
    /// The time-to-live (IPv4) or hop limit (IPv6) value used in outgoing packets.
    hop_limit: Option<u8>,
    #[cfg(feature = "async")]
    rx_waker: WakerRegistration,
    #[cfg(feature = "async")]
    tx_waker: WakerRegistration,
}

impl<'a> Socket<'a> {
    /// Create an ICMP socket with the given buffers.
    pub fn new(rx_buffer: PacketBuffer<'a>, tx_buffer: PacketBuffer<'a>) -> Socket<'a> {
        Socket {
            rx_buffer,
            tx_buffer,
            endpoint: Default::default(),
            hop_limit: None,
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

    /// Return the time-to-live (IPv4) or hop limit (IPv6) value used in outgoing packets.
    ///
    /// See also the [set_hop_limit](#method.set_hop_limit) method
    pub fn hop_limit(&self) -> Option<u8> {
        self.hop_limit
    }

    /// Set the time-to-live (IPv4) or hop limit (IPv6) value used in outgoing packets.
    ///
    /// A socket without an explicitly set hop limit value uses the default [IANA recommended]
    /// value (64).
    ///
    /// # Panics
    ///
    /// This function panics if a hop limit value of 0 is given. See [RFC 1122 § 3.2.1.7].
    ///
    /// [IANA recommended]: https://www.iana.org/assignments/ip-parameters/ip-parameters.xhtml
    /// [RFC 1122 § 3.2.1.7]: https://tools.ietf.org/html/rfc1122#section-3.2.1.7
    pub fn set_hop_limit(&mut self, hop_limit: Option<u8>) {
        // A host MUST NOT send a datagram with a hop limit value of 0
        if let Some(0) = hop_limit {
            panic!("the time-to-live value of a packet must not be zero")
        }

        self.hop_limit = hop_limit
    }

    /// Bind the socket to the given endpoint.
    ///
    /// This function returns `Err(Error::Illegal)` if the socket was open
    /// (see [is_open](#method.is_open)), and `Err(Error::Unaddressable)`
    /// if `endpoint` is unspecified (see [is_specified]).
    ///
    /// # Examples
    ///
    /// ## Bind to ICMP Error messages associated with a specific UDP port:
    ///
    /// To [recv] ICMP error messages that are associated with a specific local
    /// UDP port, the socket may be bound to a given port using [IcmpEndpoint::Udp].
    /// This may be useful for applications using UDP attempting to detect and/or
    /// diagnose connection problems.
    ///
    /// ```
    /// use smoltcp::wire::IpListenEndpoint;
    /// use smoltcp::socket::icmp;
    /// # let rx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 20]);
    /// # let tx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 20]);
    ///
    /// let mut icmp_socket = // ...
    /// # icmp::Socket::new(rx_buffer, tx_buffer);
    ///
    /// // Bind to ICMP error responses for UDP packets sent from port 53.
    /// let endpoint = IpListenEndpoint::from(53);
    /// icmp_socket.bind(icmp::Endpoint::Udp(endpoint)).unwrap();
    /// ```
    ///
    /// ## Bind to a specific ICMP identifier:
    ///
    /// To [send] and [recv] ICMP packets that are not associated with a specific UDP
    /// port, the socket may be bound to a specific ICMP identifier using
    /// [IcmpEndpoint::Ident]. This is useful for sending and receiving Echo Request/Reply
    /// messages.
    ///
    /// ```
    /// use smoltcp::wire::IpListenEndpoint;
    /// use smoltcp::socket::icmp;
    /// # let rx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 20]);
    /// # let tx_buffer = icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY], vec![0; 20]);
    ///
    /// let mut icmp_socket = // ...
    /// # icmp::Socket::new(rx_buffer, tx_buffer);
    ///
    /// // Bind to ICMP messages with the ICMP identifier 0x1234
    /// icmp_socket.bind(icmp::Endpoint::Ident(0x1234)).unwrap();
    /// ```
    ///
    /// [is_specified]: enum.IcmpEndpoint.html#method.is_specified
    /// [IcmpEndpoint::Ident]: enum.IcmpEndpoint.html#variant.Ident
    /// [IcmpEndpoint::Udp]: enum.IcmpEndpoint.html#variant.Udp
    /// [send]: #method.send
    /// [recv]: #method.recv
    pub fn bind<T: Into<Endpoint>>(&mut self, endpoint: T) -> Result<(), BindError> {
        let endpoint = endpoint.into();
        if !endpoint.is_specified() {
            return Err(BindError::Unaddressable);
        }

        if self.is_open() {
            return Err(BindError::InvalidState);
        }

        self.endpoint = endpoint;

        #[cfg(feature = "async")]
        {
            self.rx_waker.wake();
            self.tx_waker.wake();
        }

        Ok(())
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

    /// Check whether the socket is open.
    #[inline]
    pub fn is_open(&self) -> bool {
        self.endpoint != Endpoint::Unspecified
    }

    /// Enqueue a packet to be sent to a given remote address, and return a pointer
    /// to its payload.
    ///
    /// This function returns `Err(Error::Exhausted)` if the transmit buffer is full,
    /// `Err(Error::Truncated)` if the requested size is larger than the packet buffer
    /// size, and `Err(Error::Unaddressable)` if the remote address is unspecified.
    pub fn send(&mut self, size: usize, endpoint: IpAddress) -> Result<&mut [u8], SendError> {
        if endpoint.is_unspecified() {
            return Err(SendError::Unaddressable);
        }

        let packet_buf = self
            .tx_buffer
            .enqueue(size, endpoint)
            .map_err(|_| SendError::BufferFull)?;

        net_trace!("icmp:{}: buffer to send {} octets", endpoint, size);
        Ok(packet_buf)
    }

    /// Enqueue a packet to be send to a given remote address and pass the buffer
    /// to the provided closure. The closure then returns the size of the data written
    /// into the buffer.
    ///
    /// Also see [send](#method.send).
    pub fn send_with<F>(
        &mut self,
        max_size: usize,
        endpoint: IpAddress,
        f: F,
    ) -> Result<usize, SendError>
    where
        F: FnOnce(&mut [u8]) -> usize,
    {
        if endpoint.is_unspecified() {
            return Err(SendError::Unaddressable);
        }

        let size = self
            .tx_buffer
            .enqueue_with_infallible(max_size, endpoint, f)
            .map_err(|_| SendError::BufferFull)?;

        net_trace!("icmp:{}: buffer to send {} octets", endpoint, size);
        Ok(size)
    }

    /// Enqueue a packet to be sent to a given remote address, and fill it from a slice.
    ///
    /// See also [send](#method.send).
    pub fn send_slice(&mut self, data: &[u8], endpoint: IpAddress) -> Result<(), SendError> {
        let packet_buf = self.send(data.len(), endpoint)?;
        packet_buf.copy_from_slice(data);
        Ok(())
    }

    /// Dequeue a packet received from a remote endpoint, and return the `IpAddress` as well
    /// as a pointer to the payload.
    ///
    /// This function returns `Err(Error::Exhausted)` if the receive buffer is empty.
    pub fn recv(&mut self) -> Result<(&[u8], IpAddress), RecvError> {
        let (endpoint, packet_buf) = self.rx_buffer.dequeue().map_err(|_| RecvError::Exhausted)?;

        net_trace!(
            "icmp:{}: receive {} buffered octets",
            endpoint,
            packet_buf.len()
        );
        Ok((packet_buf, endpoint))
    }

    /// Dequeue a packet received from a remote endpoint, copy the payload into the given slice,
    /// and return the amount of octets copied as well as the `IpAddress`
    ///
    /// **Note**: when the size of the provided buffer is smaller than the size of the payload,
    /// the packet is dropped and a `RecvError::Truncated` error is returned.
    ///
    /// See also [recv](#method.recv).
    pub fn recv_slice(&mut self, data: &mut [u8]) -> Result<(usize, IpAddress), RecvError> {
        let (buffer, endpoint) = self.recv()?;

        if data.len() < buffer.len() {
            return Err(RecvError::Truncated);
        }

        let length = cmp::min(data.len(), buffer.len());
        data[..length].copy_from_slice(&buffer[..length]);
        Ok((length, endpoint))
    }

    /// Return the amount of octets queued in the transmit buffer.
    pub fn send_queue(&self) -> usize {
        self.tx_buffer.payload_bytes_count()
    }

    /// Return the amount of octets queued in the receive buffer.
    pub fn recv_queue(&self) -> usize {
        self.rx_buffer.payload_bytes_count()
    }

    /// Fitler determining whether the socket accepts a given ICMPv4 packet.
    /// Accepted packets are enqueued into the socket's receive buffer.
    #[cfg(feature = "proto-ipv4")]
    #[inline]
    pub(crate) fn accepts_v4(
        &self,
        cx: &mut Context,
        ip_repr: &Ipv4Repr,
        icmp_repr: &Icmpv4Repr,
    ) -> bool {
        match (&self.endpoint, icmp_repr) {
            // If we are bound to ICMP errors associated to a UDP port, only
            // accept Destination Unreachable or Time Exceeded messages with
            // the data containing a UDP packet send from the local port we
            // are bound to.
            (
                &Endpoint::Udp(endpoint),
                &Icmpv4Repr::DstUnreachable { data, header, .. }
                | &Icmpv4Repr::TimeExceeded { data, header, .. },
            ) if endpoint.addr.is_none() || endpoint.addr == Some(ip_repr.dst_addr.into()) => {
                let packet = UdpPacket::new_unchecked(data);
                match UdpRepr::parse(
                    &packet,
                    &header.src_addr.into(),
                    &header.dst_addr.into(),
                    &cx.checksum_caps(),
                ) {
                    Ok(repr) => endpoint.port == repr.src_port,
                    Err(_) => false,
                }
            }
            // If we are bound to ICMP errors associated to a TCP port, only
            // accept Destination Unreachable or Time Exceeded messages with
            // the data containing a UDP packet send from the local port we
            // are bound to.
            (
                &Endpoint::Tcp(endpoint),
                &Icmpv4Repr::DstUnreachable { data, header, .. }
                | &Icmpv4Repr::TimeExceeded { data, header, .. },
            ) if endpoint.addr.is_none() || endpoint.addr == Some(ip_repr.dst_addr.into()) => {
                let packet = TcpPacket::new_unchecked(data);
                match TcpRepr::parse(
                    &packet,
                    &header.src_addr.into(),
                    &header.dst_addr.into(),
                    &cx.checksum_caps(),
                ) {
                    Ok(repr) => endpoint.port == repr.src_port,
                    Err(_) => false,
                }
            }
            // If we are bound to a specific ICMP identifier value, only accept an
            // Echo Request/Reply with the identifier field matching the endpoint
            // port.
            (&Endpoint::Ident(bound_ident), &Icmpv4Repr::EchoRequest { ident, .. })
            | (&Endpoint::Ident(bound_ident), &Icmpv4Repr::EchoReply { ident, .. }) => {
                ident == bound_ident
            }
            _ => false,
        }
    }

    /// Fitler determining whether the socket accepts a given ICMPv6 packet.
    /// Accepted packets are enqueued into the socket's receive buffer.
    #[cfg(feature = "proto-ipv6")]
    #[inline]
    pub(crate) fn accepts_v6(
        &self,
        cx: &mut Context,
        ip_repr: &Ipv6Repr,
        icmp_repr: &Icmpv6Repr,
    ) -> bool {
        match (&self.endpoint, icmp_repr) {
            // If we are bound to ICMP errors associated to a UDP port, only
            // accept Destination Unreachable or Time Exceeded messages with
            // the data containing a UDP packet send from the local port we
            // are bound to.
            (
                &Endpoint::Udp(endpoint),
                &Icmpv6Repr::DstUnreachable { data, header, .. }
                | &Icmpv6Repr::TimeExceeded { data, header, .. },
            ) if endpoint.addr.is_none() || endpoint.addr == Some(ip_repr.dst_addr.into()) => {
                let packet = UdpPacket::new_unchecked(data);
                match UdpRepr::parse(
                    &packet,
                    &header.src_addr.into(),
                    &header.dst_addr.into(),
                    &cx.checksum_caps(),
                ) {
                    Ok(repr) => endpoint.port == repr.src_port,
                    Err(_) => false,
                }
            }
            // If we are bound to ICMP errors associated to a TCP port, only
            // accept Destination Unreachable or Time Exceeded messages with
            // the data containing a UDP packet send from the local port we
            // are bound to.
            (
                &Endpoint::Tcp(endpoint),
                &Icmpv6Repr::DstUnreachable { data, header, .. }
                | &Icmpv6Repr::TimeExceeded { data, header, .. },
            ) if endpoint.addr.is_none() || endpoint.addr == Some(ip_repr.dst_addr.into()) => {
                let packet = TcpPacket::new_unchecked(data);
                match TcpRepr::parse(
                    &packet,
                    &header.src_addr.into(),
                    &header.dst_addr.into(),
                    &cx.checksum_caps(),
                ) {
                    Ok(repr) => endpoint.port == repr.src_port,
                    Err(_) => false,
                }
            }
            // If we are bound to a specific ICMP identifier value, only accept an
            // Echo Request/Reply with the identifier field matching the endpoint
            // port.
            (
                &Endpoint::Ident(bound_ident),
                &Icmpv6Repr::EchoRequest { ident, .. } | &Icmpv6Repr::EchoReply { ident, .. },
            ) => ident == bound_ident,
            _ => false,
        }
    }

    #[cfg(feature = "proto-ipv4")]
    pub(crate) fn process_v4(
        &mut self,
        _cx: &mut Context,
        ip_repr: &Ipv4Repr,
        icmp_repr: &Icmpv4Repr,
    ) {
        net_trace!("icmp: receiving {} octets", icmp_repr.buffer_len());

        match self
            .rx_buffer
            .enqueue(icmp_repr.buffer_len(), ip_repr.src_addr.into())
        {
            Ok(packet_buf) => {
                icmp_repr.emit(
                    &mut Icmpv4Packet::new_unchecked(packet_buf),
                    &ChecksumCapabilities::default(),
                );
            }
            Err(_) => net_trace!("icmp: buffer full, dropped incoming packet"),
        }

        #[cfg(feature = "async")]
        self.rx_waker.wake();
    }

    #[cfg(feature = "proto-ipv6")]
    pub(crate) fn process_v6(
        &mut self,
        _cx: &mut Context,
        ip_repr: &Ipv6Repr,
        icmp_repr: &Icmpv6Repr,
    ) {
        net_trace!("icmp: receiving {} octets", icmp_repr.buffer_len());

        match self
            .rx_buffer
            .enqueue(icmp_repr.buffer_len(), ip_repr.src_addr.into())
        {
            Ok(packet_buf) => icmp_repr.emit(
                &ip_repr.src_addr,
                &ip_repr.dst_addr,
                &mut Icmpv6Packet::new_unchecked(packet_buf),
                &ChecksumCapabilities::default(),
            ),
            Err(_) => net_trace!("icmp: buffer full, dropped incoming packet"),
        }

        #[cfg(feature = "async")]
        self.rx_waker.wake();
    }

    pub(crate) fn dispatch<F, E>(&mut self, cx: &mut Context, emit: F) -> Result<(), E>
    where
        F: FnOnce(&mut Context, (IpRepr, IcmpRepr)) -> Result<(), E>,
    {
        let hop_limit = self.hop_limit.unwrap_or(64);
        let res = self.tx_buffer.dequeue_with(|remote_endpoint, packet_buf| {
            net_trace!(
                "icmp:{}: sending {} octets",
                remote_endpoint,
                packet_buf.len()
            );
            match *remote_endpoint {
                #[cfg(feature = "proto-ipv4")]
                IpAddress::Ipv4(dst_addr) => {
                    let src_addr = match cx.get_source_address_ipv4(&dst_addr) {
                        Some(addr) => addr,
                        None => {
                            net_trace!(
                                "icmp:{}: not find suitable source address, dropping",
                                remote_endpoint
                            );
                            return Ok(());
                        }
                    };
                    let packet = Icmpv4Packet::new_unchecked(&*packet_buf);
                    let repr = match Icmpv4Repr::parse(&packet, &ChecksumCapabilities::ignored()) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!(
                                "icmp:{}: malformed packet in queue, dropping",
                                remote_endpoint
                            );
                            return Ok(());
                        }
                    };
                    let ip_repr = IpRepr::Ipv4(Ipv4Repr {
                        src_addr,
                        dst_addr,
                        next_header: IpProtocol::Icmp,
                        payload_len: repr.buffer_len(),
                        hop_limit,
                    });
                    emit(cx, (ip_repr, IcmpRepr::Ipv4(repr)))
                }
                #[cfg(feature = "proto-ipv6")]
                IpAddress::Ipv6(dst_addr) => {
                    let src_addr = cx.get_source_address_ipv6(&dst_addr);

                    let packet = Icmpv6Packet::new_unchecked(&*packet_buf);
                    let repr = match Icmpv6Repr::parse(
                        &src_addr,
                        &dst_addr,
                        &packet,
                        &ChecksumCapabilities::ignored(),
                    ) {
                        Ok(x) => x,
                        Err(_) => {
                            net_trace!(
                                "icmp:{}: malformed packet in queue, dropping",
                                remote_endpoint
                            );
                            return Ok(());
                        }
                    };
                    let ip_repr = IpRepr::Ipv6(Ipv6Repr {
                        src_addr,
                        dst_addr,
                        next_header: IpProtocol::Icmpv6,
                        payload_len: repr.buffer_len(),
                        hop_limit,
                    });
                    emit(cx, (ip_repr, IcmpRepr::Ipv6(repr)))
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
mod tests_common {
    pub use super::*;
    pub use crate::wire::IpAddress;

    pub fn buffer(packets: usize) -> PacketBuffer<'static> {
        PacketBuffer::new(vec![PacketMetadata::EMPTY; packets], vec![0; 66 * packets])
    }

    pub fn socket(
        rx_buffer: PacketBuffer<'static>,
        tx_buffer: PacketBuffer<'static>,
    ) -> Socket<'static> {
        Socket::new(rx_buffer, tx_buffer)
    }

    pub const LOCAL_PORT: u16 = 53;

    pub static UDP_REPR: UdpRepr = UdpRepr {
        src_port: 53,
        dst_port: 9090,
    };

    pub static UDP_PAYLOAD: &[u8] = &[0xff; 10];
}

#[cfg(all(test, feature = "proto-ipv4"))]
mod test_ipv4 {
    use crate::phy::Medium;
    use crate::tests::setup;
    use rstest::*;

    use super::tests_common::*;
    use crate::wire::{Icmpv4DstUnreachable, IpEndpoint, Ipv4Address};

    const REMOTE_IPV4: Ipv4Address = Ipv4Address::new(192, 168, 1, 2);
    const LOCAL_IPV4: Ipv4Address = Ipv4Address::new(192, 168, 1, 1);
    const LOCAL_END_V4: IpEndpoint = IpEndpoint {
        addr: IpAddress::Ipv4(LOCAL_IPV4),
        port: LOCAL_PORT,
    };

    static ECHOV4_REPR: Icmpv4Repr = Icmpv4Repr::EchoRequest {
        ident: 0x1234,
        seq_no: 0x5678,
        data: &[0xff; 16],
    };

    static LOCAL_IPV4_REPR: IpRepr = IpRepr::Ipv4(Ipv4Repr {
        src_addr: LOCAL_IPV4,
        dst_addr: REMOTE_IPV4,
        next_header: IpProtocol::Icmp,
        payload_len: 24,
        hop_limit: 0x40,
    });

    static REMOTE_IPV4_REPR: Ipv4Repr = Ipv4Repr {
        src_addr: REMOTE_IPV4,
        dst_addr: LOCAL_IPV4,
        next_header: IpProtocol::Icmp,
        payload_len: 24,
        hop_limit: 0x40,
    };

    #[test]
    fn test_send_unaddressable() {
        let mut socket = socket(buffer(0), buffer(1));
        assert_eq!(
            socket.send_slice(b"abcdef", IpAddress::Ipv4(Ipv4Address::new(0, 0, 0, 0))),
            Err(SendError::Unaddressable)
        );
        assert_eq!(socket.send_slice(b"abcdef", REMOTE_IPV4.into()), Ok(()));
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_send_dispatch(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(0), buffer(1));
        let checksum = ChecksumCapabilities::default();

        assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));

        // This buffer is too long
        assert_eq!(
            socket.send_slice(&[0xff; 67], REMOTE_IPV4.into()),
            Err(SendError::BufferFull)
        );
        assert!(socket.can_send());

        let mut bytes = [0xff; 24];
        let mut packet = Icmpv4Packet::new_unchecked(&mut bytes);
        ECHOV4_REPR.emit(&mut packet, &checksum);

        assert_eq!(
            socket.send_slice(&*packet.into_inner(), REMOTE_IPV4.into()),
            Ok(())
        );
        assert_eq!(
            socket.send_slice(b"123456", REMOTE_IPV4.into()),
            Err(SendError::BufferFull)
        );
        assert!(!socket.can_send());

        assert_eq!(
            socket.dispatch(cx, |_, (ip_repr, icmp_repr)| {
                assert_eq!(ip_repr, LOCAL_IPV4_REPR);
                assert_eq!(icmp_repr, ECHOV4_REPR.into());
                Err(())
            }),
            Err(())
        );
        // buffer is not taken off of the tx queue due to the error
        assert!(!socket.can_send());

        assert_eq!(
            socket.dispatch(cx, |_, (ip_repr, icmp_repr)| {
                assert_eq!(ip_repr, LOCAL_IPV4_REPR);
                assert_eq!(icmp_repr, ECHOV4_REPR.into());
                Ok::<_, ()>(())
            }),
            Ok(())
        );
        // buffer is taken off of the queue this time
        assert!(socket.can_send());
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_set_hop_limit_v4(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut s = socket(buffer(0), buffer(1));
        let checksum = ChecksumCapabilities::default();

        let mut bytes = [0xff; 24];
        let mut packet = Icmpv4Packet::new_unchecked(&mut bytes);
        ECHOV4_REPR.emit(&mut packet, &checksum);

        s.set_hop_limit(Some(0x2a));

        assert_eq!(
            s.send_slice(&*packet.into_inner(), REMOTE_IPV4.into()),
            Ok(())
        );
        assert_eq!(
            s.dispatch(cx, |_, (ip_repr, _)| {
                assert_eq!(
                    ip_repr,
                    IpRepr::Ipv4(Ipv4Repr {
                        src_addr: LOCAL_IPV4,
                        dst_addr: REMOTE_IPV4,
                        next_header: IpProtocol::Icmp,
                        payload_len: ECHOV4_REPR.buffer_len(),
                        hop_limit: 0x2a,
                    })
                );
                Ok::<_, ()>(())
            }),
            Ok(())
        );
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_recv_process(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Ident(0x1234)), Ok(()));

        assert!(!socket.can_recv());
        assert_eq!(socket.recv(), Err(RecvError::Exhausted));

        let checksum = ChecksumCapabilities::default();

        let mut bytes = [0xff; 24];
        let mut packet = Icmpv4Packet::new_unchecked(&mut bytes[..]);
        ECHOV4_REPR.emit(&mut packet, &checksum);
        let data = &*packet.into_inner();

        assert!(socket.accepts_v4(cx, &REMOTE_IPV4_REPR, &ECHOV4_REPR));
        socket.process_v4(cx, &REMOTE_IPV4_REPR, &ECHOV4_REPR);
        assert!(socket.can_recv());

        assert!(socket.accepts_v4(cx, &REMOTE_IPV4_REPR, &ECHOV4_REPR));
        socket.process_v4(cx, &REMOTE_IPV4_REPR, &ECHOV4_REPR);

        assert_eq!(socket.recv(), Ok((data, REMOTE_IPV4.into())));
        assert!(!socket.can_recv());
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_accept_bad_id(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Ident(0x1234)), Ok(()));

        let checksum = ChecksumCapabilities::default();
        let mut bytes = [0xff; 20];
        let mut packet = Icmpv4Packet::new_unchecked(&mut bytes);
        let icmp_repr = Icmpv4Repr::EchoRequest {
            ident: 0x4321,
            seq_no: 0x5678,
            data: &[0xff; 16],
        };
        icmp_repr.emit(&mut packet, &checksum);

        // Ensure that a packet with an identifier that isn't the bound
        // ID is not accepted
        assert!(!socket.accepts_v4(cx, &REMOTE_IPV4_REPR, &icmp_repr));
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_accepts_udp(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Udp(LOCAL_END_V4.into())), Ok(()));

        let checksum = ChecksumCapabilities::default();

        let mut bytes = [0xff; 18];
        let mut packet = UdpPacket::new_unchecked(&mut bytes);
        UDP_REPR.emit(
            &mut packet,
            &REMOTE_IPV4.into(),
            &LOCAL_IPV4.into(),
            UDP_PAYLOAD.len(),
            |buf| buf.copy_from_slice(UDP_PAYLOAD),
            &checksum,
        );

        let data = &*packet.into_inner();

        let icmp_repr = Icmpv4Repr::DstUnreachable {
            reason: Icmpv4DstUnreachable::PortUnreachable,
            header: Ipv4Repr {
                src_addr: LOCAL_IPV4,
                dst_addr: REMOTE_IPV4,
                next_header: IpProtocol::Icmp,
                payload_len: 12,
                hop_limit: 0x40,
            },
            data,
        };
        let ip_repr = Ipv4Repr {
            src_addr: REMOTE_IPV4,
            dst_addr: LOCAL_IPV4,
            next_header: IpProtocol::Icmp,
            payload_len: icmp_repr.buffer_len(),
            hop_limit: 0x40,
        };

        assert!(!socket.can_recv());

        // Ensure we can accept ICMP error response to the bound
        // UDP port
        assert!(socket.accepts_v4(cx, &ip_repr, &icmp_repr));
        socket.process_v4(cx, &ip_repr, &icmp_repr);
        assert!(socket.can_recv());

        let mut bytes = [0x00; 46];
        let mut packet = Icmpv4Packet::new_unchecked(&mut bytes[..]);
        icmp_repr.emit(&mut packet, &checksum);
        assert_eq!(
            socket.recv(),
            Ok((&*packet.into_inner(), REMOTE_IPV4.into()))
        );
        assert!(!socket.can_recv());
    }
}

#[cfg(all(test, feature = "proto-ipv6"))]
mod test_ipv6 {
    use crate::phy::Medium;
    use crate::tests::setup;
    use rstest::*;

    use super::tests_common::*;

    use crate::wire::{Icmpv6DstUnreachable, IpEndpoint, Ipv6Address};

    const REMOTE_IPV6: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);
    const LOCAL_IPV6: Ipv6Address = Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
    const LOCAL_END_V6: IpEndpoint = IpEndpoint {
        addr: IpAddress::Ipv6(LOCAL_IPV6),
        port: LOCAL_PORT,
    };
    static ECHOV6_REPR: Icmpv6Repr = Icmpv6Repr::EchoRequest {
        ident: 0x1234,
        seq_no: 0x5678,
        data: &[0xff; 16],
    };

    static LOCAL_IPV6_REPR: Ipv6Repr = Ipv6Repr {
        src_addr: LOCAL_IPV6,
        dst_addr: REMOTE_IPV6,
        next_header: IpProtocol::Icmpv6,
        payload_len: 24,
        hop_limit: 0x40,
    };

    static REMOTE_IPV6_REPR: Ipv6Repr = Ipv6Repr {
        src_addr: REMOTE_IPV6,
        dst_addr: LOCAL_IPV6,
        next_header: IpProtocol::Icmpv6,
        payload_len: 24,
        hop_limit: 0x40,
    };

    #[test]
    fn test_send_unaddressable() {
        let mut socket = socket(buffer(0), buffer(1));
        assert_eq!(
            socket.send_slice(b"abcdef", IpAddress::Ipv6(Ipv6Address::UNSPECIFIED)),
            Err(SendError::Unaddressable)
        );
        assert_eq!(socket.send_slice(b"abcdef", REMOTE_IPV6.into()), Ok(()));
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_send_dispatch(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(0), buffer(1));
        let checksum = ChecksumCapabilities::default();

        assert_eq!(socket.dispatch(cx, |_, _| unreachable!()), Ok::<_, ()>(()));

        // This buffer is too long
        assert_eq!(
            socket.send_slice(&[0xff; 67], REMOTE_IPV6.into()),
            Err(SendError::BufferFull)
        );
        assert!(socket.can_send());

        let mut bytes = vec![0xff; 24];
        let mut packet = Icmpv6Packet::new_unchecked(&mut bytes);
        ECHOV6_REPR.emit(&LOCAL_IPV6, &REMOTE_IPV6, &mut packet, &checksum);

        assert_eq!(
            socket.send_slice(&*packet.into_inner(), REMOTE_IPV6.into()),
            Ok(())
        );
        assert_eq!(
            socket.send_slice(b"123456", REMOTE_IPV6.into()),
            Err(SendError::BufferFull)
        );
        assert!(!socket.can_send());

        assert_eq!(
            socket.dispatch(cx, |_, (ip_repr, icmp_repr)| {
                assert_eq!(ip_repr, LOCAL_IPV6_REPR.into());
                assert_eq!(icmp_repr, ECHOV6_REPR.into());
                Err(())
            }),
            Err(())
        );
        // buffer is not taken off of the tx queue due to the error
        assert!(!socket.can_send());

        assert_eq!(
            socket.dispatch(cx, |_, (ip_repr, icmp_repr)| {
                assert_eq!(ip_repr, LOCAL_IPV6_REPR.into());
                assert_eq!(icmp_repr, ECHOV6_REPR.into());
                Ok::<_, ()>(())
            }),
            Ok(())
        );
        // buffer is taken off of the queue this time
        assert!(socket.can_send());
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_set_hop_limit(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut s = socket(buffer(0), buffer(1));
        let checksum = ChecksumCapabilities::default();

        let mut bytes = vec![0xff; 24];
        let mut packet = Icmpv6Packet::new_unchecked(&mut bytes);
        ECHOV6_REPR.emit(&LOCAL_IPV6, &REMOTE_IPV6, &mut packet, &checksum);

        s.set_hop_limit(Some(0x2a));

        assert_eq!(
            s.send_slice(&*packet.into_inner(), REMOTE_IPV6.into()),
            Ok(())
        );
        assert_eq!(
            s.dispatch(cx, |_, (ip_repr, _)| {
                assert_eq!(
                    ip_repr,
                    IpRepr::Ipv6(Ipv6Repr {
                        src_addr: LOCAL_IPV6,
                        dst_addr: REMOTE_IPV6,
                        next_header: IpProtocol::Icmpv6,
                        payload_len: ECHOV6_REPR.buffer_len(),
                        hop_limit: 0x2a,
                    })
                );
                Ok::<_, ()>(())
            }),
            Ok(())
        );
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_recv_process(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Ident(0x1234)), Ok(()));

        assert!(!socket.can_recv());
        assert_eq!(socket.recv(), Err(RecvError::Exhausted));

        let checksum = ChecksumCapabilities::default();

        let mut bytes = [0xff; 24];
        let mut packet = Icmpv6Packet::new_unchecked(&mut bytes[..]);
        ECHOV6_REPR.emit(&LOCAL_IPV6, &REMOTE_IPV6, &mut packet, &checksum);
        let data = &*packet.into_inner();

        assert!(socket.accepts_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR));
        socket.process_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR);
        assert!(socket.can_recv());

        assert!(socket.accepts_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR));
        socket.process_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR);

        assert_eq!(socket.recv(), Ok((data, REMOTE_IPV6.into())));
        assert!(!socket.can_recv());
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_truncated_recv_slice(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Ident(0x1234)), Ok(()));

        let checksum = ChecksumCapabilities::default();

        let mut bytes = [0xff; 24];
        let mut packet = Icmpv6Packet::new_unchecked(&mut bytes[..]);
        ECHOV6_REPR.emit(&LOCAL_IPV6, &REMOTE_IPV6, &mut packet, &checksum);

        assert!(socket.accepts_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR));
        socket.process_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR);
        assert!(socket.can_recv());

        assert!(socket.accepts_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR));
        socket.process_v6(cx, &REMOTE_IPV6_REPR, &ECHOV6_REPR);

        let mut buffer = [0u8; 1];
        assert_eq!(
            socket.recv_slice(&mut buffer[..]),
            Err(RecvError::Truncated)
        );
        assert!(!socket.can_recv());
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_accept_bad_id(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Ident(0x1234)), Ok(()));

        let checksum = ChecksumCapabilities::default();
        let mut bytes = [0xff; 20];
        let mut packet = Icmpv6Packet::new_unchecked(&mut bytes);
        let icmp_repr = Icmpv6Repr::EchoRequest {
            ident: 0x4321,
            seq_no: 0x5678,
            data: &[0xff; 16],
        };
        icmp_repr.emit(&LOCAL_IPV6, &REMOTE_IPV6, &mut packet, &checksum);

        // Ensure that a packet with an identifier that isn't the bound
        // ID is not accepted
        assert!(!socket.accepts_v6(cx, &REMOTE_IPV6_REPR, &icmp_repr));
    }

    #[rstest]
    #[case::ethernet(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_accepts_udp(#[case] medium: Medium) {
        let (mut iface, _, _) = setup(medium);
        let cx = iface.context();

        let mut socket = socket(buffer(1), buffer(1));
        assert_eq!(socket.bind(Endpoint::Udp(LOCAL_END_V6.into())), Ok(()));

        let checksum = ChecksumCapabilities::default();

        let mut bytes = [0xff; 18];
        let mut packet = UdpPacket::new_unchecked(&mut bytes);
        UDP_REPR.emit(
            &mut packet,
            &REMOTE_IPV6.into(),
            &LOCAL_IPV6.into(),
            UDP_PAYLOAD.len(),
            |buf| buf.copy_from_slice(UDP_PAYLOAD),
            &checksum,
        );

        let data = &*packet.into_inner();

        let icmp_repr = Icmpv6Repr::DstUnreachable {
            reason: Icmpv6DstUnreachable::PortUnreachable,
            header: Ipv6Repr {
                src_addr: LOCAL_IPV6,
                dst_addr: REMOTE_IPV6,
                next_header: IpProtocol::Icmpv6,
                payload_len: 12,
                hop_limit: 0x40,
            },
            data,
        };
        let ip_repr = Ipv6Repr {
            src_addr: REMOTE_IPV6,
            dst_addr: LOCAL_IPV6,
            next_header: IpProtocol::Icmpv6,
            payload_len: icmp_repr.buffer_len(),
            hop_limit: 0x40,
        };

        assert!(!socket.can_recv());

        // Ensure we can accept ICMP error response to the bound
        // UDP port
        assert!(socket.accepts_v6(cx, &ip_repr, &icmp_repr));
        socket.process_v6(cx, &ip_repr, &icmp_repr);
        assert!(socket.can_recv());

        let mut bytes = [0x00; 66];
        let mut packet = Icmpv6Packet::new_unchecked(&mut bytes[..]);
        icmp_repr.emit(&LOCAL_IPV6, &REMOTE_IPV6, &mut packet, &checksum);
        assert_eq!(
            socket.recv(),
            Ok((&*packet.into_inner(), REMOTE_IPV6.into()))
        );
        assert!(!socket.can_recv());
    }
}
