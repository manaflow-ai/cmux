//! Transfer clients have no total deadline: a body that keeps arriving is read
//! to its end however long it takes, while an ordinary call stays bounded and a
//! stalled transfer still fails on its read-idle timeout.

use std::time::Duration;

use cmux_vm_client::{Limits, authenticated_raw_client_with, raw::types};
use futures::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const VM_ID: &str = "vm_0123456789abcdefghjkmnpqrs";

/// A server that answers every request with a `bytes`-byte body, one byte
/// every `gap`, so the whole body takes `bytes * gap`.
async fn trickling_server(bytes: usize, gap: Duration) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut seen = Vec::new();
                let mut buffer = [0_u8; 4096];
                while !seen.windows(4).any(|w| w == b"\r\n\r\n") {
                    match socket.read(&mut buffer).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => seen.extend_from_slice(&buffer[..n]),
                    }
                }
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\ncontent-length: {bytes}\r\nconnection: close\r\n\r\n"
                );
                if socket.write_all(head.as_bytes()).await.is_err() {
                    return;
                }
                for _ in 0..bytes {
                    tokio::time::sleep(gap).await;
                    if socket.write_all(b"x").await.is_err() || socket.flush().await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    format!("http://{address}")
}

async fn read_whole_file(base_url: &str, limits: Limits) -> Result<usize, String> {
    let client = authenticated_raw_client_with(base_url, "cmuxvm_sk_test", None, "test", limits)
        .map_err(|e| e.to_string())?;
    let path: types::GuestPath = "/root/big".parse().unwrap();
    let response = client
        .files_read_file(VM_ID, &path, None, None)
        .await
        .map_err(|e| e.to_string())?;
    let mut stream = response.into_inner();
    let mut total = 0;
    while let Some(chunk) = stream.next().await {
        total += chunk.map_err(|e| e.to_string())?.len();
    }
    Ok(total)
}

#[tokio::test]
async fn a_transfer_outlasts_the_total_deadline_an_ordinary_call_keeps() {
    // Eight bytes, 150 ms apart: about 1.2 s in all, never silent for long.
    let base_url = trickling_server(8, Duration::from_millis(150)).await;
    let bounded = Limits {
        total: Some(Duration::from_millis(500)),
        ..Limits::API
    };
    assert!(
        read_whole_file(&base_url, bounded).await.is_err(),
        "an ordinary call keeps its total deadline"
    );
    let transfer = Limits {
        read_idle: Some(Duration::from_millis(600)),
        ..Limits::STREAM
    };
    assert_eq!(read_whole_file(&base_url, transfer).await, Ok(8));
}

#[tokio::test]
async fn a_stalled_transfer_fails_on_its_read_idle_timeout() {
    let base_url = trickling_server(2, Duration::from_millis(800)).await;
    let transfer = Limits {
        read_idle: Some(Duration::from_millis(200)),
        ..Limits::STREAM
    };
    assert!(read_whole_file(&base_url, transfer).await.is_err());
}

#[test]
fn the_shipped_limits_bound_calls_and_leave_transfers_open() {
    assert!(Limits::API.total.is_some());
    assert_eq!(Limits::STREAM.total, None);
    assert!(Limits::STREAM.read_idle.is_some());
    assert_eq!(Limits::UPLOAD.total, None);
    assert_eq!(Limits::UPLOAD.read_idle, None);
}
