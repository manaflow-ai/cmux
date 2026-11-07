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

#[test]
fn vm_receiver_client_http_errors_do_not_echo_rejected_urls() {
    let url = "http://private-test-bearer@127.0.0.1/private-policy";
    let error = JsonPoster::allowing_http()
        .unwrap()
        .request_until(url, None, None, Instant::now() + Duration::from_secs(1))
        .unwrap_err();
    assert!(!error.contains(url) && !error.contains("private-test-bearer"));
}

#[test]
fn vm_receiver_client_http_can_retry_after_cancelling_a_body() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    let (release, held) = std::sync::mpsc::channel::<()>();
    let stalled = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{").unwrap();
        let _ = held.recv_timeout(Duration::from_secs(2));
    });
    let http = JsonPoster::allowing_http().unwrap();
    let answer = http.request_until(&url, None, None, Instant::now() + Duration::from_millis(200));
    let _ = release.send(());
    stalled.join().unwrap();
    assert!(answer.is_err());
    let (url, ready) = server(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".to_vec());
    let (status, bytes) =
        http.request_until(&url, None, None, Instant::now() + Duration::from_secs(1)).unwrap();
    ready.join().unwrap();
    assert_eq!(status, 200);
    assert_eq!(bytes, b"{}");
}

#[tokio::test]
async fn vm_receiver_client_http_from_a_blocking_executor_thread() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let url = format!("http://{address}/test");
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
        let mut headers = Vec::new();
        let mut byte = [0; 1];
        while !headers.ends_with(b"\r\n\r\n") && headers.len() < 8192 {
            if stream.read(&mut byte).ok() != Some(1) {
                return;
            }
            headers.push(byte[0]);
        }
        let _ = stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
    });
    let answer = tokio::task::spawn_blocking(move || {
        JsonPoster::allowing_http().unwrap().request_until(
            &url,
            None,
            None,
            Instant::now() + Duration::from_secs(3),
        )
    })
    .await;
    // Also unblock accept if the client refused before connecting. Both owned
    // threads finish before the test reports the behavioral failure.
    let _ = std::net::TcpStream::connect(address);
    server.join().unwrap();
    let (status, bytes) = answer.unwrap().expect("HTTP refused a blocking executor thread");
    assert_eq!(status, 200);
    assert_eq!(bytes, b"{}");
}

#[test]
fn a_reset_drops_the_pooled_connection() {
    // After a pause the pooled connection is dead and nothing says so: a request on it hangs to its 20 s bound.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    let accepted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = accepted.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            // Keep-alive: answer each request on the connection until it closes.
            std::thread::spawn(move || {
                let mut request = Vec::new();
                let mut byte = [0u8; 1];
                while stream.read_exact(&mut byte).is_ok() {
                    request.push(byte[0]);
                    if request.ends_with(b"\r\n\r\n") {
                        request.clear();
                        let ok = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
                        if stream.write_all(ok).is_err() {
                            return;
                        }
                    }
                }
            });
        }
    });
    let http = JsonPoster::allowing_http().unwrap();
    let get = || http.request_until(&url, None, None, Instant::now() + Duration::from_secs(2));
    assert_eq!(get().unwrap().0, 200);
    assert_eq!(get().unwrap().0, 200);
    let dials = || accepted.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(dials(), 1, "the pool reuses its connection");
    http.reset();
    assert_eq!(get().unwrap().0, 200);
    assert_eq!(dials(), 2, "after a reset the next request dials a fresh connection");
}

#[test]
fn an_address_change_fails_the_request_in_flight_and_drops_the_pool() {
    // A late network attach can leave a connection dead with nothing saying so: the request fails at once instead of
    // at its 20 s bound, and the retry dials a fresh connection.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    let accepted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = accepted.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let dial = counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            std::thread::spawn(move || {
                let mut request = Vec::new();
                let mut byte = [0u8; 1];
                while stream.read_exact(&mut byte).is_ok() {
                    request.push(byte[0]);
                    if request.ends_with(b"\r\n\r\n") {
                        request.clear();
                        let ok = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
                        if stream.write_all(ok).is_err() {
                            return;
                        }
                        // The first connection answers once, then goes silent like a dead route.
                        if dial == 0 {
                            let _ = stream.read_to_end(&mut Vec::new());
                            return;
                        }
                    }
                }
            });
        }
    });
    let network = tokio::sync::watch::Sender::new(0u64);
    let http = JsonPoster::allowing_http_on(&network).unwrap();
    let get = || http.request_until(&url, None, None, Instant::now() + Duration::from_secs(10));
    assert_eq!(get().unwrap().0, 200);
    let change = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        network.send_modify(|changes| *changes += 1);
        network
    });
    let started = Instant::now();
    assert!(get().is_err(), "the pooled connection is silent");
    let _network = change.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(5), "the change failed the request at once");
    assert_eq!(get().unwrap().0, 200);
    assert_eq!(
        accepted.load(std::sync::atomic::Ordering::SeqCst),
        2,
        "the retry dialed a fresh connection"
    );
}

#[test]
fn an_address_change_between_requests_drops_the_pool() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/test", listener.local_addr().unwrap());
    let accepted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = accepted.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            std::thread::spawn(move || {
                let mut request = Vec::new();
                let mut byte = [0u8; 1];
                while stream.read_exact(&mut byte).is_ok() {
                    request.push(byte[0]);
                    if request.ends_with(b"\r\n\r\n") {
                        request.clear();
                        let ok = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
                        if stream.write_all(ok).is_err() {
                            return;
                        }
                    }
                }
            });
        }
    });
    let network = tokio::sync::watch::Sender::new(0u64);
    let http = JsonPoster::allowing_http_on(&network).unwrap();
    let get = || http.request_until(&url, None, None, Instant::now() + Duration::from_secs(2));
    assert_eq!(get().unwrap().0, 200);
    network.send_modify(|changes| *changes += 1);
    assert_eq!(get().unwrap().0, 200);
    assert_eq!(
        accepted.load(std::sync::atomic::Ordering::SeqCst),
        2,
        "the change dropped the pooled connection"
    );
}
