//! The guest gets only fresh preview data; its root agent owns install auth.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use cmux_server_core::install_key::{InstallKey, SystemRandom, verify};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::preview::{
    PreviewAsk, PreviewOperation, ShareAudience, answer, plain_inventory, preview_row,
};
use super::sender::Answer;
use super::wire::{Bound, Env};

const MACHINE: &str = "vm_preview_test";
const INSTALL: &str = "inst_preview_test";
const TEAM: &str = "team_preview_test";
const USER: &str = "user_preview_test";
const REFRESH: &str = "/v1/cloud/machines/vm_preview_test/previews/refresh";
const NOW: u64 = 1_790_000_000_000;

fn ask(operation: PreviewOperation, port: Option<u16>) -> PreviewAsk {
    PreviewAsk { operation, port, audience: None, bootstrap: false }
}

fn preview(port: u16, suffix: &str) -> Value {
    json!({
        "port":port, "url":format!("https://p-{port}.preview.cmux.dev/auth?token={suffix}"),
        "origin":format!("https://p-{port}.preview.cmux.dev"), "expiresAt":NOW + 60_000,
    })
}

fn inventory(previews: Vec<Value>) -> Value {
    let listening: Vec<_> = previews.iter().map(|row| row["port"].clone()).collect();
    json!({"machine":MACHINE, "previews":previews, "listening":listening, "unavailable":[]})
}

fn http(body: Value) -> Answer {
    Answer::Http { status: 200, body }
}

#[test]
fn preview_url_refreshes_before_selecting_the_matching_port() {
    let fresh = preview(3000, "fresh");
    let mut requests = Vec::new();
    let reply =
        answer(&ask(PreviewOperation::Url, Some(3000)), MACHINE, TEAM, |method, path, body| {
            requests.push((method.to_owned(), path.to_owned(), body.clone()));
            http(inventory(vec![preview(8080, "other"), fresh.clone()]))
        });
    assert_eq!(requests, vec![("POST".to_owned(), REFRESH.to_owned(), json!({}))]);
    assert_eq!(reply, json!({"ok":true, "value":preview_row(&fresh, false).unwrap()}));
}

#[test]
fn preview_list_is_the_refreshed_inventory() {
    let current = inventory(vec![preview(8080, "fresh")]);
    let reply = answer(&ask(PreviewOperation::List, None), MACHINE, TEAM, |method, path, _| {
        assert_eq!(method, "POST");
        assert_eq!(path, REFRESH);
        http(current.clone())
    });
    assert_eq!(reply, json!({"ok":true, "value":plain_inventory(&current).unwrap()}));
}

#[test]
fn preview_absent_port_names_the_server_start_action() {
    let reply = answer(&ask(PreviewOperation::Url, Some(3000)), MACHINE, TEAM, |_, _, _| {
        http(inventory(vec![preview(8080, "other")]))
    });
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error"]["code"], "preview.not_listening");
    assert!(reply["error"]["message"].as_str().unwrap().contains("Start the server"));
    assert!(reply.get("value").is_none());
}

#[test]
fn preview_inventory_from_another_machine_or_with_invalid_shape_is_refused() {
    let mut other = inventory(vec![preview(3000, "wrong-machine")]);
    other["machine"] = json!("vm_someone_else");
    for body in [
        other,
        json!({}),
        json!({"machine":MACHINE, "previews":{}}),
        json!({"machine":MACHINE, "previews":null}),
    ] {
        let reply = answer(&ask(PreviewOperation::Url, Some(3000)), MACHINE, TEAM, |_, _, _| {
            http(body.clone())
        });
        assert_eq!(reply["error"]["code"], "preview.bad_answer", "{body}");
        assert!(reply.get("value").is_none());
    }
}

