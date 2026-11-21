#![cfg_attr(not(any(test, feature = "std")), no_std)]
#![deny(unsafe_code)]
// Since we have many different flags that can come on and off, we expect some variables to
// be unused sometimes, and we allow that.
#![cfg_attr(not(ci_forbid_unused), allow(unused, irrefutable_let_patterns))]

//! The _smoltcp_ library is built in a layered structure, with the layers corresponding
//! to the levels of API abstraction. Only the highest layers would be used by a typical
//! application; however, the goal of _smoltcp_ is not just to provide a simple interface
//! for writing applications but also to be a toolbox of networking primitives, so
//! every layer is fully exposed and documented.
//!
//! When discussing networking stacks and layering, often the [OSI model][osi] is invoked.
//! _smoltcp_ makes no effort to conform to the OSI model as it is not applicable to TCP/IP.
//!
//! # The socket layer
//! The socket layer APIs are provided in the module [socket](socket/index.html); currently,
//! raw, ICMP, TCP, and UDP sockets are provided. The socket API provides the usual primitives,
//! but necessarily differs in many from the [Berkeley socket API][berk], as the latter was
//! not designed to be used without heap allocation.
//!
//! The socket layer provides the buffering, packet construction and validation, and (for
//! stateful sockets) the state machines, but it is interface-agnostic. An application must
//! use sockets together with a network interface.
//!
//! # The interface layer
//! The interface layer APIs are provided in the module [iface](iface/index.html); currently,
//! Ethernet interface is provided.
//!
//! The interface layer handles the control messages, physical addressing and neighbor discovery.
//! It routes packets to and from sockets.
//!
//! # The physical layer
//! The physical layer APIs are provided in the module [phy](phy/index.html); currently,
//! raw socket and TAP interface are provided. In addition, two _middleware_ interfaces
//! are provided: the _tracer device_, which prints a human-readable representation of packets,
//! and the _fault injector device_, which randomly introduces errors into the transmitted
//! and received packet sequences.
//!
//! The physical layer handles interaction with a platform-specific network device.
//!
//! # The wire layers
//! Unlike the higher layers, the wire layer APIs will not be used by a typical application.
//! They however are the bedrock of _smoltcp_, and everything else is built on top of them.
//!
//! The wire layer APIs are designed by the principle "make illegal states ir-representable".
//! If a wire layer object can be constructed, then it can also be parsed from or emitted to
//! a lower level.
//!
//! The wire layer APIs also provide _tcpdump_-like pretty printing.
//!
//! ## The representation layer
//! The representation layer APIs are provided in the module [wire].
//!
//! The representation layer exists to reduce the state space of raw packets. Raw packets
//! may be nonsensical in a multitude of ways: invalid checksums, impossible combinations of flags,
//! pointers to fields out of bounds, meaningless options... Representations shed all that,
//! as well as any features not supported by _smoltcp_.
//!
//! ## The packet layer
//! The packet layer APIs are also provided in the module [wire].
//!
//! The packet layer exists to provide a more structured way to work with packets than
//! treating them as sequences of octets. It makes no judgement as to content of the packets,
//! except where necessary to provide safe access to fields, and strives to implement every
//! feature ever defined, to ensure that, when the representation layer is unable to make sense
//! of a packet, it is still logged correctly and in full.
//!
//! # Minimum Supported Rust Version (MSRV)
//!
//! This crate is guaranteed to compile on stable Rust 1.91 and up with any valid set of features.
//! It *might* compile on older versions but that may change in any new patch release.
//!
//! The exception is when using the `defmt` feature, in which case `defmt`'s MSRV applies, which
//! is higher.
//!
//! [wire]: wire/index.html
//! [osi]: https://en.wikipedia.org/wiki/OSI_model
//! [berk]: https://en.wikipedia.org/wiki/Berkeley_sockets

/* XXX compiler bug
#![cfg(not(any(feature = "socket-raw",
               feature = "socket-udp",
               feature = "socket-tcp")))]
compile_error!("at least one socket needs to be enabled"); */

