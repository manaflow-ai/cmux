#[cfg(feature = "async")]
use core::task::Waker;

use crate::iface::Context;
use crate::time::{Duration, Instant};
use crate::wire::dhcpv4::field as dhcpv4_field;
use crate::wire::{
    DHCP_CLIENT_PORT, DHCP_MAX_DNS_SERVER_COUNT, DHCP_SERVER_PORT, DhcpMessageType, DhcpPacket,
    DhcpRepr, IpAddress, IpProtocol, Ipv4Address, Ipv4AddressExt, Ipv4Cidr, Ipv4Repr,
    UDP_HEADER_LEN, UdpRepr,
};
use crate::wire::{DhcpOption, HardwareAddress};
use heapless::Vec;

#[cfg(feature = "async")]
use super::WakerRegistration;

use super::PollAt;

const DEFAULT_LEASE_DURATION: Duration = Duration::from_secs(120);

const DEFAULT_PARAMETER_REQUEST_LIST: &[u8] = &[
    dhcpv4_field::OPT_SUBNET_MASK,
    dhcpv4_field::OPT_ROUTER,
    dhcpv4_field::OPT_DOMAIN_NAME_SERVER,
];

/// IPv4 configuration data provided by the DHCP server.
#[derive(Debug, Eq, PartialEq, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Config<'a> {
    /// Information on how to reach the DHCP server that responded with DHCP
    /// configuration.
    pub server: ServerInfo,
    /// IP address
    pub address: Ipv4Cidr,
    /// Router address, also known as default gateway. Does not necessarily
    /// match the DHCP server's address.
    pub router: Option<Ipv4Address>,
    /// DNS servers
    pub dns_servers: Vec<Ipv4Address, DHCP_MAX_DNS_SERVER_COUNT>,
    /// Received DHCP packet
    pub packet: Option<DhcpPacket<&'a [u8]>>,
}

/// Information on how to reach a DHCP server.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct ServerInfo {
    /// IP address to use as destination in outgoing packets
    pub address: Ipv4Address,
    /// Server identifier to use in outgoing packets. Usually equal to server_address,
    /// but may differ in some situations (eg DHCP relays)
    pub identifier: Ipv4Address,
}

#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
struct DiscoverState {
    /// When to send next request
    retry_at: Instant,
}

#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
struct RequestState {
    /// When to send next request
    retry_at: Instant,
    /// How many retries have been done
    retry: u16,
    /// Server we're trying to request from
    server: ServerInfo,
    /// IP address that we're trying to request.
    requested_ip: Ipv4Address,
}

#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
struct RenewState {
    /// Active network config
    config: Config<'static>,

    /// Renew timer. When reached, we will start attempting
    /// to renew this lease with the DHCP server.
    ///
    /// Must be less or equal than `rebind_at`.
    renew_at: Instant,

    /// Rebind timer. When reached, we will start broadcasting to renew
    /// this lease with any DHCP server.
    ///
    /// Must be greater than or equal to `renew_at`, and less than or
    /// equal to `expires_at`.
    rebind_at: Instant,

    /// Whether the T2 time has elapsed
    rebinding: bool,

    /// Expiration timer. When reached, this lease is no longer valid, so it must be
    /// thrown away and the ethernet interface deconfigured.
    expires_at: Instant,
}

#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
enum ClientState {
    /// Discovering the DHCP server
    Discovering(DiscoverState),
    /// Requesting an address
    Requesting(RequestState),
    /// Having an address, refresh it periodically.
    Renewing(RenewState),
}

/// Timeout and retry configuration.
#[derive(Debug, PartialEq, Eq, Copy, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
#[non_exhaustive]
pub struct RetryConfig {
    pub discover_timeout: Duration,
    /// The REQUEST timeout doubles every 2 tries.
    pub initial_request_timeout: Duration,
    pub request_retries: u16,
    pub min_renew_timeout: Duration,
    /// An upper bound on how long to wait between retrying a renew or rebind.
    ///
    /// Set this to [`Duration::MAX`] if you don't want to impose an upper bound.
    pub max_renew_timeout: Duration,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            discover_timeout: Duration::from_secs(10),
            initial_request_timeout: Duration::from_secs(5),
            request_retries: 5,
            min_renew_timeout: Duration::from_secs(60),
            max_renew_timeout: Duration::MAX,
        }
    }
}

/// Return value for the `Dhcpv4Socket::poll` function
#[derive(Debug, PartialEq, Eq, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum Event<'a> {
    /// Configuration has been lost (for example, the lease has expired)
    Deconfigured,
    /// Configuration has been newly acquired, or modified.
    Configured(Config<'a>),
}

#[derive(Debug)]
pub struct Socket<'a> {
    /// State of the DHCP client.
    state: ClientState,
    /// Set to true on config/state change, cleared back to false by the `config` function.
    config_changed: bool,
    /// xid of the last sent message.
    transaction_id: u32,

    /// Max lease duration. If set, it sets a maximum cap to the server-provided lease duration.
    /// Useful to react faster to IP configuration changes and to test whether renews work correctly.
    max_lease_duration: Option<Duration>,

    retry_config: RetryConfig,

    /// Ignore NAKs.
    ignore_naks: bool,

    /// Server port config
    pub(crate) server_port: u16,

    /// Client port config
    pub(crate) client_port: u16,

    /// A buffer contains options additional to be added to outgoing DHCP
    /// packets.
    outgoing_options: &'a [DhcpOption<'a>],
    /// A buffer containing all requested parameters.
    parameter_request_list: Option<&'a [u8]>,

    /// Incoming DHCP packets are copied into this buffer, overwriting the previous.
    receive_packet_buffer: Option<&'a mut [u8]>,

    /// Waker registration
    #[cfg(feature = "async")]
    waker: WakerRegistration,
}

