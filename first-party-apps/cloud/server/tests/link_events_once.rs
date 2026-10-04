//! One consumer for the link supervisor's events: the serve loop drains
//! the queue once and gives each event to the host lines and to the
//! connector. Neither drain may take an event away from the other.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::Server;
use cmux_cloud::connector::iface::{
    CarrierEvent, ConnectRequest, ConnectorEvent, Lost, TerminalConnector,
};
use cmux_cloud::rescue::iface::OpenToken;
use common::FakeControlPlane;

const CHANNEL: &str = "cloud-vm/vm-alpha01#1";

fn server(spawner: &FakeSpawner) -> Server<FakeControlPlane> {
    Server::with_attach(
        FakeControlPlane::with(&["vm-get", "attach_endpoint_alpha"]),
        attach(spawner, &FakeTransport::default()),
    )
}

fn connect(s: &mut Server<FakeControlPlane>) {
    let request = ConnectRequest {
        kind: "cloud-vm".into(),
        target: "vm-alpha01".into(),
        open_token: OpenToken("open-token-test".into()),
    };
    s.connector().connect(request).expect("connect");
}

fn downs(events: &[CarrierEvent]) -> usize {
    events.iter().filter(|e| matches!(e, CarrierEvent::Down { generation: 1, .. })).count()
}

fn ends(events: &[ConnectorEvent]) -> usize {
    events
        .iter()
        .filter(|e| {
            matches!(e, ConnectorEvent::End { channel, lost: Lost { retryable: true, .. } }
                if channel == CHANNEL)
        })
        .count()
}

#[test]
fn the_host_drain_first_still_leaves_the_connector_its_end() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    connect(&mut s);
    spawner.exit("vm-alpha01", 1);
    let host = s.take_link_events();
    let connector = s.connector().take_events();
    assert_eq!(downs(&host), 1, "the host line gets the exit once: {host:?}");
    assert_eq!(ends(&connector), 1, "the connector gets its end too: {connector:?}");
    assert!(s.take_link_events().is_empty() && s.connector().take_events().is_empty());
}

#[test]
fn the_connector_drain_first_still_leaves_the_host_its_line() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    connect(&mut s);
    spawner.exit("vm-alpha01", 1);
    let connector = s.connector().take_events();
    let host = s.take_link_events();
    assert_eq!(ends(&connector), 1, "the connector gets the end once: {connector:?}");
    assert_eq!(downs(&host), 1, "the host line gets the exit too: {host:?}");
}