#[test]
fn preview_transport_and_policy_failures_return_actionable_refusals() {
    let url = ask(PreviewOperation::Url, Some(3000));
    let unreachable = answer(&url, MACHINE, TEAM, |_, _, _| Answer::Transport);
    assert_eq!(unreachable["error"]["code"], "preview.unreachable");
    assert!(unreachable["error"]["message"].as_str().unwrap().contains("Retry"));
    let denied = answer(&url, MACHINE, TEAM, |_, _, _| Answer::Http {
        status: 403,
        body: json!({"error":{"code":"policy.denied","message":"internal detail"}}),
    });
    assert_eq!(denied["error"]["code"], "policy.denied");
    assert!(denied["error"]["message"].as_str().unwrap().contains("retry"));
    assert!(!denied.to_string().contains("internal detail"));
}

#[derive(Default)]
struct FakeState {
    posts: Vec<(String, Option<String>, Value)>,
    answers: VecDeque<(u16, Value)>,
    minted: usize,
}

#[derive(Clone)]
struct Fake {
    state: Arc<Mutex<FakeState>>,
    public_key: Value,
}

impl Http for Fake {
    fn send(
        &self,
        method: &str,
        url: &str,
        body: &Value,
        bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        assert_eq!(method, "POST", "refresh uses POST; share routing is tested separately");
        self.post(url, body, bearer)
    }

    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let mut state = self.state.lock().unwrap();
        state.posts.push((url.to_owned(), bearer.map(str::to_owned), body.clone()));
        if url == format!("{}/v1/auth/challenge", Env::Dev.api_origin()) {
            assert!(bearer.is_none());
            assert_eq!(body, &json!({"user":USER,"install":INSTALL}));
            return Ok((
                200,
                json!({
                    "install":INSTALL, "nonce":"preview-nonce",
                    "message_prefix":format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n"),
                }),
            ));
        }
        if url == format!("{}/v1/auth/token", Env::Dev.api_origin()) {
            assert!(bearer.is_none());
            assert_eq!(body["user"], USER);
            assert_eq!(body["install"], INSTALL);
            assert!(verify(
                &self.public_key,
                format!("cmux-auth-v1\ndevelopment\n{INSTALL}\npreview-nonce").as_bytes(),
                body["signature"].as_str().unwrap(),
            ));
            state.minted += 1;
            return Ok((
                200,
                json!({
                    "access_token":format!("bearer-{}",state.minted),
                    "token_type":"Bearer", "expires_at":NOW + 600_000,
                    "user":USER, "install":INSTALL, "grant":"grant_preview_test",
                    "team":"team_preview_test",
                }),
            ));
        }
        assert_eq!(url, format!("{}{REFRESH}", Env::Dev.platform_origin()));
        assert_eq!(body, &json!({}));
        assert_eq!(bearer, Some(format!("bearer-{}", state.minted).as_str()));
        Ok(state.answers.pop_front().expect("no unexpected preview calls"))
    }
}

fn client(answers: impl IntoIterator<Item = (u16, Value)>) -> (CloudClient<Fake>, Fake) {
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    let fake = Fake {
        state: Arc::new(Mutex::new(FakeState {
            answers: answers.into_iter().collect(),
            ..FakeState::default()
        })),
        public_key: key.public_jwk(),
    };
    let bound = Bound {
        machine: MACHINE.to_owned(),
        team: "team_preview_test".to_owned(),
        host: "host_preview_test".to_owned(),
        epoch: 1,
        install: INSTALL.to_owned(),
        user: USER.to_owned(),
        grant: "grant_preview_test".to_owned(),
        env: Env::Dev,
        api_origin: Env::Dev.api_origin().to_owned(),
        keyset: Value::Null,
        bound_at: NOW,
    };
    (CloudClient::new(fake.clone(), bound, key), fake)
}

fn preview_posts(state: &FakeState) -> Vec<&(String, Option<String>, Value)> {
    state.posts.iter().filter(|post| post.0.ends_with(REFRESH)).collect()
}