/// DHCP client socket.
///
/// The socket acquires an IP address configuration through DHCP autonomously.
/// You must query the configuration with `.poll()` after every call to `Interface::poll()`,
/// and apply the configuration to the `Interface`.
impl<'a> Socket<'a> {
    /// Create a DHCPv4 socket
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        Socket {
            state: ClientState::Discovering(DiscoverState {
                retry_at: Instant::from_millis(0),
            }),
            config_changed: true,
            transaction_id: 1,
            max_lease_duration: None,
            retry_config: RetryConfig::default(),
            ignore_naks: false,
            outgoing_options: &[],
            parameter_request_list: None,
            receive_packet_buffer: None,
            #[cfg(feature = "async")]
            waker: WakerRegistration::new(),
            server_port: DHCP_SERVER_PORT,
            client_port: DHCP_CLIENT_PORT,
        }
    }

    /// Set the retry/timeouts configuration.
    pub fn set_retry_config(&mut self, config: RetryConfig) {
        self.retry_config = config;
    }

    /// Gets the current retry/timeouts configuration
    pub fn get_retry_config(&self) -> RetryConfig {
        self.retry_config
    }

    /// Set the outgoing options.
    pub fn set_outgoing_options(&mut self, options: &'a [DhcpOption<'a>]) {
        self.outgoing_options = options;
    }

    /// Set the buffer into which incoming DHCP packets are copied into.
    pub fn set_receive_packet_buffer(&mut self, buffer: &'a mut [u8]) {
        self.receive_packet_buffer = Some(buffer);
    }

    /// Set the parameter request list.
    ///
    /// This should contain at least `OPT_SUBNET_MASK` (`1`), `OPT_ROUTER`
    /// (`3`), and `OPT_DOMAIN_NAME_SERVER` (`6`).
    pub fn set_parameter_request_list(&mut self, parameter_request_list: &'a [u8]) {
        self.parameter_request_list = Some(parameter_request_list);
    }

    /// Get the configured max lease duration.
    ///
    /// See also [`Self::set_max_lease_duration()`]
    pub fn max_lease_duration(&self) -> Option<Duration> {
        self.max_lease_duration
    }

    /// Set the max lease duration.
    ///
    /// When set, the lease duration will be capped at the configured duration if the
    /// DHCP server gives us a longer lease. This is generally not recommended, but
    /// can be useful for debugging or reacting faster to network configuration changes.
    ///
    /// If None, no max is applied (the lease duration from the DHCP server is used.)
    pub fn set_max_lease_duration(&mut self, max_lease_duration: Option<Duration>) {
        self.max_lease_duration = max_lease_duration;
    }

    /// Get whether to ignore NAKs.
    ///
    /// See also [`Self::set_ignore_naks()`]
    pub fn ignore_naks(&self) -> bool {
        self.ignore_naks
    }

    /// Set whether to ignore NAKs.
    ///
    /// This is not compliant with the DHCP RFCs, since theoretically
    /// we must stop using the assigned IP when receiving a NAK. This
    /// can increase reliability on broken networks with buggy routers
    /// or rogue DHCP servers, however.
    pub fn set_ignore_naks(&mut self, ignore_naks: bool) {
        self.ignore_naks = ignore_naks;
    }

    /// Set the server/client port
    ///
    /// Allows you to specify the ports used by DHCP.
    /// This is meant to support esoteric usecases allowed by the dhclient program.
    pub fn set_ports(&mut self, server_port: u16, client_port: u16) {
        self.server_port = server_port;
        self.client_port = client_port;
    }

    pub(crate) fn poll_at(&self, _cx: &mut Context) -> PollAt {
        let t = match &self.state {
            ClientState::Discovering(state) => state.retry_at,
            ClientState::Requesting(state) => state.retry_at,
            ClientState::Renewing(state) => if state.rebinding {
                state.rebind_at
            } else {
                state.renew_at.min(state.rebind_at)
            }
            .min(state.expires_at),
        };
        PollAt::Time(t)
    }

    pub(crate) fn process(
        &mut self,
        cx: &mut Context,
        ip_repr: &Ipv4Repr,
        repr: &UdpRepr,
        payload: &[u8],
    ) {
        let src_ip = ip_repr.src_addr;

        // This is enforced in interface.rs.
        assert!(repr.src_port == self.server_port && repr.dst_port == self.client_port);

        let dhcp_packet = match DhcpPacket::new_checked(payload) {
            Ok(dhcp_packet) => dhcp_packet,
            Err(e) => {
                net_debug!("DHCP invalid pkt from {}: {:?}", src_ip, e);
                return;
            }
        };
        let dhcp_repr = match DhcpRepr::parse(&dhcp_packet) {
            Ok(dhcp_repr) => dhcp_repr,
            Err(e) => {
                net_debug!("DHCP error parsing pkt from {}: {:?}", src_ip, e);
                return;
            }
        };

        let HardwareAddress::Ethernet(ethernet_addr) = cx.hardware_addr() else {
            panic!("using DHCPv4 socket with a non-ethernet hardware address.");
        };

        if dhcp_repr.client_hardware_address != ethernet_addr {
            return;
        }
        if dhcp_repr.transaction_id != self.transaction_id {
            return;
        }
        let server_identifier = match dhcp_repr.server_identifier {
            Some(server_identifier) => server_identifier,
            None => {
                net_debug!(
                    "DHCP ignoring {:?} because missing server_identifier",
                    dhcp_repr.message_type
                );
                return;
            }
        };

        net_debug!(
            "DHCP recv {:?} from {}: {:?}",
            dhcp_repr.message_type,
            src_ip,
            dhcp_repr
        );

        // Copy over the payload into the receive packet buffer.
        if let Some(buffer) = self.receive_packet_buffer.as_mut()
            && let Some(buffer) = buffer.get_mut(..payload.len())
        {
            buffer.copy_from_slice(payload);
        }

        match (&mut self.state, dhcp_repr.message_type) {
            (ClientState::Discovering(_state), DhcpMessageType::Offer) => {
                if !dhcp_repr.your_ip.x_is_unicast() {
                    net_debug!("DHCP ignoring OFFER because your_ip is not unicast");
                    return;
                }

                self.state = ClientState::Requesting(RequestState {
                    retry_at: cx.now(),
                    retry: 0,
                    server: ServerInfo {
                        address: src_ip,
                        identifier: server_identifier,
                    },
                    requested_ip: dhcp_repr.your_ip, // use the offered ip
                });
            }
            (ClientState::Requesting(state), DhcpMessageType::Ack) => {
                if let Some((config, renew_at, rebind_at, expires_at)) =
                    Self::parse_ack(cx.now(), &dhcp_repr, self.max_lease_duration, state.server)
                {
                    self.state = ClientState::Renewing(RenewState {
                        config,
                        renew_at,
                        rebind_at,
                        expires_at,
                        rebinding: false,
                    });
                    self.config_changed();
                }
            }
            (ClientState::Requesting(_), DhcpMessageType::Nak) => {
                if !self.ignore_naks {
                    self.reset();
                }
            }
            (ClientState::Renewing(state), DhcpMessageType::Ack) => {
                if let Some((config, renew_at, rebind_at, expires_at)) = Self::parse_ack(
                    cx.now(),
                    &dhcp_repr,
                    self.max_lease_duration,
                    state.config.server,
                ) {
                    state.renew_at = renew_at;
                    state.rebind_at = rebind_at;
                    state.rebinding = false;
                    state.expires_at = expires_at;
                    // The `receive_packet_buffer` field isn't populated until
                    // the client asks for the state, but receiving any packet
                    // will change it, so we indicate that the config has
                    // changed every time if the receive packet buffer is set,
                    // but we only write changes to the rest of the config now.
                    let config_changed =
                        state.config != config || self.receive_packet_buffer.is_some();
                    if state.config != config {
                        state.config = config;
                    }
                    if config_changed {
                        self.config_changed();
                    }
                }
            }
            (ClientState::Renewing(_), DhcpMessageType::Nak) => {
                if !self.ignore_naks {
                    self.reset();
                }
            }
            _ => {
                net_debug!(
                    "DHCP ignoring {:?}: unexpected in current state",
                    dhcp_repr.message_type
                );
            }
        }
    }

    fn parse_ack(
        now: Instant,
        dhcp_repr: &DhcpRepr,
        max_lease_duration: Option<Duration>,
        server: ServerInfo,
    ) -> Option<(Config<'static>, Instant, Instant, Instant)> {
        let subnet_mask = match dhcp_repr.subnet_mask {
            Some(subnet_mask) => subnet_mask,
            None => {
                net_debug!("DHCP ignoring ACK because missing subnet_mask");
                return None;
            }
        };

        let prefix_len = match IpAddress::Ipv4(subnet_mask).prefix_len() {
            Some(prefix_len) => prefix_len,
            None => {
                net_debug!("DHCP ignoring ACK because subnet_mask is not a valid mask");
                return None;
            }
        };

        if !dhcp_repr.your_ip.x_is_unicast() {
            net_debug!("DHCP ignoring ACK because your_ip is not unicast");
            return None;
        }

        let mut lease_duration = dhcp_repr
            .lease_duration
            .map(|d| Duration::from_secs(d as _))
            .unwrap_or(DEFAULT_LEASE_DURATION);
        if let Some(max_lease_duration) = max_lease_duration {
            lease_duration = lease_duration.min(max_lease_duration);
        }

        // Cleanup the DNS servers list, keeping only unicasts/
        // TP-Link TD-W8970 sends 0.0.0.0 as second DNS server if there's only one configured :(
        let mut dns_servers = Vec::new();

        dhcp_repr
            .dns_servers
            .iter()
            .flatten()
            .filter(|s| s.x_is_unicast())
            .for_each(|a| {
                // This will never produce an error, as both the arrays and `dns_servers`
                // have length DHCP_MAX_DNS_SERVER_COUNT
                dns_servers.push(*a).ok();
            });

        let config = Config {
            server,
            address: Ipv4Cidr::new(dhcp_repr.your_ip, prefix_len),
            router: dhcp_repr.router,
            dns_servers,
            packet: None,
        };

        // Set renew and rebind times as per RFC 2131:
        // Times T1 and T2 are configurable by the server through
        // options. T1 defaults to (0.5 * duration_of_lease). T2
        // defaults to (0.875 * duration_of_lease).
        // When receiving T1 and T2, they must be in the order:
        // T1 < T2 < lease_duration
        let (renew_duration, rebind_duration) = match (
            dhcp_repr
                .renew_duration
                .map(|d| Duration::from_secs(d as u64)),
            dhcp_repr
                .rebind_duration
                .map(|d| Duration::from_secs(d as u64)),
        ) {
            (Some(renew_duration), Some(rebind_duration))
                if renew_duration < rebind_duration && rebind_duration < lease_duration =>
            {
                (renew_duration, rebind_duration)
            }
            // RFC 2131 does not say what to do if only one value is
            // provided, so:

            // If only T1 is provided, set T2 to be 0.75 through the gap
            // between T1 and the duration of the lease. If T1 is set to
            // the default (0.5 * duration_of_lease), then T2 will also
            // be set to the default (0.875 * duration_of_lease).
            (Some(renew_duration), None) if renew_duration < lease_duration => (
                renew_duration,
                renew_duration + (lease_duration - renew_duration) * 3 / 4,
            ),

            // If only T2 is provided, then T1 will be set to be
            // whichever is smaller of the default (0.5 *
            // duration_of_lease) or T2.
            (None, Some(rebind_duration)) if rebind_duration < lease_duration => {
                ((lease_duration / 2).min(rebind_duration), rebind_duration)
            }

            // Use the defaults if the following order is not met:
            // T1 < T2 < lease_duration
            (_, _) => {
                net_debug!("using default T1 and T2 values since the provided values are invalid");
                (lease_duration / 2, lease_duration * 7 / 8)
            }
        };
        let renew_at = now + renew_duration;
        let rebind_at = now + rebind_duration;
        let expires_at = now + lease_duration;

        Some((config, renew_at, rebind_at, expires_at))
    }

    #[cfg(not(test))]
    fn random_transaction_id(cx: &mut Context) -> u32 {
        cx.rand().rand_u32()
    }

    #[cfg(test)]
    fn random_transaction_id(_cx: &mut Context) -> u32 {
        0x12345678
    }

    pub(crate) fn dispatch<F, E>(&mut self, cx: &mut Context, emit: F) -> Result<(), E>
    where
        F: FnOnce(&mut Context, (Ipv4Repr, UdpRepr, DhcpRepr)) -> Result<(), E>,
    {
        // note: Dhcpv4Socket is only usable in ethernet mediums, so the
        // unwrap can never fail.
        let HardwareAddress::Ethernet(ethernet_addr) = cx.hardware_addr() else {
            panic!("using DHCPv4 socket with a non-ethernet hardware address.");
        };

        // Worst case biggest IPv4 header length.
        // 0x0f * 4 = 60 bytes.
        const MAX_IPV4_HEADER_LEN: usize = 60;

        let mut dhcp_repr = DhcpRepr {
            message_type: DhcpMessageType::Discover,
            transaction_id: self.transaction_id,
            secs: 0,
            client_hardware_address: ethernet_addr,
            client_ip: Ipv4Address::UNSPECIFIED,
            your_ip: Ipv4Address::UNSPECIFIED,
            server_ip: Ipv4Address::UNSPECIFIED,
            router: None,
            subnet_mask: None,
            relay_agent_ip: Ipv4Address::UNSPECIFIED,
            broadcast: false,
            requested_ip: None,
            client_identifier: Some(ethernet_addr),
            server_identifier: None,
            parameter_request_list: Some(
                self.parameter_request_list
                    .unwrap_or(DEFAULT_PARAMETER_REQUEST_LIST),
            ),
            max_size: Some((cx.ip_mtu() - MAX_IPV4_HEADER_LEN - UDP_HEADER_LEN) as u16),
            lease_duration: None,
            renew_duration: None,
            rebind_duration: None,
            dns_servers: None,
            additional_options: self.outgoing_options,
        };

        let udp_repr = UdpRepr {
            src_port: self.client_port,
            dst_port: self.server_port,
        };

        let mut ipv4_repr = Ipv4Repr {
            src_addr: Ipv4Address::UNSPECIFIED,
            dst_addr: Ipv4Address::BROADCAST,
            next_header: IpProtocol::Udp,
            payload_len: 0, // filled right before emit
            hop_limit: 64,
        };

        match &mut self.state {
            ClientState::Discovering(state) => {
                if cx.now() < state.retry_at {
                    return Ok(());
                }

                let next_transaction_id = Self::random_transaction_id(cx);
                dhcp_repr.transaction_id = next_transaction_id;

                // send packet
                net_debug!(
                    "DHCP send DISCOVER to {}: {:?}",
                    ipv4_repr.dst_addr,
                    dhcp_repr
                );
                ipv4_repr.payload_len = udp_repr.header_len() + dhcp_repr.buffer_len();
                emit(cx, (ipv4_repr, udp_repr, dhcp_repr))?;

                // Update state AFTER the packet has been successfully sent.
                state.retry_at = cx.now() + self.retry_config.discover_timeout;
                self.transaction_id = next_transaction_id;
                Ok(())
            }
            ClientState::Requesting(state) => {
                if cx.now() < state.retry_at {
                    return Ok(());
                }

                if state.retry >= self.retry_config.request_retries {
                    net_debug!("DHCP request retries exceeded, restarting discovery");
                    self.reset();
                    return Ok(());
                }

                dhcp_repr.message_type = DhcpMessageType::Request;
                dhcp_repr.requested_ip = Some(state.requested_ip);
                dhcp_repr.server_identifier = Some(state.server.identifier);

                net_debug!(
                    "DHCP send request to {}: {:?}",
                    ipv4_repr.dst_addr,
                    dhcp_repr
                );
                ipv4_repr.payload_len = udp_repr.header_len() + dhcp_repr.buffer_len();
                emit(cx, (ipv4_repr, udp_repr, dhcp_repr))?;

                // Exponential backoff: Double every 2 retries.
                state.retry_at = cx.now()
                    + (self.retry_config.initial_request_timeout << (state.retry as u32 / 2));
                state.retry += 1;

                Ok(())
            }
            ClientState::Renewing(state) => {
                let now = cx.now();
                if state.expires_at <= now {
                    net_debug!("DHCP lease expired");
                    self.reset();
                    // return Ok so we get polled again
                    return Ok(());
                }

                if now < state.renew_at || state.rebinding && now < state.rebind_at {
                    return Ok(());
                }

                state.rebinding |= now >= state.rebind_at;

                ipv4_repr.src_addr = state.config.address.address();
                // Renewing is unicast to the original server, rebinding is broadcast
                if !state.rebinding {
                    ipv4_repr.dst_addr = state.config.server.address;
                }
                dhcp_repr.message_type = DhcpMessageType::Request;
                dhcp_repr.client_ip = state.config.address.address();

                let next_transaction_id = Self::random_transaction_id(cx);
                dhcp_repr.transaction_id = next_transaction_id;

                net_debug!("DHCP send renew to {}: {:?}", ipv4_repr.dst_addr, dhcp_repr);
                ipv4_repr.payload_len = udp_repr.header_len() + dhcp_repr.buffer_len();
                emit(cx, (ipv4_repr, udp_repr, dhcp_repr))?;

                // In both RENEWING and REBINDING states, if the client receives no
                // response to its DHCPREQUEST message, the client SHOULD wait one-half
                // of the remaining time until T2 (in RENEWING state) and one-half of
                // the remaining lease time (in REBINDING state), down to a minimum of
                // 60 seconds, before retransmitting the DHCPREQUEST message.
                if state.rebinding {
                    state.rebind_at = now
                        + self
                            .retry_config
                            .min_renew_timeout
                            .max((state.expires_at - now) / 2)
                            .min(self.retry_config.max_renew_timeout);
                } else {
                    state.renew_at = now
                        + self
                            .retry_config
                            .min_renew_timeout
                            .max((state.rebind_at - now) / 2)
                            .min(state.rebind_at - now)
                            .min(self.retry_config.max_renew_timeout);
                }

                self.transaction_id = next_transaction_id;
                Ok(())
            }
        }
    }

    /// Reset state and restart discovery phase.
    ///
    /// Use this to speed up acquisition of an address in a new
    /// network if a link was down and it is now back up.
    pub fn reset(&mut self) {
        net_trace!("DHCP reset");
        if let ClientState::Renewing(_) = &self.state {
            self.config_changed();
        }
        self.state = ClientState::Discovering(DiscoverState {
            retry_at: Instant::from_millis(0),
        });
    }

    /// Query the socket for configuration changes.
    ///
    /// The socket has an internal "configuration changed" flag. If
    /// set, this function returns the configuration and resets the flag.
    pub fn poll(&mut self) -> Option<Event<'_>> {
        if !self.config_changed {
            None
        } else if let ClientState::Renewing(state) = &self.state {
            self.config_changed = false;
            Some(Event::Configured(Config {
                server: state.config.server,
                address: state.config.address,
                router: state.config.router,
                dns_servers: state.config.dns_servers.clone(),
                packet: self
                    .receive_packet_buffer
                    .as_deref()
                    .map(DhcpPacket::new_unchecked),
            }))
        } else {
            self.config_changed = false;
            Some(Event::Deconfigured)
        }
    }

    /// This function _must_ be called when the configuration provided to the
    /// interface, by this DHCP socket, changes. It will update the `config_changed` field
    /// so that a subsequent call to `poll` will yield an event, and wake a possible waker.
    pub(crate) fn config_changed(&mut self) {
        self.config_changed = true;
        #[cfg(feature = "async")]
        self.waker.wake();
    }

    /// Register a waker.
    ///
    /// The waker is woken on state changes that might affect the return value
    /// of `poll` method calls, which indicates a new state in the DHCP configuration
    /// provided by this DHCP socket.
    ///
    /// Notes:
    ///
    /// - Only one waker can be registered at a time. If another waker was previously registered,
    ///   it is overwritten and will no longer be woken.
    /// - The Waker is woken only once. Once woken, you must register it again to receive more wakes.
    #[cfg(feature = "async")]
    pub fn register_waker(&mut self, waker: &Waker) {
        self.waker.register(waker)
    }
}

