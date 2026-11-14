/*! Network interface logic.

The `iface` module deals with the *network interfaces*. It filters incoming frames,
provides lookup and caching of hardware addresses, and handles management packets.
*/

mod fragmentation;
mod interface;
#[cfg(any(feature = "medium-ethernet", feature = "medium-ieee802154"))]
mod neighbor;
mod route;
#[cfg(feature = "proto-rpl")]
mod rpl;
#[cfg(feature = "proto-ipv6-slaac")]
mod slaac;
mod socket_meta;
mod socket_set;

mod packet;

#[cfg(feature = "multicast")]
pub use self::interface::multicast::MulticastError;
pub use self::interface::{
    Config, Interface, InterfaceInner as Context, PollIngressSingleResult, PollResult,
};

pub use self::route::{Route, RouteTableFull, Routes};
#[cfg(feature = "proto-ipv6-slaac")]
pub use self::slaac::Slaac;
pub use self::socket_set::{SocketHandle, SocketSet, SocketStorage};
