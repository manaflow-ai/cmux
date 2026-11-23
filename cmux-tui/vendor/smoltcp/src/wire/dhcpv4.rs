// See https://tools.ietf.org/html/rfc2131 for the DHCP specification.

use bitflags::bitflags;
use byteorder::{ByteOrder, NetworkEndian};
use core::iter;
use heapless::Vec;

use super::{Error, Result};
use crate::wire::arp::Hardware;
use crate::wire::{EthernetAddress, Ipv4Address};

pub const SERVER_PORT: u16 = 67;
pub const CLIENT_PORT: u16 = 68;
pub const MAX_DNS_SERVER_COUNT: usize = 3;

const DHCP_MAGIC_NUMBER: u32 = 0x63825363;

enum_with_unknown! {
    /// The possible opcodes of a DHCP packet.
    pub enum OpCode(u8) {
        Request = 1,
        Reply = 2,
    }
}

enum_with_unknown! {
    /// The possible message types of a DHCP packet.
    pub enum MessageType(u8) {
        Discover = 1,
        Offer = 2,
        Request = 3,
        Decline = 4,
        Ack = 5,
        Nak = 6,
        Release = 7,
        Inform = 8,
    }
}

bitflags! {
    pub struct Flags: u16 {
        const BROADCAST = 0b1000_0000_0000_0000;
    }
}

impl MessageType {
    const fn opcode(&self) -> OpCode {
        match *self {
            MessageType::Discover
            | MessageType::Inform
            | MessageType::Request
            | MessageType::Decline
            | MessageType::Release => OpCode::Request,
            MessageType::Offer | MessageType::Ack | MessageType::Nak => OpCode::Reply,
            MessageType::Unknown(_) => OpCode::Unknown(0),
        }
    }
}

/// A buffer for DHCP options.
#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct DhcpOptionWriter<'a> {
    /// The underlying buffer, directly from the DHCP packet representation.
    buffer: &'a mut [u8],
}

impl<'a> DhcpOptionWriter<'a> {
    pub fn new(buffer: &'a mut [u8]) -> Self {
        Self { buffer }
    }

    /// Emit a  [`DhcpOption`] into a [`DhcpOptionWriter`].
    pub fn emit(&mut self, option: DhcpOption<'_>) -> Result<()> {
        if option.data.len() > u8::MAX as _ {
            return Err(Error);
        }

        let total_len = 2 + option.data.len();
        if self.buffer.len() < total_len {
            return Err(Error);
        }

        let (buf, rest) = core::mem::take(&mut self.buffer).split_at_mut(total_len);
        self.buffer = rest;

        buf[0] = option.kind;
        buf[1] = option.data.len() as _;
        buf[2..].copy_from_slice(option.data);

        Ok(())
    }

    pub fn end(&mut self) -> Result<()> {
        if self.buffer.is_empty() {
            return Err(Error);
        }

        self.buffer[0] = field::OPT_END;
        self.buffer = &mut [];
        Ok(())
    }
}

/// A representation of a single DHCP option.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct DhcpOption<'a> {
    pub kind: u8,
    pub data: &'a [u8],
}

/// A read/write wrapper around a Dynamic Host Configuration Protocol packet buffer.
#[derive(Debug, PartialEq, Eq, Copy, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

pub(crate) mod field {
    #![allow(non_snake_case)]
    #![allow(unused)]

    use crate::wire::field::*;

    pub const OP: usize = 0;
    pub const HTYPE: usize = 1;
    pub const HLEN: usize = 2;
    pub const HOPS: usize = 3;
    pub const XID: Field = 4..8;
    pub const SECS: Field = 8..10;
    pub const FLAGS: Field = 10..12;
    pub const CIADDR: Field = 12..16;
    pub const YIADDR: Field = 16..20;
    pub const SIADDR: Field = 20..24;
    pub const GIADDR: Field = 24..28;
    pub const CHADDR: Field = 28..34;
    pub const SNAME: Field = 34..108;
    pub const FILE: Field = 108..236;
    pub const MAGIC_NUMBER: Field = 236..240;
    pub const OPTIONS: Rest = 240..;

    // Vendor Extensions
    pub const OPT_END: u8 = 255;
    pub const OPT_PAD: u8 = 0;
    pub const OPT_SUBNET_MASK: u8 = 1;
    pub const OPT_TIME_OFFSET: u8 = 2;
    pub const OPT_ROUTER: u8 = 3;
    pub const OPT_TIME_SERVER: u8 = 4;
    pub const OPT_NAME_SERVER: u8 = 5;
    pub const OPT_DOMAIN_NAME_SERVER: u8 = 6;
    pub const OPT_LOG_SERVER: u8 = 7;
    pub const OPT_COOKIE_SERVER: u8 = 8;
    pub const OPT_LPR_SERVER: u8 = 9;
    pub const OPT_IMPRESS_SERVER: u8 = 10;
    pub const OPT_RESOURCE_LOCATION_SERVER: u8 = 11;
    pub const OPT_HOST_NAME: u8 = 12;
    pub const OPT_BOOT_FILE_SIZE: u8 = 13;
    pub const OPT_MERIT_DUMP: u8 = 14;
    pub const OPT_DOMAIN_NAME: u8 = 15;
    pub const OPT_SWAP_SERVER: u8 = 16;
    pub const OPT_ROOT_PATH: u8 = 17;
    pub const OPT_EXTENSIONS_PATH: u8 = 18;

    // IP Layer Parameters per Host
    pub const OPT_IP_FORWARDING: u8 = 19;
    pub const OPT_NON_LOCAL_SOURCE_ROUTING: u8 = 20;
    pub const OPT_POLICY_FILTER: u8 = 21;
    pub const OPT_MAX_DATAGRAM_REASSEMBLY_SIZE: u8 = 22;
    pub const OPT_DEFAULT_TTL: u8 = 23;
    pub const OPT_PATH_MTU_AGING_TIMEOUT: u8 = 24;
    pub const OPT_PATH_MTU_PLATEAU_TABLE: u8 = 25;