#[test]
fn preview_client_uses_bound_identity_and_platform_origin_with_one_401_refresh() {
    let fresh = preview(3000, "fresh");
    let (mut client, fake) = client([
        (401, json!({"error":{"code":"auth.required"}})),
        (200, inventory(vec![fresh.clone()])),
    ]);
    let reply = client.preview(&ask(PreviewOperation::Url, Some(3000)), NOW);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["value"]["url"], "https://p-3000.preview.cmux.dev");
    assert!(!reply.to_string().contains("token="));
    assert!(!reply.to_string().contains("bearer-"));
    let state = fake.state.lock().unwrap();
    assert_eq!(state.minted, 2);
    let posts = preview_posts(&state);
    assert_eq!(posts.len(), 2);
    assert_eq!(posts[0].1.as_deref(), Some("bearer-1"));
    assert_eq!(posts[1].1.as_deref(), Some("bearer-2"));
    assert!(state.answers.is_empty());
}

#[test]
fn preview_client_policy_denial_is_not_retried() {
    let (mut client, fake) = client([(403, json!({"error":{"code":"policy.denied"}}))]);
    let reply = client.preview(&ask(PreviewOperation::Url, Some(3000)), NOW);
    assert_eq!(reply["error"]["code"], "policy.denied");
    let state = fake.state.lock().unwrap();
    assert_eq!(state.minted, 1);
    assert_eq!(preview_posts(&state).len(), 1);
}

#[test]
fn preview_client_never_falls_back_to_a_cached_url_after_a_server_stops() {
    let old = preview(3000, "old-credential");
    let (mut client, fake) =
        client([(200, inventory(vec![old.clone()])), (200, inventory(vec![])), (503, json!({}))]);
    let url = ask(PreviewOperation::Url, Some(3000));
    assert_eq!(client.preview(&url, NOW)["value"], preview_row(&old, false).unwrap());
    let stopped = client.preview(&url, NOW + 1);
    assert_eq!(stopped["error"]["code"], "preview.not_listening");
    assert!(!stopped.to_string().contains("old-credential"));
    let unavailable = client.preview(&url, NOW + 2);
    assert_eq!(unavailable["ok"], false);
    assert!(!unavailable.to_string().contains("old-credential"));
    let state = fake.state.lock().unwrap();
    assert_eq!(state.minted, 1, "the install bearer is reused, preview URLs are not");
    assert_eq!(preview_posts(&state).len(), 3);
}

fn share(audience: ShareAudience) -> PreviewAsk {
    PreviewAsk {
        operation: PreviewOperation::Share,
        port: Some(3000),
        audience: Some(audience),
        bootstrap: false,
    }
}

#[test]
fn preview_link_sharing_posts_defaults_and_returns_only_the_new_link() {
    let mut calls = Vec::new();
    let linked = json!({"link":{"linkId":"link_test"},"url":"https://share.cmux.dev/s/new-link"});
    let reply = answer(&share(ShareAudience::Link), MACHINE, TEAM, |method, path, body| {
        calls.push((method.to_owned(), path.to_owned(), body.clone()));
        if path == REFRESH {
            return http(inventory(vec![preview(3000, "owner-only")]));
        }
        http(linked.clone())
    });
    assert_eq!(
        calls,
        vec![
            ("POST".to_owned(), REFRESH.to_owned(), json!({})),
            (
                "POST".to_owned(),
                format!("/v1/cloud/machines/{MACHINE}/previews/3000/links"),
                json!({})
            ),
        ]
    );
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["value"]["url"], linked["url"]);
    assert_eq!(reply["value"]["linkId"], linked["link"]["linkId"]);
    assert!(!reply.to_string().contains("owner-only"));
}