#[cfg(test)]
mod test {

    use std::ops::{Deref, DerefMut};

    use super::*;
    use crate::wire::EthernetAddress;

    // =========================================================================================//
    // Helper functions

    struct TestSocket {
        socket: Socket<'static>,
        cx: Context,
    }

    impl Deref for TestSocket {
        type Target = Socket<'static>;
        fn deref(&self) -> &Self::Target {
            &self.socket
        }
    }

    impl DerefMut for TestSocket {
        fn deref_mut(&mut self) -> &mut Self::Target {
            &mut self.socket
        }
    }

    fn send(
        s: &mut TestSocket,
        timestamp: Instant,
        (ip_repr, udp_repr, dhcp_repr): (Ipv4Repr, UdpRepr, DhcpRepr),
    ) {
        s.cx.set_now(timestamp);

        net_trace!("send: {:?}", ip_repr);
        net_trace!("      {:?}", udp_repr);
        net_trace!("      {:?}", dhcp_repr);

        let mut payload = vec![0; dhcp_repr.buffer_len()];
        dhcp_repr
            .emit(&mut DhcpPacket::new_unchecked(&mut payload))
            .unwrap();

        s.socket.process(&mut s.cx, &ip_repr, &udp_repr, &payload)
    }

    fn recv(s: &mut TestSocket, timestamp: Instant, reprs: &[(Ipv4Repr, UdpRepr, DhcpRepr)]) {
        s.cx.set_now(timestamp);

        let mut i = 0;

        while s.socket.poll_at(&mut s.cx) <= PollAt::Time(timestamp) {
            let _ = s
                .socket
                .dispatch(&mut s.cx, |_, (mut ip_repr, udp_repr, dhcp_repr)| {
                    assert_eq!(ip_repr.next_header, IpProtocol::Udp);
                    assert_eq!(
                        ip_repr.payload_len,
                        udp_repr.header_len() + dhcp_repr.buffer_len()
                    );

                    // We validated the payload len, change it to 0 to make equality testing easier
                    ip_repr.payload_len = 0;

                    net_trace!("recv: {:?}", ip_repr);
                    net_trace!("      {:?}", udp_repr);
                    net_trace!("      {:?}", dhcp_repr);

                    let got_repr = (ip_repr, udp_repr, dhcp_repr);
                    match reprs.get(i) {
                        Some(want_repr) => assert_eq!(want_repr, &got_repr),
                        None => panic!("Too many reprs emitted"),
                    }
                    i += 1;
                    Ok::<_, ()>(())
                });
        }

        assert_eq!(i, reprs.len());
    }