    // IP Layer Parameters per Interface
    pub const OPT_INTERFACE_MTU: u8 = 26;
    pub const OPT_ALL_SUBNETS_ARE_LOCAL: u8 = 27;
    pub const OPT_BROADCAST_ADDRESS: u8 = 28;
    pub const OPT_PERFORM_MASK_DISCOVERY: u8 = 29;
    pub const OPT_MASK_SUPPLIER: u8 = 30;
    pub const OPT_PERFORM_ROUTER_DISCOVERY: u8 = 31;
    pub const OPT_ROUTER_SOLICITATION_ADDRESS: u8 = 32;
    pub const OPT_STATIC_ROUTE: u8 = 33;

    // Link Layer Parameters per Interface
    pub const OPT_TRAILER_ENCAPSULATION: u8 = 34;
    pub const OPT_ARP_CACHE_TIMEOUT: u8 = 35;
    pub const OPT_ETHERNET_ENCAPSULATION: u8 = 36;

    // TCP Parameters
    pub const OPT_TCP_DEFAULT_TTL: u8 = 37;
    pub const OPT_TCP_KEEPALIVE_INTERVAL: u8 = 38;
    pub const OPT_TCP_KEEPALIVE_GARBAGE: u8 = 39;

    // Application and Service Parameters
    pub const OPT_NIS_DOMAIN: u8 = 40;
    pub const OPT_NIS_SERVERS: u8 = 41;
    pub const OPT_NTP_SERVERS: u8 = 42;
    pub const OPT_VENDOR_SPECIFIC_INFO: u8 = 43;
    pub const OPT_NETBIOS_NAME_SERVER: u8 = 44;
    pub const OPT_NETBIOS_DISTRIBUTION_SERVER: u8 = 45;
    pub const OPT_NETBIOS_NODE_TYPE: u8 = 46;
    pub const OPT_NETBIOS_SCOPE: u8 = 47;
    pub const OPT_X_WINDOW_FONT_SERVER: u8 = 48;
    pub const OPT_X_WINDOW_DISPLAY_MANAGER: u8 = 49;
    pub const OPT_NIS_PLUS_DOMAIN: u8 = 64;
    pub const OPT_NIS_PLUS_SERVERS: u8 = 65;
    pub const OPT_MOBILE_IP_HOME_AGENT: u8 = 68;
    pub const OPT_SMTP_SERVER: u8 = 69;
    pub const OPT_POP3_SERVER: u8 = 70;
    pub const OPT_NNTP_SERVER: u8 = 71;
    pub const OPT_WWW_SERVER: u8 = 72;
    pub const OPT_FINGER_SERVER: u8 = 73;
    pub const OPT_IRC_SERVER: u8 = 74;
    pub const OPT_STREETTALK_SERVER: u8 = 75;
    pub const OPT_STDA_SERVER: u8 = 76;

    // DHCP Extensions
    pub const OPT_REQUESTED_IP: u8 = 50;
    pub const OPT_IP_LEASE_TIME: u8 = 51;
    pub const OPT_OPTION_OVERLOAD: u8 = 52;
    pub const OPT_TFTP_SERVER_NAME: u8 = 66;
    pub const OPT_BOOTFILE_NAME: u8 = 67;
    pub const OPT_DHCP_MESSAGE_TYPE: u8 = 53;
    pub const OPT_SERVER_IDENTIFIER: u8 = 54;
    pub const OPT_PARAMETER_REQUEST_LIST: u8 = 55;
    pub const OPT_MESSAGE: u8 = 56;
    pub const OPT_MAX_DHCP_MESSAGE_SIZE: u8 = 57;
    pub const OPT_RENEWAL_TIME_VALUE: u8 = 58;
    pub const OPT_REBINDING_TIME_VALUE: u8 = 59;
    pub const OPT_VENDOR_CLASS_ID: u8 = 60;
    pub const OPT_CLIENT_ID: u8 = 61;
}