#![allow(clippy::match_like_matches_macro)]
#![allow(clippy::redundant_field_names)]
#![allow(clippy::identity_op)]
#![allow(clippy::option_map_unit_fn)]
#![allow(clippy::unit_arg)]
#![allow(clippy::new_without_default)]

#[cfg(feature = "alloc")]
extern crate alloc;

#[cfg(not(any(
    feature = "proto-ipv4",
    feature = "proto-ipv6",
    feature = "proto-sixlowpan"
)))]
compile_error!(
    "You must enable at least one of the following features: proto-ipv4, proto-ipv6, proto-sixlowpan"
);

#[cfg(all(
    feature = "socket",
    not(any(
        feature = "socket-raw",
        feature = "socket-udp",
        feature = "socket-tcp",
        feature = "socket-icmp",
        feature = "socket-dhcpv4",
        feature = "socket-dns",
    ))
))]
compile_error!(
    "If you enable the socket feature, you must enable at least one of the following features: socket-raw, socket-udp, socket-tcp, socket-icmp, socket-dhcpv4, socket-dns"
);

#[cfg(all(
    feature = "socket",
    not(any(
        feature = "medium-ethernet",
        feature = "medium-ip",
        feature = "medium-ieee802154",
    ))
))]
compile_error!(
    "If you enable the socket feature, you must enable at least one of the following features: medium-ip, medium-ethernet, medium-ieee802154"
);

#[cfg(all(
    feature = "proto-ipv6-slaac",
    not(any(feature = "medium-ethernet", feature = "medium-ieee802154",))
))]
compile_error!(
    "If you enable the `proto-ipv6-slaac` feature, you must enable at least one of the following features: medium-ethernet, medium-ieee802154"
);

#[cfg(all(feature = "defmt", feature = "log"))]
compile_error!("You must enable at most one of the following features: defmt, log");

#[macro_use]
mod macros;
mod parsers;
mod rand;

#[cfg(test)]
pub mod config {
    #![allow(unused)]
    pub const ASSEMBLER_MAX_SEGMENT_COUNT: usize = 4;
    pub const DNS_MAX_NAME_SIZE: usize = 255;
    pub const DNS_MAX_RESULT_COUNT: usize = 1;
    pub const DNS_MAX_SERVER_COUNT: usize = 1;
    pub const FRAGMENTATION_BUFFER_SIZE: usize = 4096;
    pub const IFACE_MAX_ADDR_COUNT: usize = 8;
    pub const IFACE_MAX_MULTICAST_GROUP_COUNT: usize = 4;
    pub const IFACE_MAX_ROUTE_COUNT: usize = 4;
    pub const IFACE_MAX_PREFIX_COUNT: usize = 1;
    pub const IFACE_MAX_SIXLOWPAN_ADDRESS_CONTEXT_COUNT: usize = 4;
    pub const IFACE_NEIGHBOR_CACHE_COUNT: usize = 3;
    pub const REASSEMBLY_BUFFER_COUNT: usize = 4;
    pub const REASSEMBLY_BUFFER_SIZE: usize = 1500;
    pub const RPL_RELATIONS_BUFFER_COUNT: usize = 16;
    pub const RPL_PARENTS_BUFFER_COUNT: usize = 8;
    pub const IPV6_HBH_MAX_OPTIONS: usize = 4;
}

#[cfg(not(test))]
pub mod config {
    #![allow(unused)]
    include!(concat!(env!("OUT_DIR"), "/config.rs"));
}

#[cfg(any(
    feature = "medium-ethernet",
    feature = "medium-ip",
    feature = "medium-ieee802154"
))]
pub mod iface;

pub mod phy;
#[cfg(feature = "socket")]
pub mod socket;
pub mod storage;
pub mod time;
pub mod wire;

#[cfg(all(
    test,
    any(
        feature = "medium-ethernet",
        feature = "medium-ip",
        feature = "medium-ieee802154"
    )
))]
mod tests;
