//! An app's `integration.request` to GitHub through the supervisor: the
//! grant check, then the daemon's gateway over a fake `gh` (a private repo,
//! then a conditional re-read answered 304), never the provider.

use std::collections::VecDeque;

use super::super::github_gateway::GitHubGateway;
use super::*;
use crate::feed_client::GhRunner;

#[derive(Default)]
struct ScriptedGh {
    calls: Mutex<Vec<Vec<String>>>,
    answers: Mutex<VecDeque<&'static str>>,
}

impl GhRunner for ScriptedGh {
    fn run(&self, args: &[String]) -> Result<Vec<u8>, String> {
        self.calls.lock().unwrap().push(args.to_vec());
        self.answers
            .lock()
            .unwrap()
            .pop_front()
            .map(|a| a.as_bytes().to_vec())
            .ok_or_else(|| "gh failed".into())
    }
}

const PRIVATE_PULLS: &str = "HTTP/2.0 200 OK\r\nEtag: W/\"secret-1\"\r\nX-Ratelimit-Remaining: 4999\r\n\r\n[{\"number\":42,\"title\":\"private change\",\"head\":{\"repo\":{\"private\":true}}}]";
const NOT_MODIFIED: &str =
    "HTTP/2.0 304 Not Modified\r\nEtag: W/\"secret-1\"\r\nX-Ratelimit-Remaining: 4999\r\n\r\n";

#[test]
fn a_private_repo_read_goes_through_the_gateway_and_a_re_read_replays_on_304() {
    let f = fixture();
    let gh = Arc::new(ScriptedGh::default());
    gh.answers.lock().unwrap().extend([PRIVATE_PULLS, NOT_MODIFIED]);
    f.supervisor.set_github_gateway(GitHubGateway::new(gh.clone()));
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let params = json!({ "provider": "github", "path": "/repos/acme/secret/pulls?state=open" });
    let first = f.call("m1", "integration.request", params.clone(), false);
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(first["body"]["value"][0]["title"], "private change");
    assert_eq!(first["body"]["integration"]["status"], 200);
    let second = f.call("m1", "integration.request", params, false);
    assert_eq!(second["body"]["value"], first["body"]["value"]);
    assert_eq!(
        (
            second["body"]["integration"]["status"].clone(),
            second["body"]["integration"]["notModified"].clone()
        ),
        (json!(304), json!(true))
    );
    let calls = gh.calls.lock().unwrap().clone();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0][4], "repos/acme/secret/pulls?state=open");
    assert!(!calls[0].iter().any(|a| a.starts_with("If-None-Match")));
    assert!(calls[1].iter().any(|a| a == "If-None-Match: W/\"secret-1\""));
}

#[test]
fn the_gateway_refuses_paths_off_its_allowlist_and_an_app_without_the_scope() {
    let f = fixture();
    let gh = Arc::new(ScriptedGh::default());
    f.supervisor.set_github_gateway(GitHubGateway::new(gh.clone()));
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let refused = f.call(
        "m1",
        "integration.request",
        json!({ "provider": "github", "path": "/user/emails" }),
        false,
    );
    assert_eq!(refused["body"]["code"], "validation.invalid");
    // The read scope never covers a write, whatever the path.
    let write = f.call(
        "m1",
        "integration.request",
        json!({ "provider": "github", "method": "POST", "path": "/repos/a/b/pulls" }),
        false,
    );
    assert_eq!(write["body"]["code"], "scope.missing");
    assert!(gh.calls.lock().unwrap().is_empty(), "gh never ran");
}