    macro_rules! send {
        ($socket:ident, $repr:expr) =>
            (send!($socket, time 0, $repr));
        ($socket:ident, time $time:expr, $repr:expr) =>
            (send(&mut $socket, Instant::from_millis($time), $repr));
    }

    macro_rules! recv {
        ($socket:ident, $reprs:expr) => ({
            recv!($socket, time 0, $reprs);
        });
        ($socket:ident, time $time:expr, $reprs:expr) => ({
            recv(&mut $socket, Instant::from_millis($time), &$reprs);
        });
    }

    // =========================================================================================//
    // Constants

    const TXID: u32 = 0x12345678;

    const MY_IP: Ipv4Address = Ipv4Address::new(192, 168, 1, 42);
    const SERVER_IP: Ipv4Address = Ipv4Address::new(192, 168, 1, 1);
    const DNS_IP_1: Ipv4Address = Ipv4Address::new(1, 1, 1, 1);
    const DNS_IP_2: Ipv4Address = Ipv4Address::new(1, 1, 1, 2);
    const DNS_IP_3: Ipv4Address = Ipv4Address::new(1, 1, 1, 3);
    const DNS_IPS: &[Ipv4Address] = &[DNS_IP_1, DNS_IP_2, DNS_IP_3];

    const MASK_24: Ipv4Address = Ipv4Address::new(255, 255, 255, 0);

