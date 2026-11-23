//! A loopback "cloud" that records what each request asked, for the header
//! tests of every cloud client: [`Heads::start`] answers a plain request
//! `200 {}` and a WebSocket upgrade `401`, and keeps each request head.

use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// The recorded request heads of one listener.
#[derive(Clone)]
pub struct Heads {
    /// `http://127.0.0.1:<port>`.
    pub base_url: String,
    heads: Arc<Mutex<Vec<String>>>,
    /// The listener's tasks: they end with the runtime, or when the last clone goes.
    _scope: Arc<cmux_scope::Scope>,
}

impl Heads {
    /// Listens on a loopback port until the runtime ends.
    pub async fn start() -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let base_url = format!("http://{}", listener.local_addr()?);
        let heads = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&heads);
        let scope = Arc::new(cmux_scope::Scope::new("build-space test heads"));
        let connections = Arc::downgrade(&scope);
        scope.spawn_until_cancelled("build-space test heads: accept", async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else { return };
                let recorded = Arc::clone(&recorded);
                let Some(connections) = connections.upgrade() else { return };
                connections.spawn_until_cancelled("build-space test heads: request", async move {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        if stream.read(&mut byte).await.unwrap_or(0) == 0 {
                            return;
                        }
                        head.push(byte[0]);
                    }
                    let head = String::from_utf8_lossy(&head).to_ascii_lowercase();
                    let upgrade = head.contains("upgrade: websocket");
                    if let Ok(mut heads) = recorded.lock() {
                        heads.push(head);
                    }
                    let answer: &[u8] = if upgrade {
                        b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                    } else {
                        b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
                    };
                    let _ = stream.write_all(answer).await;
                    let _ = stream.shutdown().await;
                });
            }
        });
        Ok(Self { base_url, heads, _scope: scope })
    }

    /// `ws://127.0.0.1:<port>`.
    pub fn ws_url(&self) -> String {
        self.base_url.replacen("http://", "ws://", 1)
    }

    /// Every head so far (lowercased).
    pub fn all(&self) -> Vec<String> {
        self.heads.lock().map(|h| h.clone()).unwrap_or_default()
    }

    /// The build space header of each head so far (`None`: the head had none).
    pub fn spaces(&self) -> Vec<Option<String>> {
        self.all()
            .iter()
            .map(|head| {
                head.lines()
                    .find_map(|line| line.strip_prefix(&format!("{}:", crate::HEADER)))
                    .map(|value| value.trim().to_owned())
            })
            .collect()
    }

    /// Waits up to two seconds for at least `count` heads.
    pub async fn wait_for(&self, count: usize) -> Vec<String> {
        for _ in 0..200 {
            let all = self.all();
            if all.len() >= count {
                return all;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        self.all()
    }
}

/// A space for tests: `dev:<slug>`, `slug` as the backends take it (`[a-z0-9-]`).
pub fn space(slug: &str) -> crate::BuildSpace {
    crate::BuildSpace(format!("dev:{slug}"))
}

/// A refused resolution, as a malformed `CMUX_BUILD_SPACE` gives.
pub fn refused() -> crate::Resolved {
    crate::resolve(|name| (name == crate::ENV).then(|| "not-a-space".to_owned()))
}
