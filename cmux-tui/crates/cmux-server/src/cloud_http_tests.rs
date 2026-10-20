use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant};

use super::JsonPoster;
use serde_json::json;

fn server(response: Vec<u8>) -> (String, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    let task = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut request = Vec::new();
        let mut byte = [0u8; 1];
        while !request.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
        }
        let _ = stream.write_all(&response);
        String::from_utf8(request).unwrap()
    });
    (url, task)
}

#[test]
fn vm_receiver_client_http_never_redirects_bearer() {
    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    target.set_nonblocking(true).unwrap();
    let (url,task)=server(format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{}/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",target.local_addr().unwrap()).into_bytes());
    let http = JsonPoster::allowing_http().unwrap();
    let (status, _) = http
        .request_until(
            &url,
            Some(&json!({})),
            Some("private-test-bearer"),
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap();
    assert_eq!(status, 307);
    assert_eq!(target.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
    assert!(
        task.join()
            .unwrap()
            .to_ascii_lowercase()
            .contains("authorization: bearer private-test-bearer")
    );
}

#[test]
fn vm_receiver_client_http_limits_body_with_and_without_content_length() {
    for length in [true, false] {
        let header = if length { "Content-Length: 1048577\r\n" } else { "" };
        let mut response =
            format!("HTTP/1.1 200 OK\r\n{header}Connection: close\r\n\r\n").into_bytes();
        response.extend(vec![b'x'; 1048577]);
        let (url, task) = server(response);
        assert!(
            JsonPoster::allowing_http()
                .unwrap()
                .request_until(&url, None, None, Instant::now() + Duration::from_secs(1))
                .is_err()
        );
        assert!(task.join().unwrap().starts_with("GET /test "));
    }
}

#[test]
fn vm_receiver_client_http_deadline_covers_stalled_response_body() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    let (release, held) = std::sync::mpsc::channel::<()>();
    let task = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{").unwrap();
        let _ = held.recv_timeout(Duration::from_secs(2));
    });
    let http = JsonPoster::allowing_http().unwrap();
    let started = Instant::now();
    assert!(http.request_until(&url, None, None, started + Duration::from_millis(200)).is_err());
    let _ = release.send(());
    task.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn vm_receiver_client_http_refuses_get_credentials_before_io() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    assert!(
        JsonPoster::allowing_http()
            .unwrap()
            .request_until(
                &url,
                None,
                Some("private-test-bearer"),
                Instant::now() + Duration::from_secs(1)
            )
            .is_err()
    );
    assert_eq!(listener.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
}
