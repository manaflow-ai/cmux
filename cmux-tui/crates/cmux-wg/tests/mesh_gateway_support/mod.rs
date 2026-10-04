//! A real gateway tunnel for the mesh gateway tests: two [`WgNet`] sides
//! over loopback UDP, shaped like a Freestyle tunnel (MTU 1280), and a
//! forwarder that plays the gateway's VPC side.
//!
//! The "server" `WgNet` stands in for the Freestyle gateway. Its datagram
//! service on UDP 4101 is the VM's VPC endpoint as the Mac sees it: what A's
//! mesh sends there through the tunnel, the forwarder hands to B's mesh
//! socket on plain UDP, and what B sends back re-enters the tunnel toward
//! A's gateway socket. B therefore sees A at the forwarder's UDP address,
//! as a VM sees a Mac at the gateway's VPC address.

#![allow(dead_code)]

use std::net::{IpAddr, SocketAddr};

use cmux_wg::testing::loopback_pair;
use cmux_wg::{Priority, WgDatagramSocket, WgNet};
use tokio::net::UdpSocket;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::mesh_support::{TIMEOUT, within};

/// The VPC endpoint port of a Cloud VM's overlay endpoint (WireGuard, outer).
pub const VPC_PORT: u16 = 4101;
/// The Freestyle tunnel MTU (measured): its datagram service carries 1232.
pub const TUNNEL_MTU: u16 = 1280;
/// The inner MTU of a mesh session nested in that tunnel.
pub const NESTED_MTU: u16 = 1200;
const PING_PORT: u16 = 9;

pub struct Tunnel {
    pub client: WgNet,
    pub server: WgNet,
    pub client_v6: IpAddr,
    pub server_v6: IpAddr,
}

impl Tunnel {
    /// The VPC endpoint datagrams to B go to, inside the tunnel.
    pub fn vpc(&self) -> SocketAddr {
        SocketAddr::new(self.server_v6, VPC_PORT)
    }

    /// Where the gateway sends datagrams for A's mesh: A's gateway socket.
    pub fn client_target(&self) -> SocketAddr {
        SocketAddr::new(self.client_v6, VPC_PORT)
    }

    /// A datagram socket for A's mesh to attach as its gateway.
    pub async fn gateway_socket(&self) -> WgDatagramSocket {
        within(self.client.bind_datagram(VPC_PORT)).await.expect("bind the gateway socket")
    }

    /// The gateway side's VPC endpoint socket.
    pub async fn vpc_socket(&self) -> WgDatagramSocket {
        within(self.server.bind_datagram(VPC_PORT)).await.expect("bind the VPC socket")
    }
}

/// A tunnel with this MTU whose session is up in both directions.
pub async fn tunnel(mtu: u16) -> Tunnel {
    let mut pair = loopback_pair().await.expect("loopback pair");
    pair.client.mtu = mtu;
    pair.server.mtu = mtu;
    let client = WgNet::start(pair.client, pair.client_socket).await.expect("client tunnel");
    let server = WgNet::start(pair.server, pair.server_socket).await.expect("server tunnel");
    client.wait_for_handshake(TIMEOUT).await.expect("tunnel handshake");
    // One datagram each way confirms the responder's session, so the
    // gateway side can send first.
    let ping = within(client.bind_datagram(PING_PORT)).await.unwrap();
    let mut pong = within(server.bind_datagram(PING_PORT)).await.unwrap();
    let to = SocketAddr::new(pair.server_v6, PING_PORT);
    within(ping.send_to(b"ping", to, Priority::Interactive)).await.unwrap();
    within(pong.recv_from()).await.expect("ping through the tunnel");
    Tunnel { client, server, client_v6: pair.client_v6, server_v6: pair.server_v6 }
}

/// How B's datagrams reach A.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Toward {
    /// From the forwarder's UDP socket straight to A's mesh socket.
    Direct,
    /// Into the gateway tunnel, to A's gateway socket.
    Gateway,
}

pub struct Forwarder {
    /// The forwarder's UDP address: B's view of A, and A's direct route to B.
    pub relay: SocketAddr,
    mode: watch::Sender<Toward>,
    task: JoinHandle<()>,
}

impl Forwarder {
    pub fn set(&self, toward: Toward) {
        self.mode.send_replace(toward);
    }
}

impl Drop for Forwarder {
    fn drop(&mut self) {
        self.task.abort();
    }
}

enum Event {
    Udp(std::io::Result<(usize, SocketAddr)>),
    Tunnel(Option<(Vec<u8>, SocketAddr)>),
}

/// Forward between the gateway's VPC socket (and a direct UDP path from A)
/// and B's mesh socket.
pub async fn forwarder(
    mut vpc: WgDatagramSocket,
    client_target: SocketAddr,
    a_udp: SocketAddr,
    b_udp: SocketAddr,
    toward: Toward,
) -> Forwarder {
    let relay = UdpSocket::bind("127.0.0.1:0").await.expect("bind the relay");
    let address = relay.local_addr().expect("relay address");
    let (mode, watched) = watch::channel(toward);
    let task = tokio::spawn(async move {
        let mut buffer = vec![0u8; 65_535];
        loop {
            let event = tokio::select! {
                received = relay.recv_from(&mut buffer) => Event::Udp(received),
                received = vpc.recv_from() => Event::Tunnel(received),
            };
            match event {
                Event::Udp(Ok((len, from))) if from == b_udp => {
                    let datagram = &buffer[..len];
                    let toward = *watched.borrow();
                    match toward {
                        Toward::Direct => {
                            let _ = relay.send_to(datagram, a_udp).await;
                        }
                        Toward::Gateway => {
                            let _ = vpc.send_to(datagram, client_target, Priority::Interactive).await;
                        }
                    }
                }
                Event::Udp(Ok((len, _))) => {
                    let _ = relay.send_to(&buffer[..len], b_udp).await;
                }
                Event::Tunnel(Some((payload, _))) => {
                    let _ = relay.send_to(&payload, b_udp).await;
                }
                Event::Tunnel(None) => return,
                Event::Udp(Err(_)) => {}
            }
        }
    });
    Forwarder { relay: address, mode, task }
}