impl<T: AsRef<[u8]>> Packet<T> {
    /// Imbue a raw octet buffer with DHCP packet structure.
    pub const fn new_unchecked(buffer: T) -> Packet<T> {
        Packet { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Packet<T>> {
        let packet = Self::new_unchecked(buffer);
        packet.check_len()?;
        Ok(packet)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error)` if the buffer is too short.
    ///
    /// [set_header_len]: #method.set_header_len
    pub fn check_len(&self) -> Result<()> {
        let len = self.buffer.as_ref().len();
        if len < field::MAGIC_NUMBER.end {
            Err(Error)
        } else {
            Ok(())
        }
    }

    /// Consume the packet, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Returns the operation code of this packet.
    pub fn opcode(&self) -> OpCode {
        let data = self.buffer.as_ref();
        OpCode::from(data[field::OP])
    }

    /// Returns the hardware protocol type (e.g. ethernet).
    pub fn hardware_type(&self) -> Hardware {
        let data = self.buffer.as_ref();
        Hardware::from(u16::from(data[field::HTYPE]))
    }

    /// Returns the length of a hardware address in bytes (e.g. 6 for ethernet).
    pub fn hardware_len(&self) -> u8 {
        self.buffer.as_ref()[field::HLEN]
    }

    /// Returns the transaction ID.
    ///
    /// The transaction ID (called `xid` in the specification) is a random number used to
    /// associate messages and responses between client and server. The number is chosen by
    /// the client.
    pub fn transaction_id(&self) -> u32 {
        let field = &self.buffer.as_ref()[field::XID];
        NetworkEndian::read_u32(field)
    }

    /// Returns the hardware address of the client (called `chaddr` in the specification).
    ///
    /// Only ethernet is supported by `smoltcp`, so this functions returns
    /// an `EthernetAddress`.
    pub fn client_hardware_address(&self) -> EthernetAddress {
        let field = &self.buffer.as_ref()[field::CHADDR];
        EthernetAddress::from_bytes(field)
    }

    /// Returns the value of the `hops` field.
    ///
    /// The `hops` field is set to zero by clients and optionally used by relay agents.
    pub fn hops(&self) -> u8 {
        self.buffer.as_ref()[field::HOPS]
    }

    /// Returns the value of the `secs` field.
    ///
    /// The secs field is filled by clients and describes the number of seconds elapsed
    /// since client began process.
    pub fn secs(&self) -> u16 {
        let field = &self.buffer.as_ref()[field::SECS];
        NetworkEndian::read_u16(field)
    }

    /// Returns the value of the `magic cookie` field in the DHCP options.
    ///
    /// This field should be always be `0x63825363`.
    pub fn magic_number(&self) -> u32 {
        let field = &self.buffer.as_ref()[field::MAGIC_NUMBER];
        NetworkEndian::read_u32(field)
    }

    /// Returns the Ipv4 address of the client, zero if not set.
    ///
    /// This corresponds to the `ciaddr` field in the DHCP specification. According to it,
    /// this field is “only filled in if client is in `BOUND`, `RENEW` or `REBINDING` state
    /// and can respond to ARP requests”.
    pub fn client_ip(&self) -> Ipv4Address {
        let field = &self.buffer.as_ref()[field::CIADDR];
        Ipv4Address::from_octets(field.try_into().unwrap())
    }

    /// Returns the value of the `yiaddr` field, zero if not set.
    pub fn your_ip(&self) -> Ipv4Address {
        let field = &self.buffer.as_ref()[field::YIADDR];
        Ipv4Address::from_octets(field.try_into().unwrap())
    }

    /// Returns the value of the `siaddr` field, zero if not set.
    pub fn server_ip(&self) -> Ipv4Address {
        let field = &self.buffer.as_ref()[field::SIADDR];
        Ipv4Address::from_octets(field.try_into().unwrap())
    }

    /// Returns the value of the `giaddr` field, zero if not set.
    pub fn relay_agent_ip(&self) -> Ipv4Address {
        let field = &self.buffer.as_ref()[field::GIADDR];
        Ipv4Address::from_octets(field.try_into().unwrap())
    }

    pub fn flags(&self) -> Flags {
        let field = &self.buffer.as_ref()[field::FLAGS];
        Flags::from_bits_truncate(NetworkEndian::read_u16(field))
    }

    /// Return an iterator over the options.
    #[inline]
    pub fn options(&self) -> impl Iterator<Item = DhcpOption<'_>> + '_ {
        let mut buf = &self.buffer.as_ref()[field::OPTIONS];
        iter::from_fn(move || {
            loop {
                match buf.first().copied() {
                    // No more options, return.
                    None => return None,
                    Some(field::OPT_END) => return None,

                    // Skip padding.
                    Some(field::OPT_PAD) => buf = &buf[1..],
                    Some(kind) => {
                        if buf.len() < 2 {
                            return None;
                        }

                        let len = buf[1] as usize;

                        if buf.len() < 2 + len {
                            return None;
                        }

                        let opt = DhcpOption {
                            kind,
                            data: &buf[2..2 + len],
                        };

                        buf = &buf[2 + len..];
                        return Some(opt);
                    }
                }
            }
        })
    }

    pub fn get_sname(&self) -> Result<&str> {
        let data = &self.buffer.as_ref()[field::SNAME];
        let len = data.iter().position(|&x| x == 0).ok_or(Error)?;
        if len == 0 {
            return Err(Error);
        }

        let data = core::str::from_utf8(&data[..len]).map_err(|_| Error)?;
        Ok(data)
    }

    pub fn get_boot_file(&self) -> Result<&str> {
        let data = &self.buffer.as_ref()[field::FILE];
        let len = data.iter().position(|&x| x == 0).ok_or(Error)?;
        if len == 0 {
            return Err(Error);
        }
        let data = core::str::from_utf8(&data[..len]).map_err(|_| Error)?;
        Ok(data)
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
    /// Sets the optional `sname` (“server name”) and `file` (“boot file name”) fields to zero.
    ///
    /// The fields are not commonly used, so we set their value always to zero. **This method
    /// must be called when creating a packet, otherwise the emitted values for these fields
    /// are undefined!**
    pub fn set_sname_and_boot_file_to_zero(&mut self) {
        let data = self.buffer.as_mut();
        for byte in &mut data[field::SNAME] {
            *byte = 0;
        }
        for byte in &mut data[field::FILE] {
            *byte = 0;
        }
    }

    /// Sets the `OpCode` for the packet.
    pub fn set_opcode(&mut self, value: OpCode) {
        let data = self.buffer.as_mut();
        data[field::OP] = value.into();
    }

    /// Sets the hardware address type (only ethernet is supported).
    pub fn set_hardware_type(&mut self, value: Hardware) {
        let data = self.buffer.as_mut();
        let number: u16 = value.into();
        assert!(number <= u16::from(u8::MAX)); // TODO: Replace with TryFrom when it's stable
        data[field::HTYPE] = number as u8;
    }

    /// Sets the hardware address length.
    ///
    /// Only ethernet is supported, so this field should be set to the value `6`.
    pub fn set_hardware_len(&mut self, value: u8) {
        self.buffer.as_mut()[field::HLEN] = value;
    }

    /// Sets the transaction ID.
    ///
    /// The transaction ID (called `xid` in the specification) is a random number used to
    /// associate messages and responses between client and server. The number is chosen by
    /// the client.
    pub fn set_transaction_id(&mut self, value: u32) {
        let field = &mut self.buffer.as_mut()[field::XID];
        NetworkEndian::write_u32(field, value)
    }

    /// Sets the ethernet address of the client.
    ///
    /// Sets the `chaddr` field.
    pub fn set_client_hardware_address(&mut self, value: EthernetAddress) {
        let field = &mut self.buffer.as_mut()[field::CHADDR];
        field.copy_from_slice(value.as_bytes());
    }

    /// Sets the hops field.
    ///
    /// The `hops` field is set to zero by clients and optionally used by relay agents.
    pub fn set_hops(&mut self, value: u8) {
        self.buffer.as_mut()[field::HOPS] = value;
    }

    /// Sets the `secs` field.
    ///
    /// The secs field is filled by clients and describes the number of seconds elapsed
    /// since client began process.
    pub fn set_secs(&mut self, value: u16) {
        let field = &mut self.buffer.as_mut()[field::SECS];
        NetworkEndian::write_u16(field, value);
    }

    /// Sets the value of the `magic cookie` field in the DHCP options.
    ///
    /// This field should be always be `0x63825363`.
    pub fn set_magic_number(&mut self, value: u32) {
        let field = &mut self.buffer.as_mut()[field::MAGIC_NUMBER];
        NetworkEndian::write_u32(field, value);
    }

    /// Sets the Ipv4 address of the client.
    ///
    /// This corresponds to the `ciaddr` field in the DHCP specification. According to it,
    /// this field is “only filled in if client is in `BOUND`, `RENEW` or `REBINDING` state
    /// and can respond to ARP requests”.
    pub fn set_client_ip(&mut self, value: Ipv4Address) {
        let field = &mut self.buffer.as_mut()[field::CIADDR];
        field.copy_from_slice(&value.octets());
    }

    /// Sets the value of the `yiaddr` field.
    pub fn set_your_ip(&mut self, value: Ipv4Address) {
        let field = &mut self.buffer.as_mut()[field::YIADDR];
        field.copy_from_slice(&value.octets());
    }

    /// Sets the value of the `siaddr` field.
    pub fn set_server_ip(&mut self, value: Ipv4Address) {
        let field = &mut self.buffer.as_mut()[field::SIADDR];
        field.copy_from_slice(&value.octets());
    }

    /// Sets the value of the `giaddr` field.
    pub fn set_relay_agent_ip(&mut self, value: Ipv4Address) {
        let field = &mut self.buffer.as_mut()[field::GIADDR];
        field.copy_from_slice(&value.octets());
    }

    /// Sets the flags to the specified value.
    pub fn set_flags(&mut self, val: Flags) {
        let field = &mut self.buffer.as_mut()[field::FLAGS];
        NetworkEndian::write_u16(field, val.bits());
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized> Packet<&mut T> {
    /// Return a pointer to the options.
    #[inline]
    pub fn options_mut(&mut self) -> DhcpOptionWriter<'_> {
        DhcpOptionWriter::new(&mut self.buffer.as_mut()[field::OPTIONS])
    }
}

/// A high-level representation of a Dynamic Host Configuration Protocol packet.
///
/// DHCP messages have the following layout (see [RFC 2131](https://tools.ietf.org/html/rfc2131)
/// for details):
///
/// ```no_rust
/// 0                   1                   2                   3
/// 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | message_type  | htype (N/A)   |   hlen (N/A)  |   hops        |
/// +---------------+---------------+---------------+---------------+
/// |                       transaction_id                          |
/// +-------------------------------+-------------------------------+
/// |           secs                |           flags               |
/// +-------------------------------+-------------------------------+
/// |                           client_ip                           |
/// +---------------------------------------------------------------+
/// |                            your_ip                            |
/// +---------------------------------------------------------------+
/// |                           server_ip                           |
/// +---------------------------------------------------------------+
/// |                        relay_agent_ip                         |
/// +---------------------------------------------------------------+
/// |                                                               |
/// |                    client_hardware_address                    |
/// |                                                               |
/// |                                                               |
/// +---------------------------------------------------------------+
/// |                                                               |
/// |                          sname  (N/A)                         |
/// +---------------------------------------------------------------+
/// |                                                               |
/// |                          file    (N/A)                        |
/// +---------------------------------------------------------------+
/// |                                                               |
/// |                          options                              |
/// +---------------------------------------------------------------+
/// ```
///
/// It is assumed that the access layer is Ethernet, so `htype` (the field representing the
/// hardware address type) is always set to `1`, and `hlen` (which represents the hardware address
/// length) is set to `6`.
///
/// The `options` field has a variable length.
#[derive(Debug, PartialEq, Eq, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Repr<'a> {
    /// This field is also known as `op` in the RFC. It indicates the type of DHCP message this
    /// packet represents.
    pub message_type: MessageType,
    /// This field is also known as `xid` in the RFC. It is a random number chosen by the client,
    /// used by the client and server to associate messages and responses between a client and a
    /// server.
    pub transaction_id: u32,
    /// seconds elapsed since client began address acquisition or renewal
    /// process the DHCPREQUEST message MUST use the same value in the DHCP
    /// message header's 'secs' field and be sent to the same IP broadcast
    /// address as the original DHCPDISCOVER message.
    pub secs: u16,
    /// This field is also known as `chaddr` in the RFC and for networks where the access layer is
    /// ethernet, it is the client MAC address.
    pub client_hardware_address: EthernetAddress,
    /// This field is also known as `ciaddr` in the RFC. It is only filled in if client is in
    /// BOUND, RENEW or REBINDING state and can respond to ARP requests.
    pub client_ip: Ipv4Address,
    /// This field is also known as `yiaddr` in the RFC.
    pub your_ip: Ipv4Address,
    /// This field is also known as `siaddr` in the RFC. It may be set by the server in DHCPOFFER
    /// and DHCPACK messages, and represent the address of the next server to use in bootstrap.
    pub server_ip: Ipv4Address,
    /// Default gateway
    pub router: Option<Ipv4Address>,
    /// This field comes from a corresponding DhcpOption.
    pub subnet_mask: Option<Ipv4Address>,
    /// This field is also known as `giaddr` in the RFC. In order to allow DHCP clients on subnets
    /// not directly served by DHCP servers to communicate with DHCP servers, DHCP relay agents can
    /// be installed on these subnets. The DHCP client broadcasts on the local link; the relay
    /// agent receives the broadcast and transmits it to one or more DHCP servers using unicast.
    /// The relay agent stores its own IP address in the `relay_agent_ip` field of the DHCP packet.
    /// The DHCP server uses the `relay_agent_ip` to determine the subnet on which the relay agent
    /// received the broadcast, and allocates an IP address on that subnet. When the DHCP server
    /// replies to the client, it sends the reply to the `relay_agent_ip` address, again using
    /// unicast. The relay agent then retransmits the response on the local network
    pub relay_agent_ip: Ipv4Address,
    /// Broadcast flags. It can be set in DHCPDISCOVER, DHCPINFORM and DHCPREQUEST message if the
    /// client requires the response to be broadcasted.
    pub broadcast: bool,
    /// The "requested IP address" option. It can be used by clients in DHCPREQUEST or DHCPDISCOVER
    /// messages, or by servers in DHCPDECLINE messages.
    pub requested_ip: Option<Ipv4Address>,
    /// The "client identifier" option.
    ///
    /// The 'client identifier' is an opaque key, not to be interpreted by the server; for example,
    /// the 'client identifier' may contain a hardware address, identical to the contents of the
    /// 'chaddr' field, or it may contain another type of identifier, such as a DNS name.  The
    /// 'client identifier' chosen by a DHCP client MUST be unique to that client within the subnet
    /// to which the client is attached. If the client uses a 'client identifier' in one message,
    /// it MUST use that same identifier in all subsequent messages, to ensure that all servers
    /// correctly identify the client.
    pub client_identifier: Option<EthernetAddress>,
    /// The "server identifier" option. It is used both to identify a DHCP server
    /// in a DHCP message and as a destination address from clients to servers.
    pub server_identifier: Option<Ipv4Address>,
    /// The parameter request list informs the server about which configuration parameters
    /// the client is interested in.
    pub parameter_request_list: Option<&'a [u8]>,
    /// DNS servers
    pub dns_servers: Option<Vec<Ipv4Address, MAX_DNS_SERVER_COUNT>>,
    /// The maximum size dhcp packet the interface can receive
    pub max_size: Option<u16>,
    /// The DHCP IP lease duration, specified in seconds.
    pub lease_duration: Option<u32>,
    /// The DHCP IP renew duration (T1 interval), in seconds, if specified in the packet.
    pub renew_duration: Option<u32>,
    /// The DHCP IP rebind duration (T2 interval), in seconds, if specified in the packet.
    pub rebind_duration: Option<u32>,
    /// When returned from [`Repr::parse`], this field will be `None`.
    /// However, when calling [`Repr::emit`], this field should contain only
    /// additional DHCP options not known to smoltcp.
    pub additional_options: &'a [DhcpOption<'a>],
}

impl<'a> Repr<'a> {
    /// Return the length of a packet that will be emitted from this high-level representation.
    pub fn buffer_len(&self) -> usize {
        let mut len = field::OPTIONS.start;
        // message type and end-of-options options
        len += 3 + 1;
        if self.requested_ip.is_some() {
            len += 6;
        }
        if self.client_identifier.is_some() {
            len += 9;
        }
        if self.server_identifier.is_some() {
            len += 6;
        }
        if self.max_size.is_some() {
            len += 4;
        }
        if self.router.is_some() {
            len += 6;
        }
        if self.subnet_mask.is_some() {
            len += 6;
        }
        if self.lease_duration.is_some() {
            len += 6;
        }
        if let Some(dns_servers) = &self.dns_servers {
            len += 2;
            len += dns_servers.iter().count() * core::mem::size_of::<u32>();
        }
        if let Some(list) = self.parameter_request_list {
            len += list.len() + 2;
        }
        for opt in self.additional_options {
            len += 2 + opt.data.len()
        }

        len
    }

