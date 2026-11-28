use super::github_repos::{ReposAsk, answer};
use super::sender::Answer;
use serde_json::{Value, json};

fn http(status: u16, body: Value) -> Answer {
    Answer::Http { status, body }
}
fn api_error(status: u16, code: &str, message: &str) -> Answer {
    http(status, json!({"error":{"code":code,"message":message}}))
}
fn ask(value: Value) -> ReposAsk {
    ReposAsk::from_json(&value).unwrap()
}

#[test]
fn github_repos_lists_from_cmux_api_preserving_pagination_and_escaping() {
    let mut calls = Vec::new();
    let reply = answer(&ask(json!({"query":"cmux &more", "cursor":"a/b+=?"})), "team-a", |path| {
        calls.push(path.to_owned());
        http(
            200,
            json!({"repos":[{"full_name":"manaflow-ai/cmux","private":true,"default_branch":"main"}],"truncated":true,"cursor":"next"}),
        )
    });
    assert_eq!(
        calls,
        ["/v1/integrations/github/repos?team=team-a&query=cmux%20%26more&cursor=a%2Fb%2B%3D%3F"]
    );
    assert_eq!(
        reply,
        json!({"ok":true,"repos":[{"fullName":"manaflow-ai/cmux","private":true}],"next_cursor":"next"})
    );
}

#[test]
fn github_repos_missing_or_expired_link_is_connect_without_a_second_call() {
    for (status, code) in [(404, "integration.not_found"), (409, "needs_reauth")] {
        let mut calls = 0;
        let reply = answer(&ask(json!({})), "team-a", |_| {
            calls += 1;
            api_error(status, code, "m")
        });
        assert_eq!(calls, 1);
        assert_eq!(reply, json!({"ok":true,"repos":[],"connect":{}}));
    }
    // A bare 404 (a route missing on this deployment) is not a missing link.
    let reply = answer(&ask(json!({})), "team-a", |_| http(404, json!("not found")));
    assert_eq!(reply["error"]["code"], "integration.unavailable");
}

#[test]
fn github_repos_empty_installation_is_not_a_missing_connection() {
    let reply =
        answer(&ask(json!({})), "team-a", |_| http(200, json!({"repos":[], "cursor":null})));
    assert_eq!(reply, json!({"ok":true,"repos":[]}));
}

#[test]
fn github_repos_errors_name_a_next_action_and_never_copy_the_api_message() {
    for (status, code, message, expected) in [
        (400, "request.invalid", "cursor is stale: not copied", "cursor_stale"),
        (400, "request.invalid", "query too long: not copied", "request.invalid"),
        (403, "policy.denied", "not copied", "repo.no_access"),
        (
            403,
            "auth.forbidden",
            "a VM install speaks only for its own live machine",
            "auth.forbidden",
        ),
        (401, "auth.required", "not copied", "auth.required"),
        (429, "rate_limited", "not copied", "rate_limited"),
        (503, "integration.unavailable", "not copied", "integration.unavailable"),
    ] {
        let reply = answer(&ask(json!({})), "team-a", |_| api_error(status, code, message));
        assert_eq!(reply["error"]["code"], expected, "{status} {code}");
        assert!(!reply["error"]["message"].as_str().unwrap().contains("not copied"));
        assert!(!reply["error"]["message"].as_str().unwrap().contains("own live machine"));
    }
    // A refused machine is not told to renew its sign-in.
    let refused = answer(&ask(json!({})), "team-a", |_| api_error(403, "auth.forbidden", "m"));
    assert!(!refused["error"]["message"].as_str().unwrap().contains("renewing"));
    let reply = answer(&ask(json!({})), "team-a", |_| {
        http(429, json!({"error":{"code":"rate_limited","message":"m"},"retry_after":7}))
    });
    assert_eq!(reply["retry_after"], 7);
    let reply = answer(&ask(json!({})), "team-a", |_| Answer::Transport);
    assert_eq!(reply["error"]["code"], "integration.unreachable");
}

#[test]
fn github_repos_rejects_caller_team_and_malformed_or_unsafe_replies() {
    for value in [json!({"team":"other"}), json!({"query":8}), json!({"cursor":"a\nb"}), json!([])]
    {
        assert!(ReposAsk::from_json(&value).is_err());
    }
    for body in [
        json!({}),
        json!({"repos":[{"full_name":"../repo","private":false}]}),
        json!({"repos":[{"full_name":"acme/web"}]}),
        json!({"repos":[],"cursor":4}),
    ] {
        let reply = answer(&ask(json!({})), "team-a", |_| http(200, body.clone()));
        assert_eq!(reply["error"]["code"], "integration.bad_answer");
    }
}