    const MY_MAC: EthernetAddress = EthernetAddress([0x02, 0x02, 0x02, 0x02, 0x02, 0x02]);

    const IP_BROADCAST: Ipv4Repr = Ipv4Repr {
        src_addr: Ipv4Address::UNSPECIFIED,
        dst_addr: Ipv4Address::BROADCAST,
        next_header: IpProtocol::Udp,
        payload_len: 0,
        hop_limit: 64,
    };

    const IP_BROADCAST_ADDRESSED: Ipv4Repr = Ipv4Repr {
        src_addr: MY_IP,
        dst_addr: Ipv4Address::BROADCAST,
        next_header: IpProtocol::Udp,
        payload_len: 0,
        hop_limit: 64,
    };

    const IP_SERVER_BROADCAST: Ipv4Repr = Ipv4Repr {
        src_addr: SERVER_IP,
        dst_addr: Ipv4Address::BROADCAST,
        next_header: IpProtocol::Udp,
        payload_len: 0,
        hop_limit: 64,
    };

    const IP_RECV: Ipv4Repr = Ipv4Repr {
        src_addr: SERVER_IP,
        dst_addr: MY_IP,
        next_header: IpProtocol::Udp,
        payload_len: 0,
        hop_limit: 64,
    };

    const IP_SEND: Ipv4Repr = Ipv4Repr {
        src_addr: MY_IP,
        dst_addr: SERVER_IP,
        next_header: IpProtocol::Udp,
        payload_len: 0,
        hop_limit: 64,
    };

