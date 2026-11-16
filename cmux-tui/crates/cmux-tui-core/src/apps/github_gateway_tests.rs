//! The GitHub gateway against a fake `gh`: the read allowlist, the
//! conditional request and its 304 replay, the cache bound, the errors.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::*;

/// A fake `gh`: records each argument list and answers the next scripted
/// output (`gh api --include` text), or an error.
#[derive(Default)]
struct FakeGh {
    calls: Mutex<Vec<Vec<String>>>,
    answers: Mutex<VecDeque<Result<Vec<u8>, String>>>,
}

impl FakeGh {
    fn answer(&self, status: &str, etag: Option<&str>, body: &str) {
        let mut out = format!("HTTP/2.0 {status}\r\nContent-Type: application/json\r\n");
        if let Some(etag) = etag {
            out.push_str(&format!("Etag: {etag}\r\n"));
        }
        out.push_str("X-Ratelimit-Remaining: 4987\r\n\r\n");
        out.push_str(body);
        self.answers.lock().unwrap().push_back(Ok(out.into_bytes()));
    }

    fn fail(&self, why: &str) {
        self.answers.lock().unwrap().push_back(Err(why.into()));
    }

    fn calls(&self) -> Vec<Vec<String>> {
        self.calls.lock().unwrap().clone()
    }
}

impl GhRunner for FakeGh {
    fn run(&self, args: &[String]) -> Result<Vec<u8>, String> {
        self.calls.lock().unwrap().push(args.to_vec());
        self.answers.lock().unwrap().pop_front().unwrap_or_else(|| Err("no scripted answer".into()))
    }
}

fn gateway() -> (Arc<FakeGh>, GitHubGateway) {
    let gh = Arc::new(FakeGh::default());
    (gh.clone(), GitHubGateway::new(gh))
}

fn get(path: &str) -> Value {
    json!({ "provider": "github", "method": "GET", "path": path })
}

fn if_none_match(args: &[String]) -> Option<String> {
    args.iter().find_map(|a| a.strip_prefix("If-None-Match: ").map(str::to_owned))
}

#[test]
fn the_read_paths_are_admitted_and_nothing_else() {
    for path in [
        "/user",
        "/search/issues?q=is%3Apr%20author%3A%40me&per_page=20",
        "/repos/acme/secret/pulls",
        "/repos/acme/secret/pulls?state=open&per_page=50",
        "/repos/acme/.github/pulls/12",
        "/repos/acme/secret/pulls/12/reviews",
        "/repos/acme/secret/commits/0123abcd/check-runs",
        "/repos/acme/secret/commits/feat%2Fx/status",
    ] {
        assert_eq!(admit_path(path).unwrap(), &path[1..], "{path}");
    }
    for path in [
        "user",
        "/user/repos",
        "/repos/acme/secret",
        "/repos/acme/secret/pulls/12/merge",
        "/repos/acme/secret/issues",
        "/repos/acme/../pulls",
        "/repos/acme/secret/pulls/abc",
        "/repos/acme//pulls",
        "/repos/{owner}/{repo}/pulls",
        "/repos/acme/secret/commits/a/b/status",
        "/repos/acme/secret/commits/%2e%2e/status",
        "/search/issues?q=a b",
        "/search/issues?q={owner}",
        "/search/issues?q=a#frag",
        "/orgs/acme/members",
        "/installation/token",
        "https://api.github.com/user",
    ] {
        let refused = admit_path(path).unwrap_err();
        assert_eq!(refused["code"], "validation.invalid", "{path}");
        assert_eq!(refused["details"]["path"], path);
    }
}

