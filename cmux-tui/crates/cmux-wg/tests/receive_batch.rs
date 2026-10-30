//! Datagrams that wait on the socket together are handled in one driver
//! pass. On a fast link a driver that ran the stack after every datagram
//! fell behind its peer, the socket's receive buffer overflowed, and the
//! lost segments cost smoltcp's 1 s minimum retransmission timeout
//! (HQ 5080: half of the 8 MiB loopback echoes took 1.1 s instead of 0.09 s).

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::SimNet;
use cmux_wg::{DatagramSocket, SocketPath, WgNet};

const CLIENT: &str = "192.0.2.10:51820";
const SERVER: &str = "192.0.2.20:51820";
const WAITING: u64 = 32;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

#[tokio::test(start_paused = true)]
async fn datagrams_waiting_together_are_handled_in_one_pass() {
    let sim = SimNet::new();
    let configs = config_pair(addr(SERVER));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    let settled = server.wakeups();

    // Every datagram is on the socket before the driver runs again.
    let mut sender = sim.bind(addr(CLIENT)).unwrap();
    for _ in 0..WAITING {
        sender.try_send_to(&[0u8; 64], addr(SERVER)).unwrap();
    }
    tokio::time::sleep(Duration::from_millis(1)).await;

    let woke = server.wakeups() - settled;
    assert!(woke < WAITING / 4, "the driver woke {woke} times for {WAITING} waiting datagrams");
    server.shutdown().await;
}