    const UDP_SEND: UdpRepr = UdpRepr {
        src_port: DHCP_CLIENT_PORT,
        dst_port: DHCP_SERVER_PORT,
    };
    const UDP_RECV: UdpRepr = UdpRepr {
        src_port: DHCP_SERVER_PORT,
        dst_port: DHCP_CLIENT_PORT,
    };

    const DIFFERENT_CLIENT_PORT: u16 = 6800;
    const DIFFERENT_SERVER_PORT: u16 = 6700;

    const UDP_SEND_DIFFERENT_PORT: UdpRepr = UdpRepr {
        src_port: DIFFERENT_CLIENT_PORT,
        dst_port: DIFFERENT_SERVER_PORT,
    };
    const UDP_RECV_DIFFERENT_PORT: UdpRepr = UdpRepr {
        src_port: DIFFERENT_SERVER_PORT,
        dst_port: DIFFERENT_CLIENT_PORT,
    };

    const DHCP_DEFAULT: DhcpRepr = DhcpRepr {
        message_type: DhcpMessageType::Unknown(99),
        transaction_id: TXID,
        secs: 0,
        client_hardware_address: MY_MAC,
        client_ip: Ipv4Address::UNSPECIFIED,
        your_ip: Ipv4Address::UNSPECIFIED,
        server_ip: Ipv4Address::UNSPECIFIED,
        router: None,
        subnet_mask: None,
        relay_agent_ip: Ipv4Address::UNSPECIFIED,
        broadcast: false,
        requested_ip: None,
        client_identifier: None,
        server_identifier: None,
        parameter_request_list: None,
        dns_servers: None,
        max_size: None,
        renew_duration: None,
        rebind_duration: None,
        lease_duration: None,
        additional_options: &[],
    };

    const DHCP_DISCOVER: DhcpRepr = DhcpRepr {
        message_type: DhcpMessageType::Discover,
        client_identifier: Some(MY_MAC),
        parameter_request_list: Some(&[1, 3, 6]),
        max_size: Some(1432),
        ..DHCP_DEFAULT
    };

