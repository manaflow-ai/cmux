use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[tokio::test]
async fn proxy_tls_handshake_should_not_panic() {
    let port = 12345;

    let mut child = std::process::Command::new(assert_cmd::cargo::cargo_bin!("cmux"))
        .args(["proxy", "dummy-id", "--port", &port.to_string()])
        .env("CMUX_SANDBOX_URL", "http://127.0.0.1:12346")
        .stderr(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .expect("failed to spawn cmux");

    // Give it a moment to start
    tokio::time::sleep(Duration::from_secs(1)).await;

    // 2. Connect via TCP
    let mut stream = match TcpStream::connect(format!("127.0.0.1:{}", port)).await {
        Ok(s) => s,
        Err(e) => {
            let _ = child.kill();
            panic!("Failed to connect to proxy: {}", e);
        }
    };

    // 3. Send CONNECT
    stream
        .write_all(b"CONNECT google.com:443 HTTP/1.1\r\nHost: google.com:443\r\n\r\n")
        .await
        .unwrap();

    let mut buf = [0u8; 1024];
    let n = stream.read(&mut buf).await.unwrap();
    let response = String::from_utf8_lossy(&buf[..n]);
    assert!(
        response.contains("200 Connection Established"),
        "Proxy did not accept CONNECT"
    );

    // 4. Send TLS ClientHello (Client Hello is 0x16 ...)
    let client_hello_prefix = [0x16, 0x03, 0x01];
    stream.write_all(&client_hello_prefix).await.unwrap();

    // Give it a moment to panic
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Check if child is still running
    match child.try_wait() {
        Ok(Some(status)) => {
            panic!(
                "Proxy process exited unexpectedly (likely panicked): {}",
                status
            );
        }
        Ok(None) => {
            // Still running, that's good!
        }
        Err(e) => panic!("Error waiting on child: {}", e),
    }

    let _ = child.kill();
}
