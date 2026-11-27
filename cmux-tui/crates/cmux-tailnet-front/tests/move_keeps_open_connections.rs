//! A workspace moves from backend A to backend B under the front, over plain loopback TCP:
//! the connection opened before the move keeps talking to A until it closes, and a new
//! connection lands on B. Prints the reconnect time (move -> first reply from B on a new
//! connection, and close-of-old -> first reply from B) so the move rig can compare.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_tailnet_front::{
    Backend, Front, Placement, PlacementMessage, PlacementTable, Route, TcpDialer,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// A backend that answers every chunk with `<name>:<chunk>`, until the client closes.
async fn spawn_backend(name: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind backend");
    let addr = listener.local_addr().expect("addr").to_string();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                loop {
                    let n = match stream.read(&mut buf).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => n,
                    };
                    let mut reply = format!("{name}:").into_bytes();
                    reply.extend_from_slice(&buf[..n]);
                    if stream.write_all(&reply).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    addr
}

async fn ask(stream: &mut TcpStream, msg: &str) -> String {
    stream.write_all(msg.as_bytes()).await.expect("write");
    let mut buf = [0u8; 1024];
    let n = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buf))
        .await
        .expect("reply in time")
        .expect("read");
    String::from_utf8_lossy(&buf[..n]).into_owned()
}

fn ssh_at(addr: &str) -> Placement {
    Placement { ssh: Some(Backend::new(addr)), previews: Default::default() }
}

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn move_keeps_open_connection_and_new_one_lands_on_new_backend() {
    let a = spawn_backend("A").await;
    let b = spawn_backend("B").await;

    let table = Arc::new(PlacementTable::new());
    let applied = table.apply(&PlacementMessage::set("main", ssh_at(&a)));
    let cmux_tailnet_front::placement::Applied::Placed { generation } = applied else {
        panic!("set should place, got {applied:?}");
    };

    let front = Front::new(Arc::clone(&table), TcpDialer);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind front");
    let front_addr = listener.local_addr().expect("front addr");
    front.spawn_serve(listener, Route::Ssh { workspace: "main".into() });

    // Open a connection before the move.
    let mut old = TcpStream::connect(front_addr).await.expect("connect old");
    assert_eq!(ask(&mut old, "hello").await, "A:hello");

    // The workspace moves to B.
    let moved_at = Instant::now();
    let moved = table.apply(&PlacementMessage::moved("main", ssh_at(&b), Some(generation)));
    assert!(matches!(moved, cmux_tailnet_front::placement::Applied::Placed { .. }));

    // A new connection lands on B.
    let mut new = TcpStream::connect(front_addr).await.expect("connect new");
    assert_eq!(ask(&mut new, "hi").await, "B:hi");
    let move_to_first_reply = moved_at.elapsed();

    // The old connection still talks to A, repeatedly, after the move.
    for i in 0..5 {
        assert_eq!(ask(&mut old, &format!("still{i}")).await, format!("A:still{i}"));
    }

    // The old one closes; a reconnect (what an ssh client's retry does) lands on B.
    drop(old);
    let closed_at = Instant::now();
    let mut again = TcpStream::connect(front_addr).await.expect("reconnect");
    assert_eq!(ask(&mut again, "back").await, "B:back");
    let close_to_first_reply = closed_at.elapsed();

    // Steady-state reconnect cost through the front: 50 fresh connections to B.
    let mut samples = Vec::new();
    for i in 0..50 {
        let t = Instant::now();
        let mut s = TcpStream::connect(front_addr).await.expect("connect sample");
        assert_eq!(ask(&mut s, &format!("s{i}")).await, format!("B:s{i}"));
        samples.push(t.elapsed());
    }
    samples.sort();

    let stats = front.stats();
    assert_eq!(stats.dial_failed.load(std::sync::atomic::Ordering::Relaxed), 0);
    assert_eq!(stats.no_placement.load(std::sync::atomic::Ordering::Relaxed), 0);

    println!(
        "stable-node move (loopback): move->first reply on B {:?}; close of old->first reply on B {:?}; \
         reconnect through front p50 {:?} p95 {:?} max {:?} (n={})",
        move_to_first_reply,
        close_to_first_reply,
        percentile(&samples, 0.5),
        percentile(&samples, 0.95),
        samples[samples.len() - 1],
        samples.len()
    );

    // Closing the front ends its listener and its open connections.
    let report = front.close(Duration::from_secs(2)).await;
    assert!(report.joined(), "{report:?}");
    let mut buf = [0u8; 8];
    let _ = again.write_all(b"after-close").await;
    let n = tokio::time::timeout(Duration::from_secs(5), again.read(&mut buf))
        .await
        .expect("closed in time")
        .unwrap_or(0);
    assert_eq!(n, 0, "close ends open connections");
}

#[tokio::test]
async fn removed_workspace_refuses_new_connections_but_keeps_open_one() {
    let a = spawn_backend("A").await;
    let table = Arc::new(PlacementTable::new());
    table.set("main", ssh_at(&a));
    let front = Front::new(Arc::clone(&table), TcpDialer);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind front");
    let front_addr = listener.local_addr().expect("front addr");
    front.spawn_serve(listener, Route::Ssh { workspace: "main".into() });

    let mut open = TcpStream::connect(front_addr).await.expect("connect");
    assert_eq!(ask(&mut open, "x").await, "A:x");
    table.apply(&PlacementMessage::removed("main"));
    assert_eq!(ask(&mut open, "y").await, "A:y");

    let mut refused = TcpStream::connect(front_addr).await.expect("tcp accept still happens");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(5), refused.read(&mut buf))
        .await
        .expect("closed in time")
        .unwrap_or(0);
    assert_eq!(n, 0, "no placement: the front closes the connection");
}

#[tokio::test]
async fn preview_port_routes_to_current_preview_target() {
    let a = spawn_backend("A3000").await;
    let b = spawn_backend("B3000").await;
    let table = Arc::new(PlacementTable::new());
    let mut placement = Placement::default();
    placement.previews.insert(3000, Backend::new(a.clone()));
    table.set("web", placement);
    let front = Front::new(Arc::clone(&table), TcpDialer);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let front_addr = listener.local_addr().expect("addr");
    front.spawn_serve(listener, Route::Preview { workspace: "web".into(), port: 3000 });
    let mut s = TcpStream::connect(front_addr).await.expect("connect");
    assert_eq!(ask(&mut s, "GET").await, "A3000:GET");
    let mut moved = Placement::default();
    moved.previews.insert(3000, Backend::new(b));
    table.move_to("web", moved, None);
    let mut s2 = TcpStream::connect(front_addr).await.expect("connect");
    assert_eq!(ask(&mut s2, "GET").await, "B3000:GET");
    assert_eq!(ask(&mut s, "GET").await, "A3000:GET");
}
