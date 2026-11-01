use super::github_repos::{ReposAsk, answer};
use super::sender::Answer;
use serde_json::{Value, json};

fn http(status: u16, body: Value) -> Answer {
    Answer::Http { status, body }
}
fn catalog(state: &str) -> Answer {
    http(200, json!({"connectors":[{"provider":"github","state":state}]}))
}
fn ask(value: Value) -> ReposAsk {
    ReposAsk::from_json(&value).unwrap()
}

#[test]
fn github_repos_preserves_pagination_and_escapes_query_and_cursor() {
    let mut calls = Vec::new();
    let reply = answer(&ask(json!({"query":"cmux &more", "cursor":"a/b+=?"})), "team-a", |path| {
        calls.push(path.to_owned());
        if path.starts_with("/v1/connectors/?") {
            return catalog("installed");
        }
        http(200, json!({"repos":[{"fullName":"manaflow-ai/cmux","private":true}],"cursor":"next"}))
    });
    assert_eq!(
        calls[1],
        "/v1/connectors/github/repos?team=team-a&query=cmux%20%26more&cursor=a%2Fb%2B%3D%3F"
    );
    assert_eq!(
        reply,
        json!({"ok":true,"repos":[{"fullName":"manaflow-ai/cmux","private":true}],"next_cursor":"next"})
    );
}

#[test]
fn github_repos_connection_states_get_install_url_without_listing() {
    for state in ["available", "needs-auth", "expired"] {
        let mut calls = Vec::new();
        let reply = answer(&ask(json!({})), "team-a", |path| {
            calls.push(path.to_owned());
            if path.starts_with("/v1/connectors/?") {
                catalog(state)
            } else {
                http(200, json!({"url":"https://github.com/apps/cmux/installations/new"}))
            }
        });
        assert_eq!(calls.len(), 2);
        assert!(calls[1].contains("/install?team=team-a"));
        assert_eq!(
            reply["connect"]["install_url"],
            "https://github.com/apps/cmux/installations/new"
        );
        assert_eq!(reply["ok"], true);
    }
}

#[test]
fn github_repos_empty_installation_is_not_a_missing_connection() {
    let reply = answer(&ask(json!({})), "team-a", |path| {
        if path.starts_with("/v1/connectors/?") {
            catalog("installed")
        } else {
            http(200, json!({"repos":[], "cursor":null}))
        }
    });
    assert_eq!(reply, json!({"ok":true,"repos":[]}));
}

#[test]
fn github_repos_errors_name_a_next_action_and_stale_cursor_does_not_connect() {
    for (status, tag, expected) in [
        (409, "ConnectorCursorStale", "cursor_stale"),
        (403, "ConnectorForbidden", "repo.no_access"),
        (429, "ConnectorRateLimited", "rate_limited"),
        (400, "ConnectorInvalid", "request.invalid"),
        (503, "ConnectorUnavailable", "integration.unavailable"),
    ] {
        let reply = answer(&ask(json!({})), "team-a", |path| {
            if path.starts_with("/v1/connectors/?") {
                catalog("installed")
            } else {
                http(status, json!({"_tag":tag,"message":"not copied"}))
            }
        });
        assert_eq!(reply["error"]["code"], expected);
        assert!(!reply["error"]["message"].as_str().unwrap().contains("not copied"));
    }
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
        json!({"repos":[{"fullName":"../repo","private":false}]}),
        json!({"repos":[],"cursor":4}),
    ] {
        let reply = answer(&ask(json!({})), "team-a", |path| {
            if path.starts_with("/v1/connectors/?") {
                catalog("installed")
            } else {
                http(200, body.clone())
            }
        });
        assert_eq!(reply["error"]["code"], "integration.bad_answer");
    }
    let reply = answer(&ask(json!({})), "team-a", |path| {
        if path.starts_with("/v1/connectors/?") {
            catalog("available")
        } else {
            http(200, json!({"url":"javascript:alert(1)"}))
        }
    });
    assert_eq!(reply["error"]["code"], "integration.bad_answer");
}

#[test]
fn github_repos_authenticated_get_uses_platform_origin_and_refreshes_once() {
    use super::client::{CloudClient, Http};
    use super::wire::{Bound, Env};
    use cmux_server_core::install_key::{InstallKey, SystemRandom};
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Fake(Arc<Mutex<(Vec<(String, Option<String>)>, usize, usize)>>);
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
                    json!({"access_token":format!("bearer-{}",state.1),"token_type":"Bearer","expires_at":600_000}),
                ))
            }
        }
        fn get(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
            let mut state = self.0.lock().unwrap();
            state.0.push((url.to_owned(), bearer.map(str::to_owned)));
            state.2 += 1;
            if state.2 == 1 {
                return Ok((401, json!({"_tag":"ConnectorAuthRequired"})));
            }
            if url.contains("/v1/connectors/?") {
                Ok((200, json!({"connectors":[{"provider":"github","state":"installed"}]})))
            } else {
                Ok((200, json!({"repos":[],"cursor":null})))
            }
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
    assert_eq!(state.0.len(), 3);
    assert_eq!(
        state.0[0],
        (
            "https://cmux-platform-development.debussy.workers.dev/v1/connectors/?team=team-a"
                .to_owned(),
            Some("bearer-1".to_owned())
        )
    );
    assert_eq!(state.0[1].1.as_deref(), Some("bearer-2"));
}

#[test]
fn github_repos_expired_connection_between_catalog_and_list_gets_install_url() {
    let reply = answer(&ask(json!({})), "team-a", |path| {
        if path.starts_with("/v1/connectors/?") {
            catalog("installed")
        } else if path.contains("/repos?") {
            http(409, json!({"_tag":"ConnectorNeedsAuth"}))
        } else {
            http(200, json!({"url":"https://github.com/apps/cmux/installations/new"}))
        }
    });
    assert_eq!(reply["connect"]["install_url"], "https://github.com/apps/cmux/installations/new");
}

#[test]
fn github_repos_access_denied_carries_install_url_when_authorized() {
    for link_allowed in [true, false] {
        let reply = answer(&ask(json!({})), "team-a", |path| {
            if path.starts_with("/v1/connectors/?") {
                catalog("installed")
            } else if path.contains("/install?") && link_allowed {
                http(200, json!({"url":"https://github.com/apps/cmux/installations/new"}))
            } else {
                http(403, json!({"_tag":"ConnectorForbidden"}))
            }
        });
        assert_eq!(reply["error"]["code"], "repo.no_access");
        assert_eq!(reply["error"].get("install_url").is_some(), link_allowed);
    }
}

#[test]
fn github_repos_unlinked_vm_preserves_connect_when_link_issuance_is_denied() {
    for state in ["available", "needs-auth", "expired", "installed"] {
        let reply = answer(&ask(json!({})), "team-a", |path| {
            if path.starts_with("/v1/connectors/?") {
                catalog(state)
            } else if path.contains("/repos?") {
                http(409, json!({"_tag":"ConnectorNeedsAuth"}))
            } else {
                http(
                    403,
                    json!({"_tag":"ConnectorForbidden", "message":"a machine install may call only its own machine's ops"}),
                )
            }
        });
        assert_eq!(reply, json!({"ok":true,"repos":[],"connect":{}}));
    }
}
