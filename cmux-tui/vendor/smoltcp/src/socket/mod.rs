/*! Communication between endpoints.

The `socket` module deals with *network endpoints* and *buffering*.
It provides interfaces for accessing buffers of data, and protocol state machines
for filling and emptying these buffers.

The programming interface implemented here differs greatly from the common Berkeley socket
interface. Specifically, in the Berkeley interface the buffering is implicit:
the operating system decides on the good size for a buffer and manages it.
The interface implemented by this module uses explicit buffering: you decide on the good
size for a buffer, allocate it, and let the networking stack use it.
*/

use crate::iface::Context;
use crate::time::Instant;

#[cfg(feature = "socket-dhcpv4")]
pub mod dhcpv4;
#[cfg(feature = "socket-dns")]
pub mod dns;
#[cfg(feature = "socket-icmp")]
pub mod icmp;
#[cfg(feature = "socket-raw")]
pub mod raw;
#[cfg(feature = "socket-tcp")]
pub mod tcp;
#[cfg(feature = "socket-udp")]
pub mod udp;

#[cfg(feature = "async")]
mod waker;

#[cfg(feature = "async")]
pub(crate) use self::waker::WakerRegistration;

/// Gives an indication on the next time the socket should be polled.
#[derive(Debug, PartialOrd, Ord, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub(crate) enum PollAt {
    /// The socket needs to be polled immediately.
    Now,
    /// The socket needs to be polled at given [Instant][struct.Instant].
    Time(Instant),
    /// The socket does not need to be polled unless there are external changes.
    Ingress,
}

/// A network socket.
///
/// This enumeration abstracts the various types of sockets based on the IP protocol.
/// To downcast a `Socket` value to a concrete socket, use the [AnySocket] trait,
/// e.g. to get `udp::Socket`, call `udp::Socket::downcast(socket)`.
///
/// It is usually more convenient to use [SocketSet::get] instead.
///
/// [AnySocket]: trait.AnySocket.html
/// [SocketSet::get]: ../iface/struct.SocketSet.html#method.get
#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum Socket<'a> {
    #[cfg(feature = "socket-raw")]
    Raw(raw::Socket<'a>),
    #[cfg(feature = "socket-icmp")]
    Icmp(icmp::Socket<'a>),
    #[cfg(feature = "socket-udp")]
    Udp(udp::Socket<'a>),
    #[cfg(feature = "socket-tcp")]
    Tcp(tcp::Socket<'a>),
    #[cfg(feature = "socket-dhcpv4")]
    Dhcpv4(dhcpv4::Socket<'a>),
    #[cfg(feature = "socket-dns")]
    Dns(dns::Socket<'a>),
}

impl<'a> Socket<'a> {
    pub(crate) fn poll_at(&self, cx: &mut Context) -> PollAt {
        match self {
            #[cfg(feature = "socket-raw")]
            Socket::Raw(s) => s.poll_at(cx),
            #[cfg(feature = "socket-icmp")]
            Socket::Icmp(s) => s.poll_at(cx),
            #[cfg(feature = "socket-udp")]
            Socket::Udp(s) => s.poll_at(cx),
            #[cfg(feature = "socket-tcp")]
            Socket::Tcp(s) => s.poll_at(cx),
            #[cfg(feature = "socket-dhcpv4")]
            Socket::Dhcpv4(s) => s.poll_at(cx),
            #[cfg(feature = "socket-dns")]
            Socket::Dns(s) => s.poll_at(cx),
        }
    }
}

/// A conversion trait for network sockets.
pub trait AnySocket<'a> {
    fn upcast(self) -> Socket<'a>;
    fn downcast<'c>(socket: &'c Socket<'a>) -> Option<&'c Self>
    where
        Self: Sized;
    fn downcast_mut<'c>(socket: &'c mut Socket<'a>) -> Option<&'c mut Self>
    where
        Self: Sized;
}

impl<'a> AnySocket<'a> for Socket<'a> {
    #[inline]
    fn upcast(self) -> Socket<'a> {
        self
    }

    #[inline]
    fn downcast<'c>(socket: &'c Socket<'a>) -> Option<&'c Self>
    where
        Self: Sized,
    {
        Some(socket)
    }

    #[inline]
    fn downcast_mut<'c>(socket: &'c mut Socket<'a>) -> Option<&'c mut Self>
    where
        Self: Sized,
    {
        Some(socket)
    }
}

macro_rules! from_socket {
    ($socket:ty, $variant:ident) => {
        impl<'a> AnySocket<'a> for $socket {
            fn upcast(self) -> Socket<'a> {
                Socket::$variant(self)
            }

            fn downcast<'c>(socket: &'c Socket<'a>) -> Option<&'c Self> {
                #[allow(unreachable_patterns)]
                match socket {
                    Socket::$variant(socket) => Some(socket),
                    _ => None,
                }
            }

            fn downcast_mut<'c>(socket: &'c mut Socket<'a>) -> Option<&'c mut Self> {
                #[allow(unreachable_patterns)]
                match socket {
                    Socket::$variant(socket) => Some(socket),
                    _ => None,
                }
            }
        }
    };
}

#[cfg(feature = "socket-raw")]
from_socket!(raw::Socket<'a>, Raw);
#[cfg(feature = "socket-icmp")]
from_socket!(icmp::Socket<'a>, Icmp);
#[cfg(feature = "socket-udp")]
from_socket!(udp::Socket<'a>, Udp);
#[cfg(feature = "socket-tcp")]
from_socket!(tcp::Socket<'a>, Tcp);
#[cfg(feature = "socket-dhcpv4")]
from_socket!(dhcpv4::Socket<'a>, Dhcpv4);
#[cfg(feature = "socket-dns")]
from_socket!(dns::Socket<'a>, Dns);