    fn dhcp_offer() -> DhcpRepr<'static> {
        DhcpRepr {
            message_type: DhcpMessageType::Offer,
            server_ip: SERVER_IP,
            server_identifier: Some(SERVER_IP),

            your_ip: MY_IP,
            router: Some(SERVER_IP),
            subnet_mask: Some(MASK_24),
            dns_servers: Some(Vec::from_slice(DNS_IPS).unwrap()),
            lease_duration: Some(1000),

            ..DHCP_DEFAULT
        }
    }

    const DHCP_REQUEST: DhcpRepr = DhcpRepr {
        message_type: DhcpMessageType::Request,
        client_identifier: Some(MY_MAC),
        server_identifier: Some(SERVER_IP),
        max_size: Some(1432),

        requested_ip: Some(MY_IP),
        parameter_request_list: Some(&[1, 3, 6]),
        ..DHCP_DEFAULT
    };

    fn dhcp_ack() -> DhcpRepr<'static> {
        DhcpRepr {
            message_type: DhcpMessageType::Ack,
            server_ip: SERVER_IP,
            server_identifier: Some(SERVER_IP),

            your_ip: MY_IP,
            router: Some(SERVER_IP),
            subnet_mask: Some(MASK_24),
            dns_servers: Some(Vec::from_slice(DNS_IPS).unwrap()),
            lease_duration: Some(1000),

            ..DHCP_DEFAULT
        }
    }

    const DHCP_NAK: DhcpRepr = DhcpRepr {
        message_type: DhcpMessageType::Nak,
        server_ip: SERVER_IP,
        server_identifier: Some(SERVER_IP),
        ..DHCP_DEFAULT
    };

    const DHCP_RENEW: DhcpRepr = DhcpRepr {
        message_type: DhcpMessageType::Request,
        client_identifier: Some(MY_MAC),
        // NO server_identifier in renew requests, only in first one!
        client_ip: MY_IP,
        max_size: Some(1432),

        requested_ip: None,
        parameter_request_list: Some(&[1, 3, 6]),
        ..DHCP_DEFAULT
    };

    const DHCP_REBIND: DhcpRepr = DhcpRepr {
        message_type: DhcpMessageType::Request,
        client_identifier: Some(MY_MAC),
        // NO server_identifier in renew requests, only in first one!
        client_ip: MY_IP,
        max_size: Some(1432),

        requested_ip: None,
        parameter_request_list: Some(&[1, 3, 6]),
        ..DHCP_DEFAULT
    };

    // =========================================================================================//
    // Tests

    use crate::phy::Medium;
    use crate::tests::setup;
    use rstest::*;

    fn socket(medium: Medium) -> TestSocket {
        let (iface, _, _) = setup(medium);
        let mut s = Socket::new();
        assert_eq!(s.poll(), Some(Event::Deconfigured));
        TestSocket {
            socket: s,
            cx: iface.inner,
        }
    }

    fn socket_different_port(medium: Medium) -> TestSocket {
        let (iface, _, _) = setup(medium);
        let mut s = Socket::new();
        s.set_ports(DIFFERENT_SERVER_PORT, DIFFERENT_CLIENT_PORT);

        assert_eq!(s.poll(), Some(Event::Deconfigured));
        TestSocket {
            socket: s,
            cx: iface.inner,
        }
    }

    fn socket_bound(medium: Medium) -> TestSocket {
        let mut s = socket(medium);
        s.state = ClientState::Renewing(RenewState {
            config: Config {
                server: ServerInfo {
                    address: SERVER_IP,
                    identifier: SERVER_IP,
                },
                address: Ipv4Cidr::new(MY_IP, 24),
                dns_servers: Vec::from_slice(DNS_IPS).unwrap(),
                router: Some(SERVER_IP),
                packet: None,
            },
            renew_at: Instant::from_secs(500),
            rebind_at: Instant::from_secs(875),
            rebinding: false,
            expires_at: Instant::from_secs(1000),
        });

        s
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_bind(#[case] medium: Medium) {
        let mut s = socket(medium);

        recv!(s, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        assert_eq!(s.poll(), None);
        send!(s, (IP_RECV, UDP_RECV, dhcp_offer()));
        assert_eq!(s.poll(), None);
        recv!(s, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        assert_eq!(s.poll(), None);
        send!(s, (IP_RECV, UDP_RECV, dhcp_ack()));

        assert_eq!(
            s.poll(),
            Some(Event::Configured(Config {
                server: ServerInfo {
                    address: SERVER_IP,
                    identifier: SERVER_IP,
                },
                address: Ipv4Cidr::new(MY_IP, 24),
                dns_servers: Vec::from_slice(DNS_IPS).unwrap(),
                router: Some(SERVER_IP),
                packet: None,
            }))
        );

        match &s.state {
            ClientState::Renewing(r) => {
                assert_eq!(r.renew_at, Instant::from_secs(500));
                assert_eq!(r.rebind_at, Instant::from_secs(875));
                assert_eq!(r.expires_at, Instant::from_secs(1000));
            }
            _ => panic!("Invalid state"),
        }
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_bind_different_ports(#[case] medium: Medium) {
        let mut s = socket_different_port(medium);

        recv!(s, [(IP_BROADCAST, UDP_SEND_DIFFERENT_PORT, DHCP_DISCOVER)]);
        assert_eq!(s.poll(), None);
        send!(s, (IP_RECV, UDP_RECV_DIFFERENT_PORT, dhcp_offer()));
        assert_eq!(s.poll(), None);
        recv!(s, [(IP_BROADCAST, UDP_SEND_DIFFERENT_PORT, DHCP_REQUEST)]);
        assert_eq!(s.poll(), None);
        send!(s, (IP_RECV, UDP_RECV_DIFFERENT_PORT, dhcp_ack()));

        assert_eq!(
            s.poll(),
            Some(Event::Configured(Config {
                server: ServerInfo {
                    address: SERVER_IP,
                    identifier: SERVER_IP,
                },
                address: Ipv4Cidr::new(MY_IP, 24),
                dns_servers: Vec::from_slice(DNS_IPS).unwrap(),
                router: Some(SERVER_IP),
                packet: None,
            }))
        );

        match &s.state {
            ClientState::Renewing(r) => {
                assert_eq!(r.renew_at, Instant::from_secs(500));
                assert_eq!(r.rebind_at, Instant::from_secs(875));
                assert_eq!(r.expires_at, Instant::from_secs(1000));
            }
            _ => panic!("Invalid state"),
        }
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_discover_retransmit(#[case] medium: Medium) {
        let mut s = socket(medium);

        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        recv!(s, time 1_000, []);
        recv!(s, time 10_000, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        recv!(s, time 11_000, []);
        recv!(s, time 20_000, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);

        // check after retransmits it still works
        send!(s, time 20_000, (IP_RECV, UDP_RECV, dhcp_offer()));
        recv!(s, time 20_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_request_retransmit(#[case] medium: Medium) {
        let mut s = socket(medium);

        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        send!(s, time 0, (IP_RECV, UDP_RECV, dhcp_offer()));
        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 1_000, []);
        recv!(s, time 5_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 6_000, []);
        recv!(s, time 10_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 15_000, []);
        recv!(s, time 20_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);

        // check after retransmits it still works
        send!(s, time 20_000, (IP_RECV, UDP_RECV, dhcp_ack()));

        match &s.state {
            ClientState::Renewing(r) => {
                assert_eq!(r.renew_at, Instant::from_secs(20 + 500));
                assert_eq!(r.expires_at, Instant::from_secs(20 + 1000));
            }
            _ => panic!("Invalid state"),
        }
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_request_timeout(#[case] medium: Medium) {
        let mut s = socket(medium);

        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        send!(s, time 0, (IP_RECV, UDP_RECV, dhcp_offer()));
        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 5_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 10_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 20_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        recv!(s, time 30_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);

        // After 5 tries and 70 seconds, it gives up.
        // 5 + 5 + 10 + 10 + 20 = 70
        recv!(s, time 70_000, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);

        // check it still works
        send!(s, time 60_000, (IP_RECV, UDP_RECV, dhcp_offer()));
        recv!(s, time 60_000, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_request_nak(#[case] medium: Medium) {
        let mut s = socket(medium);

        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        send!(s, time 0, (IP_RECV, UDP_RECV, dhcp_offer()));
        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_REQUEST)]);
        send!(s, time 0, (IP_SERVER_BROADCAST, UDP_RECV, DHCP_NAK));
        recv!(s, time 0, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_renew(#[case] medium: Medium) {
        let mut s = socket_bound(medium);

        recv!(s, []);
        assert_eq!(s.poll(), None);
        recv!(s, time 500_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        assert_eq!(s.poll(), None);

        match &s.state {
            ClientState::Renewing(r) => {
                // the expiration still hasn't been bumped, because
                // we haven't received the ACK yet
                assert_eq!(r.expires_at, Instant::from_secs(1000));
            }
            _ => panic!("Invalid state"),
        }

        send!(s, time 500_000, (IP_RECV, UDP_RECV, dhcp_ack()));
        assert_eq!(s.poll(), None);

        match &s.state {
            ClientState::Renewing(r) => {
                // NOW the expiration gets bumped
                assert_eq!(r.renew_at, Instant::from_secs(500 + 500));
                assert_eq!(r.expires_at, Instant::from_secs(500 + 1000));
            }
            _ => panic!("Invalid state"),
        }
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_renew_rebind_retransmit(#[case] medium: Medium) {
        let mut s = socket_bound(medium);

        recv!(s, []);
        // First renew attempt at T1
        recv!(s, time 499_000, []);
        recv!(s, time 500_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt at half way to T2
        recv!(s, time 687_000, []);
        recv!(s, time 687_500, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt at half way again to T2
        recv!(s, time 781_000, []);
        recv!(s, time 781_250, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt 60s later (minimum interval)
        recv!(s, time 841_000, []);
        recv!(s, time 841_250, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // No more renews due to minimum interval
        recv!(s, time 874_000, []);
        // First rebind attempt
        recv!(s, time 875_000, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);
        // Next rebind attempt half way to expiry
        recv!(s, time 937_000, []);
        recv!(s, time 937_500, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);
        // Next rebind attempt 60s later (minimum interval)
        recv!(s, time 997_000, []);
        recv!(s, time 997_500, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);

        // check it still works
        send!(s, time 999_000, (IP_RECV, UDP_RECV, dhcp_ack()));
        match &s.state {
            ClientState::Renewing(r) => {
                // NOW the expiration gets bumped
                assert_eq!(r.renew_at, Instant::from_secs(999 + 500));
                assert_eq!(r.expires_at, Instant::from_secs(999 + 1000));
            }
            _ => panic!("Invalid state"),
        }
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_renew_rebind_timeout(#[case] medium: Medium) {
        let mut s = socket_bound(medium);

        recv!(s, []);
        // First renew attempt at T1
        recv!(s, time 500_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt at half way to T2
        recv!(s, time 687_500, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt at half way again to T2
        recv!(s, time 781_250, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt 60s later (minimum interval)
        recv!(s, time 841_250, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // TODO uncomment below part of test
        // // First rebind attempt
        // recv!(s, time 875_000, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);
        // // Next rebind attempt half way to expiry
        // recv!(s, time 937_500, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);
        // // Next rebind attempt 60s later (minimum interval)
        // recv!(s, time 997_500, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);
        // No more rebinds due to minimum interval
        recv!(s, time 1_000_000, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
        match &s.state {
            ClientState::Discovering(_) => {}
            _ => panic!("Invalid state"),
        }
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_min_max_renew_timeout(#[case] medium: Medium) {
        let mut s = socket_bound(medium);
        // Set a minimum of 45s and a maximum of 120s
        let config = RetryConfig {
            max_renew_timeout: Duration::from_secs(120),
            min_renew_timeout: Duration::from_secs(45),
            ..s.get_retry_config()
        };
        s.set_retry_config(config);
        recv!(s, []);
        // First renew attempt at T1
        recv!(s, time 499_999, []);
        recv!(s, time 500_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt 120s after T1 because we hit the max
        recv!(s, time 619_999, []);
        recv!(s, time 620_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt 120s after previous because we hit the max again
        recv!(s, time 739_999, []);
        recv!(s, time 740_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt half way to T2
        recv!(s, time 807_499, []);
        recv!(s, time 807_500, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next renew attempt 45s after previous because we hit the min
        recv!(s, time 852_499, []);
        recv!(s, time 852_500, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        // Next is a rebind, because the min puts us after T2
        recv!(s, time 874_999, []);
        recv!(s, time 875_000, [(IP_BROADCAST_ADDRESSED, UDP_SEND, DHCP_REBIND)]);
    }

    #[rstest]
    #[case::ip(Medium::Ethernet)]
    #[cfg(feature = "medium-ethernet")]
    fn test_renew_nak(#[case] medium: Medium) {
        let mut s = socket_bound(medium);

        recv!(s, time 500_000, [(IP_SEND, UDP_SEND, DHCP_RENEW)]);
        send!(s, time 500_000, (IP_SERVER_BROADCAST, UDP_RECV, DHCP_NAK));
        recv!(s, time 500_000, [(IP_BROADCAST, UDP_SEND, DHCP_DISCOVER)]);
    }
}
