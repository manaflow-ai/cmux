use super::*;
use tokio_tungstenite::tungstenite::Message as Frame;

fn line(bytes: usize) -> String {
    let rows: Vec<Value> = (0..bytes / 60)
        .map(|i| json!({"sessionId": format!("chat-{i}"), "status": "idle", "cwd": "/work"}))
        .collect();
    let mut line = json!({"jsonrpc": "2.0", "id": 1, "result": {"sessions": rows}}).to_string();
    line.push('\n');
    line
}

#[test]
fn only_an_initialize_that_lists_zlib_asks_for_it() {
    let ask = |meta: Value| offered(Some(&json!({"protocolVersion": 1, "_meta": meta})));
    assert!(ask(json!({"acpmux": {"compression": offer()}})));
    assert!(ask(json!({"acpmux": {"compression": ["zstd", "zlib"]}})));
    assert!(!ask(json!({"acpmux": {"compression": ["zstd"]}})));
    assert!(!ask(json!({"acpmux": {"compression": "zlib"}})));
    assert!(!ask(json!({"acpmux": {"githubBroker": true}})));
    assert!(!offered(None));
}

#[tokio::test]
async fn a_large_line_goes_as_zlib_only_once_asked_and_a_small_one_stays_text() {
    let wire = Wire::default();
    let big = line(MIN_BYTES * 4);
    let Some(Frame::Text(text)) = wire.frame(big.clone()).await else {
        panic!("not asked: Text");
    };
    assert_eq!(text.as_str(), big.trim_end());
    wire.enable();
    let Some(Frame::Binary(bytes)) = wire.frame(big.clone()).await else {
        panic!("asked: Binary");
    };
    assert!(bytes.len() * 4 < big.len(), "{} of {}", bytes.len(), big.len());
    assert_eq!(inflate(&bytes, big.len()).unwrap(), big.trim_end());
    let small = line(MIN_BYTES / 2);
    assert!(matches!(wire.frame(small).await, Some(Frame::Text(_))));
}

#[tokio::test]
async fn a_line_past_the_blocking_size_is_compressed_whole() {
    let wire = Wire::default();
    wire.enable();
    let big = line(BLOCKING_BYTES * 3);
    let Some(Frame::Binary(bytes)) = wire.frame(big.clone()).await else {
        panic!("asked: Binary");
    };
    assert_eq!(inflate(&bytes, big.len()).unwrap(), big.trim_end());
}

#[test]
fn a_frame_that_inflates_past_the_limit_or_is_not_zlib_text_is_refused() {
    let text = "x".repeat(1 << 20);
    let bytes = deflate(text.as_bytes());
    assert!(bytes.len() < 8 << 10, "a bomb is small: {}", bytes.len());
    assert_eq!(inflate(&bytes, text.len()).unwrap(), text);
    let past = inflate(&bytes, text.len() - 1).unwrap_err();
    assert!(past.contains("inflates past"), "{past}");
    assert!(inflate(b"{\"not\": \"zlib\"}", 1 << 20).is_err());
    assert!(inflate(&deflate(&[0xff, 0xfe, 0x00]), 1 << 20).unwrap_err().contains("UTF-8"));
}
