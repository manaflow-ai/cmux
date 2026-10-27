//! A client connection is a worker of the hub's supervisor while it is served, and
//! leaves it when its client goes; its panic is `Fatal` through `supervised::call`
//! (`supervised_tests.rs`), its requests' through `request_task_tests.rs`.

use std::time::Duration;

use tokio::sync::mpsc;

use super::*;
use crate::supervised::tests::Recorded;

async fn until(hub: &Hub, serving: bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while hub.supervisor().live_workers().iter().any(|w| w == CONNECTION_WORKER) != serving {
        assert!(tokio::time::Instant::now() < deadline, "{:?}", hub.supervisor().live_workers());
        tokio::task::yield_now().await;
    }
}

#[tokio::test]
async fn a_connection_is_served_under_the_hubs_supervisor() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = Hub::in_memory(supervisor);
    let (client, inbound) = mpsc::channel::<String>(4);
    let (out, _answers) = mpsc::channel::<String>(64);
    let served = tokio::spawn(crate::server::serve_connection(hub.clone(), inbound, out));
    until(&hub, true).await;
    // The client goes: the connection ends, its caller returns, and its worker leaves.
    drop(client);
    tokio::time::timeout(Duration::from_secs(5), served)
        .await
        .expect("the connection ended within 5 s")
        .expect("served");
    until(&hub, false).await;
    assert!(sink.reports().is_empty());
}
