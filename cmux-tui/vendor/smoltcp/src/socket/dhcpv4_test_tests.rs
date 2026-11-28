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
