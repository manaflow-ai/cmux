use std::net::TcpListener;

use super::*;

fn ports(text: &str) -> Vec<(u16, String, String)> {
    candidates(text).into_iter().map(|c| (c.port, c.host, c.url)).collect()
}

#[test]
fn terminal_ports_finds_dev_server_lines() {
    let text = "\
  VITE v6.0.0  ready in 310 ms\n\
  ➜  Local:   http://localhost:5173/\n\
  ➜  Network: http://192.168.1.20:5173/\n\
Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n\
serving /tmp/site on http://127.0.0.1:54663/ (pid 73602)\n\
Listening on [::1]:3001\n";
    assert_eq!(
        ports(text),
        vec![
            (3001, "[::1]".into(), "http://[::1]:3001/".into()),
            (54663, "127.0.0.1".into(), "http://127.0.0.1:54663/".into()),
            (8000, "0.0.0.0".into(), "http://0.0.0.0:8000/".into()),
            (5173, "localhost".into(), "http://localhost:5173/".into()),
        ],
        "loopback and wildcard only, newest first; the LAN address is not a loopback route"
    );
}

#[test]
fn terminal_ports_keeps_the_last_mention_and_path() {
    let text = "old http://localhost:3000/a\nnew https://LOCALHOST:3000/app?x=1 done\n";
    assert_eq!(
        ports(text),
        vec![(3000, "localhost".into(), "https://localhost:3000/app?x=1".into())]
    );
}

#[test]
fn terminal_ports_ignores_non_ports() {
    assert!(ports("localhost:0 localhost:99999 example.com:80 10.0.0.1:22 time 12:30").is_empty());
}

#[test]
fn terminal_ports_caps_candidates() {
    let text: String = (1..=100).map(|p| format!("http://localhost:{}/\n", 4000 + p)).collect();
    let found = candidates(&text);
    assert_eq!(found.len(), MAX_CANDIDATES);
    assert_eq!(found[0].port, 4100, "the newest mention first");
}

#[test]
fn terminal_ports_tail_cuts_on_a_char_boundary() {
    let text = "é".repeat(10);
    let cut = tail(&text, 5);
    assert!(cut.len() <= 5 && cut.chars().all(|c| c == 'é'));
    assert_eq!(tail("abc", 10), "abc");
}

#[test]
fn terminal_ports_reports_only_ports_that_accept() {
    let found = candidates("http://localhost:5173/ and http://127.0.0.1:9/\n");
    let reply = report_json(7, &found, |port| (port == 5173).then_some("127.0.0.1"));
    assert_eq!(
        reply,
        json!({
            "surface": 7,
            "listeners": [{"port": 5173, "host": "localhost", "url": "http://localhost:5173/", "bound": "127.0.0.1"}],
            "closed": [9],
        })
    );
}

#[test]
fn terminal_ports_probe_connects_to_loopback() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    assert_eq!(probe(port), Some("127.0.0.1"));
    drop(listener);
    assert_eq!(probe(port), None, "a closed port is not reported");
}
