use super::*;

fn bytes(s: &str) -> TailRead {
    TailRead::Bytes(s.as_bytes().to_vec())
}

#[test]
fn a_line_split_across_reads_comes_out_once_whole() {
    let mut t = TranscriptTail::new();
    assert_eq!(t.take(bytes("{\"a\":1}\n{\"b\"")), vec!["{\"a\":1}"]);
    assert_eq!(t.offset(), 12);
    assert_eq!(t.range(), format!("bytes=12-{}", 12 + CHUNK_BYTES - 1));
    assert_eq!(t.take(bytes(":2}\r\n\n{\"c\":3}\n")), vec!["{\"b\":2}", "{\"c\":3}"]);
    assert_eq!(t.take(bytes("")), Vec::<String>::new());
}

#[test]
fn a_shrunk_file_starts_over_from_its_first_byte() {
    let mut t = TranscriptTail::new();
    t.take(bytes("one\ntw"));
    assert_eq!(t.take(TailRead::Shrunk), Vec::<String>::new());
    assert_eq!((t.offset(), t.restarts()), (0, 1));
    assert_eq!(t.take(bytes("new\n")), vec!["new"], "the old partial line is gone");
}

#[test]
fn a_missing_file_keeps_the_tail_as_it_was() {
    let mut t = TranscriptTail::new();
    t.take(bytes("x\n"));
    assert!(t.take(TailRead::Missing).is_empty());
    assert_eq!(t.offset(), 2);
}

#[test]
fn an_overlong_line_is_dropped_whole_and_the_next_one_reads() {
    let mut t = TranscriptTail::new();
    let long = "x".repeat(MAX_LINE_BYTES + 10);
    assert!(t.take(TailRead::Bytes(long.into_bytes())).is_empty());
    assert!(t.partial.is_empty(), "nothing of it is held");
    assert_eq!(t.take(bytes("tail\nnext\n")), vec!["next"]);
}

#[test]
fn an_overlong_line_in_one_read_is_dropped_too() {
    let mut t = TranscriptTail::new();
    let mut read = b"before\n".to_vec();
    read.extend(std::iter::repeat_n(b'x', MAX_LINE_BYTES + 1));
    read.extend_from_slice(b"\nafter\n");
    assert_eq!(t.take(TailRead::Bytes(read)), vec!["before", "after"]);
    // A line that grows past the limit over several reads, each under it.
    let half = "y".repeat(MAX_LINE_BYTES / 2 + 1);
    assert!(t.take(bytes(&half)).is_empty());
    assert!(t.take(bytes(&half)).is_empty());
    assert!(t.partial.is_empty());
    assert_eq!(t.take(bytes("y\nlast\n")), vec!["last"]);
}

#[test]
fn http_answers_map_to_reads() {
    let at = |start, size| Some(ContentRange { start, size });
    assert_eq!(classify(206, b"ab".to_vec(), 5, at(Some(5), Some(7))), Some(bytes("ab")));
    assert_eq!(classify(206, b"ab".to_vec(), 5, None), Some(bytes("ab")));
    assert_eq!(classify(206, b"ab".to_vec(), 5, at(Some(0), Some(7))), None, "not the bytes asked");
    assert_eq!(classify(200, b"hello world".to_vec(), 6, None), Some(bytes("world")));
    assert_eq!(classify(200, b"hi".to_vec(), 6, None), Some(TailRead::Shrunk));
    assert_eq!(classify(416, Vec::new(), 6, at(None, Some(6))), Some(bytes("")));
    assert_eq!(classify(416, Vec::new(), 6, at(None, Some(3))), Some(TailRead::Shrunk));
    assert_eq!(classify(404, Vec::new(), 0, None), Some(TailRead::Missing));
    assert_eq!(classify(502, Vec::new(), 0, None), None);
    assert_eq!(ContentRange::parse("bytes */120"), at(None, Some(120)));
    assert_eq!(ContentRange::parse("bytes 3-9/120"), at(Some(3), Some(120)));
    assert_eq!(ContentRange::parse("bytes 0-9/*"), at(Some(0), None));
    assert_eq!(ContentRange::parse("items 0-9/10"), None);
}

