use super::*;

/// One HTTP exchange against a loopback "GitHub": answers `status` and `body`, and hands back the
/// request it got (head and body).
async fn github(status: u16, body: &'static str) -> (String, tokio::task::JoinHandle<String>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        loop {
            let mut chunk = [0; 4096];
            let count = socket.read(&mut chunk).await.unwrap();
            assert!(count > 0);
            request.extend_from_slice(&chunk[..count]);
            if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&request[..end]).to_ascii_lowercase();
                let length: usize = head
                    .lines()
                    .find_map(|l| {
                        l.strip_prefix("content-length: ").map(|v| v.trim().parse().unwrap())
                    })
                    .unwrap_or(0);
                if request.len() >= end + 4 + length {
                    break;
                }
            }
        }
        let answer = format!(
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        );
        socket.write_all(answer.as_bytes()).await.unwrap();
        String::from_utf8_lossy(&request).into_owned()
    });
    (api, task)
}

fn plan_of(params: Value) -> Plan {
    rest::plan(&params).unwrap()
}

#[tokio::test]
async fn an_app_call_carries_its_token_its_body_and_githubs_headers() {
    let (api, request) = github(200, r#"{"merged":true}"#).await;
    let head = "c".repeat(40);
    let plan = plan_of(
        json!({"op": "pr.merge", "repo": "o/r", "number": 4, "head": head, "method": "squash"}),
    );
    let answer = http(&plan, &api, "ghs_test").await.unwrap();
    assert!(answer.ok);
    assert_eq!(answer.status, Some(200));
    let request = request.await.unwrap();
    assert!(request.starts_with("PUT /repos/o/r/pulls/4/merge "), "{request}");
    let lower = request.to_ascii_lowercase();
    assert!(lower.contains("authorization: bearer ghs_test"));
    assert!(lower.contains("x-github-api-version: 2022-11-28"));
    assert!(
        request.contains(&format!(r#""sha":"{head}""#))
            && request.contains(r#""merge_method":"squash""#)
    );
}

#[tokio::test]
async fn a_refusal_keeps_its_status_and_githubs_words() {
    let (api, _request) = github(405, r#"{"message":"Pull Request is not mergeable"}"#).await;
    let plan =
        plan_of(json!({"op": "pr.merge", "repo": "o/r", "number": 4, "head": "d".repeat(40)}));
    let reply =
        http(&plan, &api, "ghs_test").await.unwrap().reply(&Source::App("ghs_test".into(), 1));
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["status"], 405);
    assert_eq!(reply["source"], "app");
    assert_eq!(reply["message"], "Pull Request is not mergeable");
    assert!(!reply.to_string().contains("ghs_test"), "the token never goes back: {reply}");
}

#[tokio::test]
async fn a_graphql_answer_with_only_errors_is_not_ok() {
    let (api, _request) =
        github(200, r#"{"errors":[{"message":"Could not resolve to a Repository"}]}"#).await;
    let plan = plan_of(json!({"op": "graphql", "repo": "o/r", "query": "{ viewer { login } }"}));
    let answer = http(&plan, &api, "ghs_test").await.unwrap();
    assert!(!answer.ok);
    assert_eq!(answer.reply(&Source::Keyring)["message"], "Could not resolve to a Repository");
}

#[cfg(unix)]
fn fake_gh(dir: &std::path::Path, script: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("gh");
    std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_string_lossy().into_owned()
}

#[cfg(unix)]
#[tokio::test]
async fn signed_out_it_is_the_persons_gh_with_the_same_call() {
    let dir = tempfile::tempdir().unwrap();
    let seen = dir.path().join("seen");
    let gh = fake_gh(
        dir.path(),
        &format!(
            "printf '%s\\n' \"$@\" > '{}'; cat >> '{}'; printf '{{\"number\":3}}'",
            seen.display(),
            seen.display()
        ),
    );
    let head = "e".repeat(40);
    let params =
        json!({"op": "pr.merge", "repo": "o/r", "number": 3, "head": head, "method": "merge"});
    let reply = serve_at(params, &AppLease::default(), "http://127.0.0.1:9", &gh).await.unwrap();
    assert_eq!((reply["ok"].clone(), reply["source"].clone()), (json!(true), json!("keyring")));
    assert_eq!(reply["body"], r#"{"number":3}"#);
    let seen = std::fs::read_to_string(seen).unwrap();
    assert!(seen.starts_with("api\n--hostname\ngithub.com\n--method\nPUT\n"), "{seen}");
    assert!(seen.contains("repos/o/r/pulls/3/merge\n--input\n-\n"), "{seen}");
    assert!(seen.contains(&format!(r#""sha":"{head}""#)), "the body went on stdin: {seen}");
}

#[cfg(unix)]
#[tokio::test]
async fn a_gh_refusal_is_an_answer_with_its_status() {
    let dir = tempfile::tempdir().unwrap();
    let gh = fake_gh(
        dir.path(),
        "printf '{\"message\":\"Not Found\"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1",
    );
    let reply = serve_at(
        json!({"op": "get", "repo": "o/r", "path": "pulls/1"}),
        &AppLease::default(),
        "http://127.0.0.1:9",
        &gh,
    )
    .await
    .unwrap();
    assert_eq!(
        (reply["ok"].clone(), reply["status"].clone(), reply["message"].clone()),
        (json!(false), json!(404), json!("Not Found"))
    );
}

#[cfg(unix)]
#[tokio::test]
async fn no_sign_in_and_no_usable_gh_is_not_connected() {
    let dir = tempfile::tempdir().unwrap();
    let logged_out = fake_gh(
        dir.path(),
        "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4",
    );
    let missing = dir.path().join("no-gh").to_string_lossy().into_owned();
    for gh in [logged_out, missing] {
        let e = serve_at(
            json!({"op": "get", "repo": "o/r", "path": ""}),
            &AppLease::default(),
            "http://127.0.0.1:9",
            &gh,
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, crate::github_app_token::not_connected().code, "{gh}");
    }
}

#[tokio::test]
async fn an_op_outside_the_table_never_runs() {
    let e = serve_at(
        json!({"op": "get", "repo": "o/r", "path": "actions/secrets"}),
        &AppLease::default(),
        "http://127.0.0.1:9",
        "/nonexistent/gh",
    )
    .await
    .unwrap_err();
    assert_eq!(e.code, RpcError::invalid_params("x").code);
}
