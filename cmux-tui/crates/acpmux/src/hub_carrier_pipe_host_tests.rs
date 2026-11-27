use super::*;
use cmux_remote::resume_hold::{Held, hold};
use std::sync::Mutex as StdMutex;
use tokio::io::DuplexStream;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

const BOUND: Duration = Duration::from_secs(30);

fn pattern(seed: u64, len: usize) -> Vec<u8> {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
    (0..len)
        .map(|_| {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (x >> 33) as u8
        })
        .collect()
}

/// Write `send` in pieces, end the writes, return what was read.
async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(io: S, send: Vec<u8>) -> Vec<u8> {
    let (mut read, mut write) = tokio::io::split(io);
    let writing = async {
        for piece in send.chunks(5_003) {
            write.write_all(piece).await.unwrap();
        }
        write.shutdown().await.unwrap();
    };
    let reading = async {
        let mut got = Vec::new();
        read.read_to_end(&mut got).await.unwrap();
        got
    };
    tokio::join!(writing, reading).1
}

/// A pipe host on a socket in a fresh directory.
fn host(idle: Duration) -> (tempfile::TempDir, PathBuf, JoinHandle<()>) {
    let dir = tempfile::tempdir().unwrap();
    let socket = socket_path(dir.path());
    let listener = bind(&socket).unwrap().expect("a fresh socket was taken");
    let serving = tokio::spawn(serve(listener, Parking::new(RESUME_GRACE), idle));
    (dir, socket, serving)
}

/// The daemons between the dialer and the host: each connect is one daemon's hop (the stream
/// it serves, bridged to the host), and `restart` ends the newest one as a daemon's exit does.
struct Daemons {
    socket: PathBuf,
    header: Header,
    hops: StdMutex<Vec<JoinHandle<()>>>,
}

impl Daemons {
    fn connect(self: &Arc<Self>) -> impl Future<Output = Result<DuplexStream, String>> + use<> {
        let daemons = self.clone();
        async move {
            let (near, far) = tokio::io::duplex(32 * 1024);
            let conn = super::connect(&daemons.socket, &daemons.header).await?;
            let hop = tokio::spawn(bridge(far, conn));
            daemons.hops.lock().unwrap().push(hop);
            Ok(near)
        }
    }

    fn restart(&self) {
        if let Some(hop) = self.hops.lock().unwrap().last() {
            hop.abort();
        }
    }
}

#[tokio::test]
async fn a_held_pipe_lives_through_its_far_daemon_restarting() {
    // The far machine's sshd: one connection, a whole exchange.
    let sshd = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = sshd.local_addr().unwrap();
    let to_far = pattern(11, 6 << 20);
    let to_near = pattern(12, 1 << 20);
    let far_got = {
        let to_near = to_near.clone();
        tokio::spawn(async move {
            let (conn, _) = sshd.accept().await.unwrap();
            let got = exchange(conn, to_near).await;
            // Only one connection: a resume never dials sshd again.
            let again = tokio::time::timeout(Duration::from_millis(200), sshd.accept()).await;
            assert!(again.is_err(), "the host dialed sshd again for a resumed pipe");
            got
        })
    };
    let (_dir, socket, serving) = host(IDLE_EXIT);
    let daemons = Arc::new(Daemons {
        socket,
        header: header("dialer", target),
        hops: StdMutex::new(Vec::new()),
    });
    let (near_app, near_local) = tokio::io::duplex(8 * 1024);
    let near_got = tokio::spawn(exchange(near_app, to_far.clone()));
    let restarts = {
        let daemons = daemons.clone();
        tokio::spawn(async move {
            for i in 0..5u64 {
                tokio::time::sleep(Duration::from_millis(5 + 9 * i)).await;
                daemons.restart();
            }
        })
    };
    let held = tokio::time::timeout(BOUND, hold(near_local, || daemons.connect(), RESUME_GRACE))
        .await
        .expect("the held pipe did not end");
    assert_eq!(held, Held::Finished);
    restarts.await.unwrap();
    assert_eq!(near_got.await.unwrap(), to_near, "the dialer lost or doubled bytes");
    assert_eq!(far_got.await.unwrap(), to_far, "sshd lost or doubled bytes");
    assert!(daemons.hops.lock().unwrap().len() > 1, "no restart landed inside the transfer");
    serving.abort();
}

#[tokio::test]
async fn the_host_refuses_a_target_off_this_machine() {
    let (_dir, socket, serving) = host(IDLE_EXIT);
    let target: std::net::SocketAddr = "192.0.2.1:22".parse().unwrap();
    let mut conn = super::connect(&socket, &header("dialer", target)).await.unwrap();
    let mut got = Vec::new();
    let read = tokio::time::timeout(BOUND, conn.read_to_end(&mut got)).await.unwrap();
    assert!(read.is_ok_and(|n| n == 0), "the host answered a stream to {target}");
    serving.abort();
}

#[tokio::test]
async fn the_host_refuses_a_stream_without_a_header() {
    let (_dir, socket, serving) = host(IDLE_EXIT);
    let mut conn = UnixStream::connect(&socket).await.unwrap();
    conn.write_all(&[b'x'; HEADER_BYTES + 1]).await.unwrap();
    let mut got = Vec::new();
    let read = tokio::time::timeout(BOUND, conn.read_to_end(&mut got)).await.unwrap();
    assert!(read.is_err() || got.is_empty(), "the host answered a stream with no header");
    serving.abort();
}

#[tokio::test]
async fn an_idle_host_ends() {
    let (_dir, _socket, serving) = host(Duration::from_millis(50));
    tokio::time::timeout(BOUND, serving).await.expect("an idle host stayed").unwrap();
}

#[tokio::test]
async fn a_second_host_leaves_a_live_one_and_replaces_a_stale_socket() {
    let (_dir, socket, serving) = host(IDLE_EXIT);
    assert!(bind(&socket).unwrap().is_none(), "a second host took a live host's socket");
    serving.abort();
    let _ = serving.await;
    // The aborted host's listener is gone; its file stays, and a new host takes it over.
    assert!(socket.exists());
    assert!(bind(&socket).unwrap().is_some(), "a stale socket kept a new host out");
}
