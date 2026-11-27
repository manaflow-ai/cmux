//! `machine.fork` against the fake: cmux-platform's `POST /v1/machines/{id}/fork` with the
//! caller's bearer, team, key and visibility; the copy answered as is; refusals before any request.

use super::*;

const PARENT: &str = "vm_0123456789abcdefghij";

/// A `TeamMachine` as the platform answers a fork: the running copy.
const COPY: &str = r#"{"provider":"cloudcarrier","id":"vm_aaaaaaaaaaaaaaaaaaaa","region":"us-east","shape":{"vcpu":2,"memGiB":4,"diskGiB":32},"state":"running","capabilities":{"snapshot":true,"restore":true,"fork":true,"exec":true,"stats":true,"restart":true,"ports":true,"desktop":false,"clientSession":true,"sizing":true,"persistentHome":true,"attachTransports":["ssh"]},"creator":"user_owner","visibility":"private","createdAt":1,"kind":"user","present":[],"cost":{"currency":"USD","estimated":true,"hourlyUsd":0.1,"idleHourlyUsd":0,"accruedUsd":0,"runningUsd":0,"totalUsd":0,"runningSince":1}}"#;

const NOT_CREATOR: &str = r#"{"_tag":"MachineForbidden","code":"machine.creator_only","message":"only the creator may fork"}"#;

fn fork(origin: &str, args: Value) -> Request {
    let mut call = request(origin, Auth::Worker, "machine.fork", args);
    call.team = Some("team_1".into());
    call
}

#[test]
fn a_fork_posts_the_key_and_visibility_and_answers_the_copy() {
    let (origin, seen) = fake(|_| ok(COPY));
    let args = json!({ "machine": PARENT, "clientKey": "place-s1", "visibility": "team" });
    let answer = go(&fork(&origin, args)).unwrap();
    assert_eq!(answer["id"], "vm_aaaaaaaaaaaaaaaaaaaa");
    assert_eq!(answer["state"], "running");
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].target(), format!("POST /v1/machines/{PARENT}/fork"));
    assert_eq!(seen[0].json(), json!({ "clientKey": "place-s1", "visibility": "team" }));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_1"));
}

#[test]
fn a_fork_without_visibility_sends_only_the_key() {
    let (origin, seen) = fake(|_| ok(COPY));
    go(&fork(&origin, json!({ "machine": PARENT, "clientKey": "k" }))).unwrap();
    assert_eq!(seen.lock().unwrap()[0].json(), json!({ "clientKey": "k" }));
}

#[test]
fn a_fork_at_a_ladder_size_sends_it() {
    let (origin, seen) = fake(|_| ok(COPY));
    go(&fork(&origin, json!({ "machine": PARENT, "clientKey": "k", "size": "xl" }))).unwrap();
    assert_eq!(seen.lock().unwrap()[0].json(), json!({ "clientKey": "k", "size": "xl" }));
}

#[test]
fn a_teammates_fork_is_refused_with_the_platforms_code() {
    let (origin, _seen) = fake(|_| Some((403, NOT_CREATOR.into())));
    let failure = go(&fork(&origin, json!({ "machine": PARENT, "clientKey": "k" }))).unwrap_err();
    assert!(
        matches!(&failure, Failure::Http { status: 403, code: Some(c), .. } if c == "machine.creator_only"),
        "{failure:?}"
    );
}

#[test]
fn a_fork_is_refused_before_any_request_on_stack_or_bad_args() {
    let (origin, seen) = fake(|_| ok(COPY));
    let mut call = fork(&origin, json!({ "machine": PARENT, "clientKey": "k" }));
    call.auth = Auth::Stack;
    assert!(matches!(go(&call), Err(Failure::Http { status: 501, .. })));
    let long = "k".repeat(129);
    for args in [
        json!({ "machine": "../v1/teams", "clientKey": "k" }),
        json!({ "machine": PARENT }),
        json!({ "machine": PARENT, "clientKey": "" }),
        json!({ "machine": PARENT, "clientKey": long }),
        json!({ "machine": PARENT, "clientKey": "k", "visibility": "public" }),
        json!({ "machine": PARENT, "clientKey": "k", "size": "huge" }),
    ] {
        assert!(matches!(go(&fork(&origin, args.clone())), Err(Failure::Transport(_))), "{args}");
    }
    assert!(seen.lock().unwrap().is_empty());
}
