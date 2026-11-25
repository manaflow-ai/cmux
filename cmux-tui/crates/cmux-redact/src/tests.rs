//! The corpus is fake: every token is assembled at run time, so no file in the tree holds a string
//! a secret scanner would flag.

use super::*;

fn body(n: usize) -> String {
    "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS".chars().cycle().take(n).collect()
}

fn run(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    redact_stream(input, &mut out).expect("in-memory io");
    out
}

/// One JSONL transcript with a token of each family inside message text and a tool result.
fn transcript() -> (String, Vec<String>) {
    let github = format!("gh{}_{}", "p", body(36));
    let anthropic = format!("sk-ant-api03-{}AA", body(93));
    let aws = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let pem_body = body(64);
    let pem = format!(
        "-----BEGIN RSA PRIVATE KEY-----\\n{pem_body}\\n{pem_body}\\n-----END RSA PRIVATE KEY-----"
    );
    let url = format!("postgres://app:{}@db.internal:5432/main", "hunter2Xk9Qz");
    let text = [
        format!(r#"{{"type":"user","message":{{"content":"export GITHUB_TOKEN={github} then run it"}}}}"#),
        format!(r#"{{"type":"tool_result","content":"ANTHROPIC key {anthropic} and {aws}"}}"#),
        format!(r#"{{"type":"tool_result","content":"{pem}"}}"#),
        format!(r#"{{"type":"assistant","message":{{"content":"connect with {url}"}}}}"#),
        r#"{"type":"assistant","message":{"content":"plain text, commit 3f2a9c1d0e4b5a6978c1d2e3f4a5b6c7d8e9f001"}}"#.to_string(),
    ];
    (text.join("\n") + "\n", vec![github, anthropic, aws, pem_body, "hunter2Xk9Qz".to_string()])
}

#[test]
fn token_shapes_are_masked_and_json_stays_valid() {
    let (input, secrets) = transcript();
    let out = String::from_utf8(run(input.as_bytes())).expect("utf-8");
    for secret in &secrets {
        assert!(!out.contains(secret.as_str()), "a secret survives: {out}");
    }
    assert_eq!(out.lines().count(), input.lines().count(), "line structure is kept");
    for line in out.lines() {
        serde_json::from_str::<serde_json::Value>(line).unwrap_or_else(|e| panic!("{e}: {line}"));
    }
}

#[test]
fn ordinary_text_passes_unchanged() {
    let input = "{\"type\":\"assistant\",\"message\":{\"content\":\"commit 3f2a9c1d0e4b5a6978c1d2e3f4a5b6c7d8e9f001 fixed /src/main.rs\"}}\n\n";
    assert_eq!(run(input.as_bytes()), input.as_bytes());
}

#[test]
fn a_last_line_without_newline_is_still_scanned() {
    let github = format!("gh{}_{}", "p", body(36));
    let out = run(format!("export GITHUB_TOKEN={github}").as_bytes());
    assert!(!String::from_utf8(out).expect("utf-8").contains(&github));
}

#[test]
fn invalid_utf8_is_read_lossily_not_passed_through() {
    let github = format!("gh{}_{}", "p", body(36));
    let mut input = b"\xff\xfe bad bytes ".to_vec();
    input.extend_from_slice(format!("token {github}\n").as_bytes());
    let out = run(&input);
    assert!(!String::from_utf8_lossy(&out).contains(&github));
}

/// `cargo test -p cmux-redact --release -- --ignored --nocapture throughput`
#[test]
#[ignore = "a measurement, not a check"]
fn throughput() {
    let (one, _) = transcript();
    // A realistic mix: mostly long lines of prose and code with a token every few hundred lines.
    let prose = format!(
        r#"{{"type":"assistant","message":{{"content":"{}"}}}}"#,
        "Reading src/server/machines/CloudCarrier.ts and running the targeted tests; the fork path keeps its own state. ".repeat(12)
    );
    let mut data = String::new();
    let mut i = 0;
    while data.len() < 64 * 1024 * 1024 {
        data.push_str(&prose);
        data.push('\n');
        i += 1;
        if i % 400 == 0 {
            data.push_str(&one);
        }
    }
    let start = std::time::Instant::now();
    let out = run(data.as_bytes());
    let secs = start.elapsed().as_secs_f64();
    eprintln!(
        "redacted {:.1} MB in {secs:.2}s = {:.1} MB/s",
        data.len() as f64 / 1e6,
        data.len() as f64 / 1e6 / secs
    );
    assert!(out.len() < data.len() + 1024 * 1024);
}
