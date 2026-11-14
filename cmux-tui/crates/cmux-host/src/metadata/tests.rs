use super::*;
use std::net::TcpListener;
use std::thread;

#[test]
fn mmds_client_does_the_token_dance() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let mut seen = Vec::new();
        for reply in ["tok-1", "vm-42"] {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = [0u8; 2048];
            let n = s.read(&mut buf).unwrap();
            seen.push(String::from_utf8_lossy(&buf[..n]).into_owned());
            let resp = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{reply}", reply.len());
            s.write_all(resp.as_bytes()).unwrap();
        }
        seen
    });
    let mut mmds = Mmds { addr, timeout: Duration::from_secs(2) };
    assert_eq!(mmds.fetch_once().unwrap(), "vm-42");
    let seen = server.join().unwrap();
    assert!(seen[0].starts_with("PUT /latest/api/token "));
    assert!(seen[0].contains("X-metadata-token-ttl-seconds: 60"));
    assert!(seen[1].starts_with("GET /latest/meta-data/instance-id "));
    assert!(seen[1].contains("X-aws-ec2-metadata-token: tok-1"));
}