#[test]
fn a_private_repo_read_runs_gh_and_answers_its_json_with_the_metadata() {
    let (gh, gw) = gateway();
    gh.answer("200 OK", Some("W/\"p1\""), r#"[{"number":7,"title":"secret work"}]"#);
    let reply = gw.request(&get("/repos/acme/secret/pulls?state=open")).unwrap();
    assert_eq!(reply["value"], json!([{ "number": 7, "title": "secret work" }]));
    assert_eq!(
        reply["integration"],
        json!({ "provider": "github", "status": 200, "notModified": false, "rateRemaining": 4987, "route": "gh" })
    );
    let calls = gh.calls();
    assert_eq!(
        calls[0][..5],
        ["api", "--include", "-X", "GET", "repos/acme/secret/pulls?state=open"]
    );
    assert_eq!(if_none_match(&calls[0]), None, "the first read is unconditional");
}

#[test]
fn a_second_read_sends_if_none_match_and_replays_the_body_on_304() {
    let (gh, gw) = gateway();
    gh.answer("200 OK", Some("W/\"p1\""), r#"{"items":[{"number":7}]}"#);
    gh.answer("304 Not Modified", Some("W/\"p1\""), "");
    let path = get("/search/issues?q=is%3Apr");
    let first = gw.request(&path).unwrap();
    let second = gw.request(&path).unwrap();
    assert_eq!(if_none_match(&gh.calls()[1]).as_deref(), Some("W/\"p1\""));
    assert_eq!(second["value"], first["value"]);
    assert_eq!(second["integration"]["status"], 304);
    assert_eq!(second["integration"]["notModified"], true);
    // A changed answer replaces the kept one.
    gh.answer("200 OK", Some("W/\"p2\""), r#"{"items":[]}"#);
    let third = gw.request(&path).unwrap();
    assert_eq!(third["value"], json!({ "items": [] }));
    gh.answer("304 Not Modified", None, "");
    gw.request(&path).unwrap();
    assert_eq!(if_none_match(&gh.calls()[3]).as_deref(), Some("W/\"p2\""));
}

#[test]
fn a_304_for_an_evicted_path_reads_it_again_unconditionally() {
    let (gh, gw) = gateway();
    gh.answer("304 Not Modified", None, "");
    gh.answer("200 OK", Some("W/\"u\""), r#"{"login":"me"}"#);
    let reply = gw.request(&get("/user")).unwrap();
    assert_eq!(reply["value"]["login"], "me");
    assert_eq!(if_none_match(&gh.calls()[1]), None);
}

#[test]
fn the_cache_stays_bounded_in_entries_and_bytes() {
    let (gh, gw) = gateway();
    for n in 0..(MAX_ENTRIES + 20) {
        gh.answer("200 OK", Some(&format!("\"e{n}\"")), r#"{"number":1}"#);
        gw.request(&get(&format!("/repos/acme/r/pulls/{n}"))).unwrap();
    }
    assert_eq!(gw.cached().0, MAX_ENTRIES);
    // The oldest went first: pull 0 reads unconditionally, the newest does not.
    gh.answer("200 OK", None, "{}");
    gw.request(&get("/repos/acme/r/pulls/0")).unwrap();
    assert_eq!(if_none_match(gh.calls().last().unwrap()), None);
    let newest = MAX_ENTRIES + 19;
    gh.answer("304 Not Modified", None, "");
    gw.request(&get(&format!("/repos/acme/r/pulls/{newest}"))).unwrap();
    assert!(if_none_match(gh.calls().last().unwrap()).is_some());
    // A body over the entry cap is answered but not kept.
    let big = format!("{{\"blob\":\"{}\"}}", "x".repeat(MAX_ENTRY_BYTES));
    gh.answer("200 OK", Some("\"big\""), &big);
    let (entries, _) = gw.cached();
    gw.request(&get("/user")).unwrap();
    assert!(gw.cached().0 <= entries);
    assert!(gw.cached().1 <= MAX_CACHE_BYTES);
}

#[test]
fn writes_and_unknown_paths_never_run_gh() {
    let (gh, gw) = gateway();
    let post = gw
        .request(&json!({ "provider": "github", "method": "POST", "path": "/repos/a/b/pulls" }))
        .unwrap_err();
    assert_eq!(post["code"], "operation.unsupported");
    assert_eq!(gw.request(&get("/user/emails")).unwrap_err()["code"], "validation.invalid");
    assert_eq!(
        gw.request(&json!({ "provider": "github" })).unwrap_err()["code"],
        "validation.invalid"
    );
    assert!(gh.calls().is_empty());
}

#[test]
fn errors_name_sign_in_http_status_and_retry() {
    let (gh, gw) = gateway();
    gh.fail("gh failed: exit status: 4");
    let no_sign_in = gw.request(&get("/user")).unwrap_err();
    assert_eq!(no_sign_in["code"], "integration.unavailable");
    assert_eq!(no_sign_in["retryable"], false);
    gh.answer("404 Not Found", None, r#"{"message":"Not Found"}"#);
    let missing = gw.request(&get("/repos/acme/gone/pulls")).unwrap_err();
    assert_eq!(
        (
            missing["code"].clone(),
            missing["details"]["status"].clone(),
            missing["retryable"].clone()
        ),
        (json!("integration.http"), json!(404), json!(false))
    );
    gh.answer("403 Forbidden", None, r#"{"message":"API rate limit exceeded"}"#);
    assert_eq!(gw.request(&get("/user")).unwrap_err()["message"], "API rate limit exceeded");
    gh.answer("502 Bad Gateway", None, "");
    assert_eq!(gw.request(&get("/user")).unwrap_err()["retryable"], true);
    gh.answer("401 Unauthorized", None, r#"{"message":"Bad credentials"}"#);
    assert_eq!(gw.request(&get("/user")).unwrap_err()["code"], "integration.unavailable");
}