#[test]
fn github_repos_authenticated_get_uses_api_origin_and_refreshes_once() {
    use super::client::{CloudClient, Http};
    use super::wire::{Bound, Env};
    use cmux_server_core::install_key::{InstallKey, SystemRandom};
    use std::sync::{Arc, Mutex};

    /// GET requests seen (url, bearer), token posts, GET count.
    type FakeState = (Vec<(String, Option<String>)>, usize, usize);
    #[derive(Clone, Default)]
    struct Fake(Arc<Mutex<FakeState>>);
    impl Http for Fake {
        fn post(&self, url: &str, _: &Value, _: Option<&str>) -> Result<(u16, Value), String> {
            let mut state = self.0.lock().unwrap();
            if url.ends_with("/v1/auth/challenge") {
                Ok((
                    200,
                    json!({"install":"inst-vm", "nonce":"n", "message_prefix":"cmux-auth-v1\ndevelopment\ninst-vm\n"}),
                ))
            } else {
                state.1 += 1;
                Ok((
                    200,
                    json!({"access_token":format!("bearer-{}",state.1),"token_type":"Bearer","expires_at":600_000,
                        "user":"user-test","install":"inst-vm","grant":"grant-test","team":"team-a"}),
                ))
            }
        }
        fn get(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
            let mut state = self.0.lock().unwrap();
            state.0.push((url.to_owned(), bearer.map(str::to_owned)));
            state.2 += 1;
            if state.2 == 1 {
                return Ok((401, json!({"error":{"code":"auth.required","message":"m"}})));
            }
            Ok((200, json!({"repos":[],"truncated":false,"cursor":null})))
        }
    }
    let fake = Fake::default();
    let mut client = CloudClient::new(
        fake.clone(),
        Bound {
            machine: "vm-test".to_owned(),
            team: "team-a".to_owned(),
            host: "host-test".to_owned(),
            epoch: 1,
            install: "inst-vm".to_owned(),
            user: "user-test".to_owned(),
            grant: "grant-test".to_owned(),
            env: Env::Dev,
            api_origin: Env::Dev.api_origin().to_owned(),
            keyset: Value::Null,
            bound_at: 0,
        },
        InstallKey::generate(&SystemRandom::new()).unwrap(),
    );
    assert_eq!(client.github_repos(&ask(json!({})), 1), json!({"ok":true,"repos":[]}));
    let state = fake.0.lock().unwrap();
    assert_eq!(state.1, 2);
    assert_eq!(state.0.len(), 2);
    assert_eq!(
        state.0[0],
        (
            format!("{}/v1/integrations/github/repos?team=team-a", Env::Dev.api_origin()),
            Some("bearer-1".to_owned())
        )
    );
    assert_eq!(state.0[1], (state.0[0].0.clone(), Some("bearer-2".to_owned())));
}

#[test]
fn a_transient_platform_failure_is_retried_before_it_is_refused() {
    use super::client::patiently;
    use std::time::{Duration, Instant};

    let mut tries = 0;
    let got = patiently("a test", || {
        tries += 1;
        match tries {
            1 => Answer::Transport,
            2 => http(503, json!({})),
            _ => http(200, json!({"repos":[]})),
        }
    });
    assert_eq!(got, http(200, json!({"repos":[]})));
    assert_eq!(tries, 3);
    // A refusal no later send can pass is answered at once.
    let mut tries = 0;
    let got = patiently("a test", || {
        tries += 1;
        api_error(403, "policy.denied", "m")
    });
    assert_eq!(got, api_error(403, "policy.denied", "m"));
    assert_eq!(tries, 1);
    // A rate limit is returned once, preserving the platform's reset metadata. The transport
    // cannot see Retry-After headers, so it must not guess that any JSON value is complete.
    for retry_after in [None, Some(1), Some(60)] {
        let started = Instant::now();
        let mut tries = 0;
        let body = match retry_after {
            Some(seconds) => {
                json!({"error":{"code":"rate_limited","message":"m"},"retry_after":seconds})
            }
            None => json!({"error":{"code":"rate_limited","message":"m"}}),
        };
        let limited = http(429, body);
        let got = patiently("a test", || {
            tries += 1;
            limited.clone()
        });
        assert_eq!((got, tries), (limited.clone(), 1));
        assert!(started.elapsed() < Duration::from_millis(500));
    }
    let limited =
        http(429, json!({"error":{"code":"rate_limited","message":"m"},"retry_after":60}));
    let reply = answer(&ask(json!({})), "team-a", |_| limited.clone());
    assert_eq!(reply["error"]["code"], "rate_limited");
    assert_eq!(reply["error"]["retryable"], true);
    assert_eq!(reply["retry_after"], 60);
    assert!(reply["error"]["message"].as_str().unwrap().contains("60 s"), "{reply}");
    // An outage the machine already waited out is marked for the caller to ask again.
    let reply = answer(&ask(json!({})), "team-a", |_| Answer::Transport);
    assert_eq!(reply["error"]["retryable"], true);
    assert!(!reply["error"]["message"].as_str().unwrap().to_lowercase().contains("retry"));
}