    /// Parse a DHCP packet and return a high-level representation.
    pub fn parse<T>(packet: &'a Packet<&'a T>) -> Result<Self>
    where
        T: AsRef<[u8]> + ?Sized,
    {
        packet.check_len()?;
        let transaction_id = packet.transaction_id();
        let client_hardware_address = packet.client_hardware_address();
        let client_ip = packet.client_ip();
        let your_ip = packet.your_ip();
        let server_ip = packet.server_ip();
        let relay_agent_ip = packet.relay_agent_ip();
        let secs = packet.secs();

        // only ethernet is supported right now
        match packet.hardware_type() {
            Hardware::Ethernet => {
                if packet.hardware_len() != 6 {
                    return Err(Error);
                }
            }
            Hardware::Unknown(_) => return Err(Error), // unimplemented
        }

        if packet.magic_number() != DHCP_MAGIC_NUMBER {
            return Err(Error);
        }

        let mut message_type = Err(Error);
        let mut requested_ip = None;
        let mut client_identifier = None;
        let mut server_identifier = None;
        let mut router = None;
        let mut subnet_mask = None;
        let mut parameter_request_list = None;
        let mut dns_servers = None;
        let mut max_size = None;
        let mut lease_duration = None;
        let mut renew_duration = None;
        let mut rebind_duration = None;

        for option in packet.options() {
            let data = option.data;
            match (option.kind, data.len()) {
                (field::OPT_DHCP_MESSAGE_TYPE, 1) => {
                    let value = MessageType::from(data[0]);
                    if value.opcode() == packet.opcode() {
                        message_type = Ok(value);
                    }
                }
                (field::OPT_REQUESTED_IP, 4) => {
                    requested_ip = Some(Ipv4Address::from_octets(data.try_into().unwrap()));
                }
                (field::OPT_CLIENT_ID, 7) => {
                    let hardware_type = Hardware::from(u16::from(data[0]));
                    if hardware_type != Hardware::Ethernet {
                        return Err(Error);
                    }
                    client_identifier = Some(EthernetAddress::from_bytes(&data[1..]));
                }
                (field::OPT_SERVER_IDENTIFIER, 4) => {
                    server_identifier = Some(Ipv4Address::from_octets(data.try_into().unwrap()));
                }
                (field::OPT_ROUTER, 4) => {
                    router = Some(Ipv4Address::from_octets(data.try_into().unwrap()));
                }
                (field::OPT_SUBNET_MASK, 4) => {
                    subnet_mask = Some(Ipv4Address::from_octets(data.try_into().unwrap()));
                }
                (field::OPT_MAX_DHCP_MESSAGE_SIZE, 2) => {
                    max_size = Some(u16::from_be_bytes([data[0], data[1]]));
                }
                (field::OPT_RENEWAL_TIME_VALUE, 4) => {
                    renew_duration = Some(u32::from_be_bytes([data[0], data[1], data[2], data[3]]))
                }
                (field::OPT_REBINDING_TIME_VALUE, 4) => {
                    rebind_duration = Some(u32::from_be_bytes([data[0], data[1], data[2], data[3]]))
                }
                (field::OPT_IP_LEASE_TIME, 4) => {
                    lease_duration = Some(u32::from_be_bytes([data[0], data[1], data[2], data[3]]))
                }
                (field::OPT_PARAMETER_REQUEST_LIST, _) => {
                    parameter_request_list = Some(data);
                }
                (field::OPT_DOMAIN_NAME_SERVER, _) => {
                    let mut servers = Vec::new();
                    const IP_ADDR_BYTE_LEN: usize = 4;
                    let mut addrs = data.chunks_exact(IP_ADDR_BYTE_LEN);
                    for chunk in &mut addrs {
                        // We ignore push failures because that will only happen
                        // if we attempt to push more than 4 addresses, and the only
                        // solution to that is to support more addresses.
                        servers
                            .push(Ipv4Address::from_octets(chunk.try_into().unwrap()))
                            .ok();
                    }
                    dns_servers = Some(servers);

                    if !addrs.remainder().is_empty() {
                        net_trace!("DHCP domain name servers contained invalid address");
                    }
                }
                _ => {}
            }
        }

        let broadcast = packet.flags().contains(Flags::BROADCAST);

        Ok(Repr {
            secs,
            transaction_id,
            client_hardware_address,
            client_ip,
            your_ip,
            server_ip,
            relay_agent_ip,
            broadcast,
            requested_ip,
            server_identifier,
            router,
            subnet_mask,
            client_identifier,
            parameter_request_list,
            dns_servers,
            max_size,
            lease_duration,
            renew_duration,
            rebind_duration,
            message_type: message_type?,
            additional_options: &[],
        })
    }

