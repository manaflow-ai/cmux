use std::io::{BufRead, BufReader, Write};
use std::sync::{Arc, Mutex};

use super::*;

const GOOD: &str = "sk-proj-GOODKEY123456";

#[test]
fn key_check_strips_every_space_a_paste_adds() {
    assert_eq!(without_whitespace("  sk-proj-ab\ncd \t ef\r\n"), "sk-proj-abcdef");
    assert_eq!(
        without_whitespace("\u{FEFF}sk-ant-\u{200B}api03-x\u{2060}y\u{00A0}z"),
        "sk-ant-api03-xyz"
    );
    assert_eq!(without_whitespace("AIzaSyAbc"), "AIzaSyAbc");
}

#[test]
fn key_check_knows_each_providers_shape() {
    assert!(shape_ok("openai", "sk-proj-abcdef"));
    assert!(shape_ok("anthropic", "sk-ant-api03-abcdef"));
    assert!(!shape_ok("anthropic", "sk-proj-abcdef"));
    assert!(shape_ok("openrouter", "sk-or-v1-abcdef"));
    assert!(!shape_ok("openrouter", "sk-abcdefgh"));
    assert!(shape_ok("google", "AIzaSyAbcdef"));
    assert!(!shape_ok("google", "sk-abcdefgh"));
    assert!(shape_ok("xai", "xai-abcdefgh"));
    assert!(!shape_ok("openai", "sk-"));
    assert!(!shape_ok("openai", "sk-ab cdefgh"));
    // An unknown provider: any one printable word.
    assert!(shape_ok("someone", "whatever-key"));
    assert!(!shape_ok("someone", ""));
    assert_eq!(Verdict::BadKey(401).sentence("openai").as_deref(), Some("Key rejected by OpenAI"));
    assert_eq!(
        Verdict::BadShape.sentence("anthropic").as_deref(),
        Some("Not a key from Anthropic: Anthropic keys start with sk-ant-")
    );
    assert_eq!(Verdict::Unreachable("x".into()).sentence("openai"), None);
}

/// A fake provider on 127.0.0.1 answering STATUS for any key but one holding `GOODKEY` (200);
/// the request lines and auth header names it saw.
fn fake(status: &'static str, seen: Arc<Mutex<Vec<String>>>) -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            let _ = reader.read_line(&mut line);
            seen.lock().unwrap().push(line.trim_end().to_owned());
            let mut good = false;
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).is_err() || header.trim_end().is_empty() {
                    break;
                }
                if let Some((name, value)) = header.trim_end().split_once(':') {
                    let name = name.trim().to_ascii_lowercase();
                    if matches!(name.as_str(), "authorization" | "x-api-key" | "x-goog-api-key") {
                        good |= value.contains("GOODKEY");
                        seen.lock().unwrap().push(name);
                    }
                }
            }
            let status = if good { "200 OK" } else { status };
            let body = "{}";
            let mut stream = stream;
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    format!("http://127.0.0.1:{port}")
}

#[tokio::test(flavor = "multi_thread")]
async fn key_check_asks_the_provider_and_reads_its_answer() {
    let t = Duration::from_secs(5);
    let seen = Arc::new(Mutex::new(Vec::new()));
    let base = fake("401 Unauthorized", seen.clone());
    assert_eq!(check("openai", GOOD, Some(&base), t).await, Verdict::Ok);
    assert_eq!(check("openai", "sk-proj-WRONG12345", Some(&base), t).await, Verdict::BadKey(401));
    assert_eq!(check("anthropic", "sk-ant-api03-GOODKEY1", Some(&base), t).await, Verdict::Ok);
    assert_eq!(check("openrouter", "sk-or-v1-nope123", Some(&base), t).await, Verdict::BadKey(401));
    let lines = seen.lock().unwrap().clone();
    assert!(lines.contains(&"GET /v1/models HTTP/1.1".to_owned()), "{lines:?}");
    assert!(lines.iter().any(|l| l.starts_with("GET /v1/models?limit=1")), "{lines:?}");
    assert!(lines.iter().any(|l| l.starts_with("GET /api/v1/key")), "{lines:?}");
    assert!(lines.contains(&"x-api-key".to_owned()), "{lines:?}");
    // Google's and xAI's 400 for an unknown key is a refusal; another provider's is not.
    let base = fake("400 Bad Request", Arc::default());
    assert_eq!(check("google", "AIzaSyWRONG12", Some(&base), t).await, Verdict::BadKey(400));
    assert_eq!(check("xai", "xai-WRONG12345", Some(&base), t).await, Verdict::BadKey(400));
    assert!(matches!(
        check("openai", "sk-proj-WRONG12345", Some(&base), t).await,
        Verdict::Unreachable(_)
    ));
}

#[tokio::test(flavor = "multi_thread")]
async fn key_check_never_blocks_saving_when_the_provider_is_away() {
    let t = Duration::from_secs(5);
    // A 5xx and a closed port: unreachable, which saves.
    let base = fake("503 Service Unavailable", Arc::default());
    let v = check("openai", "sk-proj-WRONG12345", Some(&base), t).await;
    assert!(matches!(v, Verdict::Unreachable(_)) && !v.rejects(), "{v:?}");
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let closed_base = format!("http://127.0.0.1:{closed}");
    let v = check("openai", "sk-proj-WRONG12345", Some(&closed_base), t).await;
    assert!(matches!(&v, Verdict::Unreachable(why) if !why.contains("WRONG")), "{v:?}");
    // A listener that never answers: unreachable within the timeout.
    let silent = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let silent_base = format!("http://{}", silent.local_addr().unwrap());
    let started = std::time::Instant::now();
    let v =
        check("openai", "sk-proj-WRONG12345", Some(&silent_base), Duration::from_millis(500)).await;
    assert!(matches!(v, Verdict::Unreachable(_)), "{v:?}");
    assert!(started.elapsed() < Duration::from_secs(4));
    drop(silent);
    // A wrong shape is refused without a request.
    assert_eq!(
        check("anthropic", "sk-proj-abcdef", Some("http://127.0.0.1:1"), t).await,
        Verdict::BadShape
    );
    // An unknown provider with no base: nothing to ask, save.
    assert!(matches!(check("someone", "whatever-key", None, t).await, Verdict::Unreachable(_)));
}