type Reply = (u16, Vec<(&'static str, String)>, Vec<u8>);

/// One local HTTP server that answers `answers` in order, recording each request's `Range`.
async fn server(answers: Vec<Reply>) -> (reqwest::Url, tokio::task::JoinHandle<Vec<String>>) {
    crate::test_tls();
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let url =
        reqwest::Url::parse(&format!("http://{addr}/v1/vms/vm_x/files/content?path=/t.jsonl"))
            .unwrap();
    let task = tokio::spawn(async move {
        let mut ranges = Vec::new();
        for (status, headers, body) in answers {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buf = [0u8; 4096];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = socket.read(&mut buf).await.unwrap();
                assert!(n > 0, "the client closed before its headers ended");
                request.extend_from_slice(&buf[..n]);
            }
            let text = String::from_utf8_lossy(&request).to_ascii_lowercase();
            let range = text.lines().find_map(|l| l.strip_prefix("range: ")).unwrap_or("");
            ranges.push(range.to_string());
            let mut head = format!(
                "HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n",
                body.len()
            );
            for (k, v) in headers {
                head.push_str(&format!("{k}: {v}\r\n"));
            }
            head.push_str("\r\n");
            socket.write_all(head.as_bytes()).await.unwrap();
            socket.write_all(&body).await.unwrap();
        }
        ranges
    });
    (url, task)
}

fn cr(value: &str) -> Vec<(&'static str, String)> {
    vec![("content-range", value.to_string())]
}

#[tokio::test]
async fn reads_ask_only_for_the_bytes_after_the_last_one() {
    let (url, server) = server(vec![
        (206, cr("bytes 0-9/10"), b"one\ntwo\nth".to_vec()),
        (416, cr("bytes */10"), Vec::new()),
        (206, cr("bytes 10-13/14"), b"ree\n".to_vec()),
        (416, cr("bytes */4"), Vec::new()),
        (206, cr("bytes 0-3/4"), b"new\n".to_vec()),
        // A 416 that names no size: the read asks for byte 0 to tell no-news from shrunk.
        (416, vec![], Vec::new()),
        (206, cr("bytes 0-0/4"), b"n".to_vec()),
    ])
    .await;
    let http = reqwest::Client::new();
    let mut tail = TranscriptTail::with_chunk(100);
    assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["one", "two"]);
    assert!(read_next(&http, url.clone(), &mut tail).await.unwrap().is_empty());
    assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["three"]);
    // The file was replaced by a shorter one: read again from its start in the same call.
    assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["new"]);
    assert_eq!(tail.restarts(), 1);
    assert!(read_next(&http, url.clone(), &mut tail).await.unwrap().is_empty());
    assert_eq!((tail.offset(), tail.restarts()), (4, 1));
    assert_eq!(
        server.await.unwrap(),
        vec![
            "bytes=0-99",
            "bytes=10-109",
            "bytes=10-109",
            "bytes=14-113",
            "bytes=0-99",
            "bytes=4-103",
            "bytes=0-0"
        ]
    );
}

#[tokio::test]
async fn a_long_file_is_read_in_chunks_up_to_the_per_read_cap() {
    let mut answers: Vec<Reply> = Vec::new();
    for i in 0..CHUNKS_PER_READ {
        answers.push((206, cr(&format!("bytes {}-{}/*", i * 4, i * 4 + 3)), b"abc\n".to_vec()));
    }
    answers.push((
        206,
        cr(&format!("bytes {}-{}/*", CHUNKS_PER_READ * 4, CHUNKS_PER_READ * 4 + 1)),
        b"z\n".to_vec(),
    ));
    let (url, server) = server(answers).await;
    let http = reqwest::Client::new();
    let mut tail = TranscriptTail::with_chunk(4);
    let first = read_next(&http, url.clone(), &mut tail).await.unwrap();
    assert_eq!(first.len(), CHUNKS_PER_READ);
    assert!(tail.more(), "stopped at the cap with bytes left");
    assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["z"]);
    assert!(!tail.more());
    let ranges = server.await.unwrap();
    assert_eq!(ranges.len(), CHUNKS_PER_READ + 1);
    assert_eq!(ranges[1], "bytes=4-7");
}

/// RED before the fix: a failed later chunk returned the error and dropped the lines the
/// earlier chunks had completed, while the offset already stood past them, so they were lost.
#[tokio::test]
async fn a_failed_later_chunk_keeps_the_lines_already_read() {
    let answers: Vec<Reply> = vec![
        (206, cr("bytes 0-3/*"), b"abc\n".to_vec()),
        (502, Vec::new(), Vec::new()),
        (206, cr("bytes 4-5/*"), b"z\n".to_vec()),
    ];
    let (url, server) = server(answers).await;
    let http = reqwest::Client::new();
    let mut tail = TranscriptTail::with_chunk(4);
    let first = read_next(&http, url.clone(), &mut tail).await.unwrap();
    assert_eq!(first, vec!["abc"], "the first chunk's line is delivered");
    assert_eq!(tail.offset(), 4);
    assert!(tail.more(), "the caller reads again for the bytes after the failure");
    assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["z"]);
    let ranges = server.await.unwrap();
    assert_eq!(ranges, vec!["bytes=0-3", "bytes=4-7", "bytes=4-7"]);
}

#[tokio::test]
async fn a_first_chunk_that_fails_is_an_error() {
    let (url, server) = server(vec![(502, Vec::new(), Vec::new())]).await;
    let http = reqwest::Client::new();
    let mut tail = TranscriptTail::with_chunk(4);
    assert!(matches!(read_next(&http, url, &mut tail).await, Err(TailError::Status(502))));
    assert_eq!(tail.offset(), 0);
    server.await.unwrap();
}
