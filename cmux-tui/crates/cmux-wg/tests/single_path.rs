//! A tunnel on one path under a one-path `Multipath` (the hub's shape):
//! path events come from the selector, a peer that answers probes is
//! measured, and a socket that fails for good ends the session as a plain
//! socket's failure does. Paused clock: durations are simulated.

use std::io;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{DatagramSocket, PathKind, Priority, ProbeConfig, SocketPath, WgError, WgNet};
use tokio::time::timeout;

const CLIENT: &str = "192.0.2.120:51820";
const SERVER: &str = "192.0.2.121:51820";
const ONE_WAY: Duration = Duration::from_millis(10);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

#[tokio::test(start_paused = true)]
async fn one_probed_path_reports_its_kind_and_round_trip() {
    let sim = SimNet::new();
    sim.set_link(
        addr(CLIENT),
        addr(SERVER),
        LinkProfile { latency: ONE_WAY, ..Default::default() },
    );
    let configs = config_pair(addr(SERVER));
    let socket = sim.bind(addr(CLIENT)).unwrap();
    let path = SocketPath::new(socket, Some(addr(SERVER)));
    let (client, control) = WgNet::start_single_path_on(
        configs.client.clone(),
        PathKind::ViaCloudRegion,
        Some(ProbeConfig::default()),
        path,
    )
    .unwrap();
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    let before = control.snapshot();
    assert_eq!((before.path, before.kind, before.max_datagram), (None, None, 1152));
    let mut events = control.path_events();

    // Traffic keeps the session active, which is when probes run.
    let ours = client.bind_datagram(4103).await.unwrap();
    let _theirs = server.bind_datagram(4103).await.unwrap();
    let peer = SocketAddr::new(configs.server_v6, 4103);
    let event = timeout(Duration::from_secs(5), async {
        loop {
            ours.send_to(b"frame", peer, Priority::Media).await.unwrap();
            if let Ok(event) = events.try_recv()
                && event.path.is_some()
            {
                return event;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the probed path becomes current");
    assert_eq!(event.kind, Some(PathKind::ViaCloudRegion));
    assert!((19.0..=25.0).contains(&event.rtt_ms), "rtt {} ms", event.rtt_ms);
    assert_eq!(event.max_datagram, 1152);
    assert_eq!(control.snapshot().path, event.path);
    client.shutdown().await;
    server.shutdown().await;
}

/// A socket whose receive fails with a non-transient error.
struct Broken;

impl DatagramSocket for Broken {
    fn poll_recv_from(
        &mut self,
        _cx: &mut Context<'_>,
        _buffer: &mut [u8],
    ) -> Poll<io::Result<(usize, SocketAddr)>> {
        Poll::Ready(Err(io::Error::other("interface gone")))
    }

    fn poll_send_ready(&mut self, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn try_send_to(&mut self, datagram: &[u8], _target: SocketAddr) -> io::Result<usize> {
        Ok(datagram.len())
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(addr(CLIENT))
    }
}

/// With one path and nothing to add later, a dead socket must end the
/// session (callers see `Shutdown`), not leave a tunnel that never receives.
#[tokio::test(start_paused = true)]
async fn a_failed_only_path_ends_the_session() {
    let configs = config_pair(addr(SERVER));
    let path = SocketPath::new(Broken, Some(addr(SERVER)));
    let (client, _control) =
        WgNet::start_single_path_on(configs.client, PathKind::DirectWan, None, path).unwrap();
    let ended = timeout(Duration::from_secs(5), async {
        loop {
            match client.bind_datagram(4103).await {
                Err(WgError::Shutdown) => return,
                Ok(socket) => drop(socket),
                Err(other) => panic!("unexpected {other:?}"),
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    assert!(ended.is_ok(), "the session must end when its only path fails");
}
