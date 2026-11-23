//! A tiny HTTP/1.1 server on 127.0.0.1 for the tests: each connection gets one canned answer,
//! and the requests it read come back through the handle.

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

pub struct Served {
    /// `http://127.0.0.1:PORT`.
    pub url: String,
    /// The raw requests, one per answered connection.
    pub requests: JoinHandle<Vec<Vec<u8>>>,
}

/// An answer with this status, JSON content type and body.
pub fn answer(status: u16, body: &str) -> Vec<u8> {
    format!(
        "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

async fn read_request(stream: &mut TcpStream) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = stream.read(&mut chunk).await.unwrap();
        if n == 0 {
            return buf;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
            let length = head
                .lines()
                .find_map(|l| l.strip_prefix("content-length:"))
                .map_or(0, |v| v.trim().parse::<usize>().unwrap());
            if buf.len() >= end + 4 + length {
                return buf;
            }
        }
    }
}

/// Serves `answers` in order, one connection each.
pub async fn serve(answers: Vec<Vec<u8>>) -> Served {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let requests = tokio::spawn(async move {
        let mut seen = Vec::new();
        for answer in answers {
            let (mut stream, _) = listener.accept().await.unwrap();
            seen.push(read_request(&mut stream).await);
            stream.write_all(&answer).await.unwrap();
            stream.shutdown().await.ok();
        }
        seen
    });
    Served { url, requests }
}

/// Accepts one connection and never answers (until the test ends).
pub async fn hang() -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        drop(stream);
    });
    (url, task)
}

/// A URL where nothing listens.
pub async fn closed_url() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    url
}
