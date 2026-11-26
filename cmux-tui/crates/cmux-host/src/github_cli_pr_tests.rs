use super::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

fn defaults() -> PrDefaults<'static> {
    PrDefaults {
        repo: &|| Some("acme/widgets".into()),
        head: &|| Some("lane/fix".into()),
        base: &|| Some("main".into()),
        read_file: &|p| {
            if p == "body.md" { Ok("from file".into()) } else { Err(format!("{p}: missing")) }
        },
    }
}

/// What the fake edge saw: method, path, headers (lowercased names) and body.
#[derive(Debug)]
struct Seen {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Value,
}

/// A one-request HTTP server standing in for platform.cmux.internal.
fn fake_edge(status: u16, reply: Value) -> (String, mpsc::Receiver<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let mut parts = line.split_whitespace();
        let method = parts.next().unwrap().to_owned();
        let path = parts.next().unwrap().to_owned();
        let mut headers = Vec::new();
        let mut length = 0;
        loop {
            let mut h = String::new();
            reader.read_line(&mut h).unwrap();
            let h = h.trim_end();
            if h.is_empty() {
                break;
            }
            let (k, v) = h.split_once(':').unwrap();
            let (k, v) = (k.trim().to_ascii_lowercase(), v.trim().to_owned());
            if k == "content-length" {
                length = v.parse().unwrap();
            }
            headers.push((k, v));
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        let body = serde_json::from_slice(&body).unwrap_or(Value::Null);
        tx.send(Seen { method, path, headers, body }).unwrap();
        let text = reply.to_string();
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
            text.len()
        )
        .unwrap();
    });
    (origin, rx)
}

fn http_send(
    poster: &JsonPoster,
) -> impl Fn(&str, &str, Option<&Value>) -> Result<(u16, Value), String> + '_ {
    move |m, u, b| poster.send(m, u, b, None)
}

#[test]
fn create_posts_githubs_create_pr_body_to_the_edge_route_and_prints_the_url() {
    let (origin, seen) = fake_edge(
        201,
        json!({ "number": 7, "html_url": "https://github.com/acme/widgets/pull/7" }),
    );
    let poster = JsonPoster::allowing_http().unwrap();
    let out = run_with(
        &s(&["create", "--title", "Fix it", "--body", "why", "--base", "dev", "--draft"]),
        &defaults(),
        &origin,
        &http_send(&poster),
    )
    .unwrap();
    assert_eq!(out, "https://github.com/acme/widgets/pull/7");
    let seen = seen.recv().unwrap();
    assert_eq!(seen.method, "POST");
    assert_eq!(seen.path, "/v1/cloud/github/api/repos/acme/widgets/pulls");
    assert_eq!(
        seen.body,
        json!({ "title": "Fix it", "head": "lane/fix", "base": "dev", "body": "why", "draft": true })
    );
    // The guest sends no credential: the edge adds the machine's own.
    for (k, _) in &seen.headers {
        assert!(
            !matches!(k.as_str(), "authorization" | "x-cmux-machine-authorization" | "cookie"),
            "{k}"
        );
    }
}

#[test]
fn create_says_what_github_refused() {
    let (origin, _seen) = fake_edge(
        422,
        json!({ "message": "Validation Failed", "errors": [{ "message": "A pull request already exists for acme:lane/fix." }] }),
    );
    let poster = JsonPoster::allowing_http().unwrap();
    let err = run_with(&s(&["create", "--title", "T"]), &defaults(), &origin, &http_send(&poster))
        .unwrap_err();
    assert_eq!(
        err,
        "GitHub answered 422: Validation Failed: A pull request already exists for acme:lane/fix."
    );
}