    /// Emit a high-level representation into a Dynamic Host
    /// Configuration Protocol packet.
    pub fn emit<T>(&self, packet: &mut Packet<&mut T>) -> Result<()>
    where
        T: AsRef<[u8]> + AsMut<[u8]> + ?Sized,
    {
        packet.set_sname_and_boot_file_to_zero();
        packet.set_opcode(self.message_type.opcode());
        packet.set_hardware_type(Hardware::Ethernet);
        packet.set_hardware_len(6);
        packet.set_transaction_id(self.transaction_id);
        packet.set_client_hardware_address(self.client_hardware_address);
        packet.set_hops(0);
        packet.set_secs(self.secs);
        packet.set_magic_number(0x63825363);
        packet.set_client_ip(self.client_ip);
        packet.set_your_ip(self.your_ip);
        packet.set_server_ip(self.server_ip);
        packet.set_relay_agent_ip(self.relay_agent_ip);

        let mut flags = Flags::empty();
        if self.broadcast {
            flags |= Flags::BROADCAST;
        }
        packet.set_flags(flags);

        {
            let mut options = packet.options_mut();

            options.emit(DhcpOption {
                kind: field::OPT_DHCP_MESSAGE_TYPE,
                data: &[self.message_type.into()],
            })?;

            if let Some(val) = &self.client_identifier {
                let mut data = [0; 7];
                data[0] = u16::from(Hardware::Ethernet) as u8;
                data[1..].copy_from_slice(val.as_bytes());

                options.emit(DhcpOption {
                    kind: field::OPT_CLIENT_ID,
                    data: &data,
                })?;
            }

            if let Some(val) = &self.server_identifier {
                options.emit(DhcpOption {
                    kind: field::OPT_SERVER_IDENTIFIER,
                    data: &val.octets(),
                })?;
            }

            if let Some(val) = &self.router {
                options.emit(DhcpOption {
                    kind: field::OPT_ROUTER,
                    data: &val.octets(),
                })?;
            }
            if let Some(val) = &self.subnet_mask {
                options.emit(DhcpOption {
                    kind: field::OPT_SUBNET_MASK,
                    data: &val.octets(),
                })?;
            }
            if let Some(val) = &self.requested_ip {
                options.emit(DhcpOption {
                    kind: field::OPT_REQUESTED_IP,
                    data: &val.octets(),
                })?;
            }
            if let Some(val) = &self.max_size {
                options.emit(DhcpOption {
                    kind: field::OPT_MAX_DHCP_MESSAGE_SIZE,
                    data: &val.to_be_bytes(),
                })?;
            }
            if let Some(val) = &self.lease_duration {
                options.emit(DhcpOption {
                    kind: field::OPT_IP_LEASE_TIME,
                    data: &val.to_be_bytes(),
                })?;
            }
            if let Some(val) = &self.parameter_request_list {
                options.emit(DhcpOption {
                    kind: field::OPT_PARAMETER_REQUEST_LIST,
                    data: val,
                })?;
            }

            if let Some(dns_servers) = &self.dns_servers {
                const IP_SIZE: usize = core::mem::size_of::<u32>();
                let mut servers = [0; MAX_DNS_SERVER_COUNT * IP_SIZE];

                let data_len = dns_servers
                    .iter()
                    .enumerate()
                    .inspect(|(i, ip)| {
                        servers[(i * IP_SIZE)..((i + 1) * IP_SIZE)].copy_from_slice(&ip.octets());
                    })
                    .count()
                    * IP_SIZE;
                options.emit(DhcpOption {
                    kind: field::OPT_DOMAIN_NAME_SERVER,
                    data: &servers[..data_len],
                })?;
            }

            for option in self.additional_options {
                options.emit(*option)?;
            }

            options.end()?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::wire::Ipv4Address;

    const MAGIC_COOKIE: u32 = 0x63825363;

    static DISCOVER_BYTES: &[u8] = &[
        0x01, 0x01, 0x06, 0x00, 0x00, 0x00, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b,
        0x82, 0x01, 0xfc, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x82, 0x53, 0x63,
        0x35, 0x01, 0x01, 0x3d, 0x07, 0x01, 0x00, 0x0b, 0x82, 0x01, 0xfc, 0x42, 0x32, 0x04, 0x00,
        0x00, 0x00, 0x00, 0x39, 0x2, 0x5, 0xdc, 0x37, 0x04, 0x01, 0x03, 0x06, 0x2a, 0xff, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    static ACK_DNS_SERVER_BYTES: &[u8] = &[
        0x02, 0x01, 0x06, 0x00, 0xcc, 0x34, 0x75, 0xab, 0x00, 0x00, 0x80, 0x00, 0x0a, 0xff, 0x06,
        0x91, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0xff, 0x06, 0xfe, 0x34, 0x17,
        0xeb, 0xc9, 0xaa, 0x2f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x82, 0x53, 0x63,
        0x35, 0x01, 0x05, 0x36, 0x04, 0xa3, 0x01, 0x4a, 0x16, 0x01, 0x04, 0xff, 0xff, 0xff, 0x00,
        0x2b, 0x05, 0xdc, 0x03, 0x4e, 0x41, 0x50, 0x0f, 0x15, 0x6e, 0x61, 0x74, 0x2e, 0x70, 0x68,
        0x79, 0x73, 0x69, 0x63, 0x73, 0x2e, 0x6f, 0x78, 0x2e, 0x61, 0x63, 0x2e, 0x75, 0x6b, 0x00,
        0x03, 0x04, 0x0a, 0xff, 0x06, 0xfe, 0x06, 0x10, 0xa3, 0x01, 0x4a, 0x06, 0xa3, 0x01, 0x4a,
        0x07, 0xa3, 0x01, 0x4a, 0x03, 0xa3, 0x01, 0x4a, 0x04, 0x2c, 0x10, 0xa3, 0x01, 0x4a, 0x03,
        0xa3, 0x01, 0x4a, 0x04, 0xa3, 0x01, 0x4a, 0x06, 0xa3, 0x01, 0x4a, 0x07, 0x2e, 0x01, 0x08,
        0xff,
    ];

    static ACK_LEASE_TIME_BYTES: &[u8] = &[
        0x02, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x0a, 0x22, 0x10, 0x0b, 0x0a, 0x22, 0x10, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x04, 0x91,
        0x62, 0xd2, 0xa8, 0x6f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x82, 0x53, 0x63,
        0x35, 0x01, 0x05, 0x36, 0x04, 0x0a, 0x22, 0x10, 0x0a, 0x33, 0x04, 0x00, 0x00, 0x02, 0x56,
        0x01, 0x04, 0xff, 0xff, 0xff, 0x00, 0x03, 0x04, 0x0a, 0x22, 0x10, 0x0a, 0xff, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    const IP_NULL: Ipv4Address = Ipv4Address::new(0, 0, 0, 0);
    const CLIENT_MAC: EthernetAddress = EthernetAddress([0x0, 0x0b, 0x82, 0x01, 0xfc, 0x42]);
    const DHCP_SIZE: u16 = 1500;

    #[test]
    fn test_deconstruct_discover() {
        let packet = Packet::new_unchecked(DISCOVER_BYTES);
        assert_eq!(packet.magic_number(), MAGIC_COOKIE);
        assert_eq!(packet.opcode(), OpCode::Request);
        assert_eq!(packet.hardware_type(), Hardware::Ethernet);
        assert_eq!(packet.hardware_len(), 6);
        assert_eq!(packet.hops(), 0);
        assert_eq!(packet.transaction_id(), 0x3d1d);
        assert_eq!(packet.secs(), 0);
        assert_eq!(packet.client_ip(), IP_NULL);
        assert_eq!(packet.your_ip(), IP_NULL);
        assert_eq!(packet.server_ip(), IP_NULL);
        assert_eq!(packet.relay_agent_ip(), IP_NULL);
        assert_eq!(packet.client_hardware_address(), CLIENT_MAC);

        let mut options = packet.options();
        assert_eq!(
            options.next(),
            Some(DhcpOption {
                kind: field::OPT_DHCP_MESSAGE_TYPE,
                data: &[0x01]
            })
        );
        assert_eq!(
            options.next(),
            Some(DhcpOption {
                kind: field::OPT_CLIENT_ID,
                data: &[0x01, 0x00, 0x0b, 0x82, 0x01, 0xfc, 0x42],
            })
        );
        assert_eq!(
            options.next(),
            Some(DhcpOption {
                kind: field::OPT_REQUESTED_IP,
                data: &[0x00, 0x00, 0x00, 0x00],
            })
        );
        assert_eq!(
            options.next(),
            Some(DhcpOption {
                kind: field::OPT_MAX_DHCP_MESSAGE_SIZE,
                data: &DHCP_SIZE.to_be_bytes(),
            })
        );
        assert_eq!(
            options.next(),
            Some(DhcpOption {
                kind: field::OPT_PARAMETER_REQUEST_LIST,
                data: &[1, 3, 6, 42]
            })
        );
        assert_eq!(options.next(), None);
    }

    #[test]
    fn test_construct_discover() {
        let mut bytes = vec![0xa5; 276];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_magic_number(MAGIC_COOKIE);
        packet.set_sname_and_boot_file_to_zero();
        packet.set_opcode(OpCode::Request);
        packet.set_hardware_type(Hardware::Ethernet);
        packet.set_hardware_len(6);
        packet.set_hops(0);
        packet.set_transaction_id(0x3d1d);
        packet.set_secs(0);
        packet.set_flags(Flags::empty());
        packet.set_client_ip(IP_NULL);
        packet.set_your_ip(IP_NULL);
        packet.set_server_ip(IP_NULL);
        packet.set_relay_agent_ip(IP_NULL);
        packet.set_client_hardware_address(CLIENT_MAC);

        let mut options = packet.options_mut();

        options
            .emit(DhcpOption {
                kind: field::OPT_DHCP_MESSAGE_TYPE,
                data: &[0x01],
            })
            .unwrap();
        options
            .emit(DhcpOption {
                kind: field::OPT_CLIENT_ID,
                data: &[0x01, 0x00, 0x0b, 0x82, 0x01, 0xfc, 0x42],
            })
            .unwrap();
        options
            .emit(DhcpOption {
                kind: field::OPT_REQUESTED_IP,
                data: &[0x00, 0x00, 0x00, 0x00],
            })
            .unwrap();
        options
            .emit(DhcpOption {
                kind: field::OPT_MAX_DHCP_MESSAGE_SIZE,
                data: &DHCP_SIZE.to_be_bytes(),
            })
            .unwrap();
        options
            .emit(DhcpOption {
                kind: field::OPT_PARAMETER_REQUEST_LIST,
                data: &[1, 3, 6, 42],
            })
            .unwrap();
        options.end().unwrap();

        let packet = &mut packet.into_inner()[..];
        for byte in &mut packet[269..276] {
            *byte = 0; // padding bytes
        }

        assert_eq!(packet, DISCOVER_BYTES);
    }

    const fn offer_repr() -> Repr<'static> {
        Repr {
            message_type: MessageType::Offer,
            transaction_id: 0x3d1d,
            client_hardware_address: CLIENT_MAC,
            client_ip: IP_NULL,
            your_ip: IP_NULL,
            server_ip: IP_NULL,
            router: Some(IP_NULL),
            subnet_mask: Some(IP_NULL),
            relay_agent_ip: IP_NULL,
            secs: 0,
            broadcast: false,
            requested_ip: None,
            client_identifier: Some(CLIENT_MAC),
            server_identifier: None,
            parameter_request_list: None,
            dns_servers: None,
            max_size: None,
            renew_duration: None,
            rebind_duration: None,
            lease_duration: Some(0xffff_ffff), // Infinite lease
            additional_options: &[],
        }
    }

    const fn discover_repr() -> Repr<'static> {
        Repr {
            message_type: MessageType::Discover,
            transaction_id: 0x3d1d,
            client_hardware_address: CLIENT_MAC,
            client_ip: IP_NULL,
            your_ip: IP_NULL,
            server_ip: IP_NULL,
            router: None,
            subnet_mask: None,
            relay_agent_ip: IP_NULL,
            broadcast: false,
            secs: 0,
            max_size: Some(DHCP_SIZE),
            renew_duration: None,
            rebind_duration: None,
            lease_duration: None,
            requested_ip: Some(IP_NULL),
            client_identifier: Some(CLIENT_MAC),
            server_identifier: None,
            parameter_request_list: Some(&[1, 3, 6, 42]),
            dns_servers: None,
            additional_options: &[],
        }
    }

    #[test]
    fn test_parse_discover() {
        let packet = Packet::new_unchecked(DISCOVER_BYTES);
        let repr = Repr::parse(&packet).unwrap();
        assert_eq!(repr, discover_repr());
    }

    #[test]
    fn test_emit_discover() {
        let repr = discover_repr();
        let mut bytes = vec![0xa5; repr.buffer_len()];
        let mut packet = Packet::new_unchecked(&mut bytes);
        repr.emit(&mut packet).unwrap();
        let packet = &*packet.into_inner();
        let packet_len = packet.len();
        assert_eq!(packet, &DISCOVER_BYTES[..packet_len]);
        for byte in &DISCOVER_BYTES[packet_len..] {
            assert_eq!(*byte, 0); // padding bytes
        }
    }

    #[test]
    fn test_emit_offer() {
        let repr = offer_repr();
        let mut bytes = vec![0xa5; repr.buffer_len()];
        let mut packet = Packet::new_unchecked(&mut bytes);
        repr.emit(&mut packet).unwrap();
    }

    #[test]
    fn test_emit_offer_dns() {
        let repr = {
            let mut repr = offer_repr();
            repr.dns_servers = Some(
                Vec::from_slice(&[
                    Ipv4Address::new(163, 1, 74, 6),
                    Ipv4Address::new(163, 1, 74, 7),
                    Ipv4Address::new(163, 1, 74, 3),
                ])
                .unwrap(),
            );
            repr
        };
        let mut bytes = vec![0xa5; repr.buffer_len()];
        let mut packet = Packet::new_unchecked(&mut bytes);
        repr.emit(&mut packet).unwrap();

        let packet = Packet::new_unchecked(&bytes);
        let repr_parsed = Repr::parse(&packet).unwrap();

        assert_eq!(
            repr_parsed.dns_servers,
            Some(
                Vec::from_slice(&[
                    Ipv4Address::new(163, 1, 74, 6),
                    Ipv4Address::new(163, 1, 74, 7),
                    Ipv4Address::new(163, 1, 74, 3),
                ])
                .unwrap()
            )
        );
    }

    #[test]
    fn test_emit_dhcp_option() {
        static DATA: &[u8] = &[1, 3, 6];
        let dhcp_option = DhcpOption {
            kind: field::OPT_PARAMETER_REQUEST_LIST,
            data: DATA,
        };

        let mut bytes = vec![0xa5; 5];
        let mut writer = DhcpOptionWriter::new(&mut bytes);
        writer.emit(dhcp_option).unwrap();

        assert_eq!(
            &bytes[0..2],
            &[field::OPT_PARAMETER_REQUEST_LIST, DATA.len() as u8]
        );
        assert_eq!(&bytes[2..], DATA);
    }

    #[test]
    fn test_parse_ack_dns_servers() {
        let packet = Packet::new_unchecked(ACK_DNS_SERVER_BYTES);
        let repr = Repr::parse(&packet).unwrap();

        // The packet described by ACK_BYTES advertises 4 DNS servers
        // Here we ensure that we correctly parse the first 3 into our fixed
        // length-3 array (see issue #305)
        assert_eq!(
            repr.dns_servers,
            Some(
                Vec::from_slice(&[
                    Ipv4Address::new(163, 1, 74, 6),
                    Ipv4Address::new(163, 1, 74, 7),
                    Ipv4Address::new(163, 1, 74, 3)
                ])
                .unwrap()
            )
        );
    }

    #[test]
    fn test_parse_ack_lease_duration() {
        let packet = Packet::new_unchecked(ACK_LEASE_TIME_BYTES);
        let repr = Repr::parse(&packet).unwrap();

        // Verify that the lease time in the ACK is properly parsed. The packet contains a lease
        // duration of 598s.
        assert_eq!(repr.lease_duration, Some(598));
    }
}
