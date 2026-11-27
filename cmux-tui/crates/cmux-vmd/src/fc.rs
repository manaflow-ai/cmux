//! A minimal client for Firecracker's API socket: HTTP/1.1 over a Unix socket, one request per
//! connection (Firecracker closes nothing early, so Content-Length frames each reply).

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

/// Send one request to the Firecracker API at `sock`; an error for any status of 300 or more.
pub async fn call(sock: &Path, method: &str, path: &str, body: Option<&Value>) -> Result<Vec<u8>> {
    let mut stream =
        UnixStream::connect(sock).await.with_context(|| format!("connect {}", sock.display()))?;
    let body = body.map(serde_json::to_vec).transpose()?.unwrap_or_default();
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&body).await?;
    let (status, reply) =
        tokio::time::timeout(Duration::from_secs(120), read_response(&mut stream))
            .await
            .with_context(|| format!("{method} {path}: no reply in 120 s"))??;
    if status >= 300 {
        bail!("firecracker {method} {path} -> {status}: {}", String::from_utf8_lossy(&reply));
    }
    Ok(reply)
}

async fn read_response(stream: &mut UnixStream) -> Result<(u16, Vec<u8>)> {
    let mut buf = Vec::with_capacity(512);
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            bail!("firecracker closed the connection before a full reply");
        }
        buf.extend_from_slice(chunk.get(..n).unwrap_or_default());
        if let Some(i) = find(&buf, b"\r\n\r\n") {
            break i;
        }
    };
    let head = String::from_utf8_lossy(buf.get(..header_end).unwrap_or_default()).to_string();
    let status: u16 = head
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .context("unparseable firecracker status line")?;
    let len: usize = head
        .lines()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok())?
        })
        .unwrap_or(0);
    let mut body = buf.get(header_end + 4..).unwrap_or_default().to_vec();
    while body.len() < len {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(chunk.get(..n).unwrap_or_default());
    }
    body.truncate(len);
    Ok((status, body))
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    #[tokio::test]
    async fn parses_status_and_body() {
        let dir = std::env::temp_dir().join(format!("cmux-vmd-fc-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("api.sock");
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut b = [0u8; 1024];
            let _ = s.read(&mut b).await.unwrap();
            s.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 13\r\n\r\n{\"fault\":\"x\"}")
                .await
                .unwrap();
        });
        let err = call(&sock, "PUT", "/actions", Some(&serde_json::json!({}))).await.unwrap_err();
        assert!(err.to_string().contains("400"), "{err}");
        assert!(err.to_string().contains("fault"), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