#[test]
fn create_says_when_the_platform_refused() {
    let (origin, _seen) = fake_edge(
        403,
        json!({ "ok": false, "error": { "code": "integration.not_installed", "message": "the cmux GitHub App is not on acme/widgets" } }),
    );
    let poster = JsonPoster::allowing_http().unwrap();
    let err = run_with(&s(&["create", "--title", "T"]), &defaults(), &origin, &http_send(&poster))
        .unwrap_err();
    assert!(
        err.starts_with("GitHub answered 403: the cmux GitHub App is not on acme/widgets"),
        "{err}"
    );
}

#[test]
fn view_and_comment_use_the_pulls_and_issues_routes() {
    let (origin, seen) = fake_edge(
        200,
        json!({ "title": "Fix it", "state": "closed", "merged_at": "2026-11-26T00:00:00Z", "html_url": "https://github.com/acme/widgets/pull/7" }),
    );
    let poster = JsonPoster::allowing_http().unwrap();
    let out = run_with(&s(&["view", "#7"]), &defaults(), &origin, &http_send(&poster)).unwrap();
    assert_eq!(out, "#7 merged Fix it\nhttps://github.com/acme/widgets/pull/7");
    let seen = seen.recv().unwrap();
    assert_eq!(
        (seen.method.as_str(), seen.path.as_str()),
        ("GET", "/v1/cloud/github/api/repos/acme/widgets/pulls/7")
    );

    let (origin, seen) = fake_edge(
        201,
        json!({ "html_url": "https://github.com/acme/widgets/pull/7#issuecomment-1" }),
    );
    let out = run_with(
        &s(&["comment", "7", "--body-file", "body.md", "--repo", "other/repo"]),
        &defaults(),
        &origin,
        &http_send(&poster),
    )
    .unwrap();
    assert_eq!(out, "https://github.com/acme/widgets/pull/7#issuecomment-1");
    let seen = seen.recv().unwrap();
    assert_eq!(seen.path, "/v1/cloud/github/api/repos/other/repo/issues/7/comments");
    assert_eq!(seen.body, json!({ "body": "from file" }));
}

#[test]
fn create_takes_gh_spellings_and_refuses_what_it_does_not_know() {
    let pr = parse_create(
        &s(&["-R", "https://github.com/a/b.git", "-H", "x", "-B=y", "--title=T", "-F", "body.md"]),
        &defaults(),
    );
    // `-B=y` is not gh's spelling; `--base=y` is.
    assert!(pr.is_err());
    let pr = parse_create(
        &s(&[
            "-R",
            "https://github.com/a/b.git",
            "-H",
            "x",
            "--base=y",
            "--title=T",
            "-F",
            "body.md",
        ]),
        &defaults(),
    )
    .unwrap();
    assert_eq!(
        pr,
        CreatePr {
            repo: "a/b".into(),
            head: "x".into(),
            base: "y".into(),
            title: "T".into(),
            body: "from file".into(),
            draft: false
        }
    );
    assert!(parse_create(&s(&["--fill"]), &defaults()).unwrap_err().contains("--fill"));
    assert_eq!(
        parse_create(&s(&["--body", "b"]), &defaults()).unwrap_err(),
        "pr create needs --title"
    );
    assert!(parse_create(&s(&["--title", "T", "-R", "gitlab.com/a/b"]), &defaults()).is_err());
}

#[test]
fn gh_pr_create_maps_only_when_every_flag_is_known() {
    assert_eq!(
        from_gh(&s(&["pr", "create", "--title", "T", "--body", "B"])),
        Some(s(&["create", "--title", "T", "--body", "B"]))
    );
    assert_eq!(from_gh(&s(&["pr", "create", "--fill"])), None);
    assert_eq!(from_gh(&s(&["pr", "view", "7"])), None);
    assert_eq!(from_gh(&s(&["pr", "create", "--web", "--title", "T"])), None);
}

#[test]
fn numbers_must_be_numbers() {
    assert!(parse_numbered("view", &s(&["abc"]), &defaults()).is_err());
    assert!(parse_numbered("view", &s(&[]), &defaults()).is_err());
    assert!(parse_numbered("comment", &s(&["3"]), &defaults()).unwrap_err().contains("--body"));
}