#[test]
fn preview_grants_use_the_bound_team_or_named_user_and_return_the_origin() {
    for (audience, grant) in [
        (ShareAudience::Team, json!({"kind":"team", "id":TEAM})),
        (
            ShareAudience::User("user_invited".to_owned()),
            json!({"kind":"user", "id":"user_invited"}),
        ),
    ] {
        let mut calls = Vec::new();
        let reply = answer(&share(audience), MACHINE, TEAM, |method, path, body| {
            calls.push((method.to_owned(), path.to_owned(), body.clone()));
            if path == REFRESH {
                return http(inventory(vec![preview(3000, "owner-only")]));
            }
            http(json!({"grant":grant.clone()}))
        });
        assert_eq!(
            calls,
            vec![
                ("POST".to_owned(), REFRESH.to_owned(), json!({})),
                (
                    "PUT".to_owned(),
                    format!("/v1/cloud/machines/{MACHINE}/previews/3000/grants"),
                    grant
                ),
            ]
        );
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["value"]["url"], "https://p-3000.preview.cmux.dev");
        assert!(!reply.to_string().contains("owner-only"));
        assert!(!reply.to_string().contains("/auth?"));
    }
}

#[test]
fn preview_grant_failure_stops_without_returning_a_private_url() {
    let mut calls = 0;
    let reply = answer(&share(ShareAudience::Team), MACHINE, TEAM, |_, path, _| {
        calls += 1;
        if path == REFRESH {
            return http(inventory(vec![preview(3000, "owner-only")]));
        }
        Answer::Http { status: 403, body: json!({"error":{"code":"policy.denied"}}) }
    });
    assert_eq!(calls, 2);
    assert_eq!(reply["ok"], false);
    assert!(reply.get("value").is_none());
    assert!(!reply.to_string().contains("owner-only"));
    assert!(reply.get("url").is_none());
}

#[test]
fn preview_share_never_falls_back_to_owner_bootstrap_when_shared_url_is_missing() {
    let reply = answer(&share(ShareAudience::Link), MACHINE, TEAM, |_, path, _| {
        if path == REFRESH {
            return http(inventory(vec![preview(3000, "owner-only")]));
        }
        http(json!({"link":{"linkId":"link_missing_url"}}))
    });
    assert_eq!(reply["ok"], false);
    assert!(reply.get("value").is_none());
    assert!(!reply.to_string().contains("owner-only"));

    let mut without_origin = preview(3000, "owner-only");
    without_origin.as_object_mut().unwrap().remove("origin");
    let reply = answer(&share(ShareAudience::Team), MACHINE, TEAM, |_, path, _| {
        if path == REFRESH {
            return http(inventory(vec![without_origin.clone()]));
        }
        http(json!({"grant":{"kind":"team","id":TEAM}}))
    });
    assert_eq!(reply["ok"], false);
    assert!(reply.get("value").is_none());
    assert!(!reply.to_string().contains("owner-only"));
}

#[test]
fn preview_defaults_strip_private_capabilities_and_only_url_can_opt_in() {
    let fresh = preview(3000, "OWNER_SECRET");
    for operation in [PreviewOperation::List, PreviewOperation::Url] {
        let port = if operation == PreviewOperation::Url { Some(3000) } else { None };
        let request = ask(operation, port);
        let reply = answer(&request, MACHINE, TEAM, |_, _, _| http(inventory(vec![fresh.clone()])));
        assert_eq!(reply["ok"], true);
        assert!(!reply.to_string().contains("OWNER_SECRET"));
        assert!(!reply.to_string().contains("token="));
    }
    let mut request = ask(PreviewOperation::Url, Some(3000));
    request.bootstrap = true;
    let reply = answer(&request, MACHINE, TEAM, |_, _, _| http(inventory(vec![fresh.clone()])));
    assert_eq!(reply["value"]["url"], fresh["url"]);
    request.operation = PreviewOperation::List;
    request.port = None;
    assert!(request.validate().is_err());
}

#[test]
fn preview_list_drops_unrecognized_credential_fields_and_strips_missing_origins() {
    let mut row = preview(3000, "OWNER_SECRET");
    row.as_object_mut().unwrap().remove("origin");
    row["bootstrap"] = json!("OWNER_SECRET");
    let mut list = inventory(vec![row]);
    list["bootstrapUrl"] = json!("OWNER_SECRET");
    let plain = plain_inventory(&list).unwrap();
    assert_eq!(plain["previews"][0]["url"], "https://p-3000.preview.cmux.dev");
    assert!(!plain.to_string().contains("OWNER_SECRET"));
}
