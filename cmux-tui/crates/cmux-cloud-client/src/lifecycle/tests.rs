use super::*;
use cmux_cloud_wire::{CloudMachine, CloudMachineStatus};
use serde_json::json;

fn scope() -> Scope {
    Scope::new("https://cloud-api.cmux.dev", Some("team_a")).expect("scope")
}

fn record(status: &str, revision: &str) -> CloudMachine {
    serde_json::from_value(json!({
        "id": "vm_test",
        "team": "team_a",
        "creator": "user_a",
        "name": null,
        "size": {"cpu": null, "memory_mb": null, "disk_mb": null},
        "status": status,
        "image": {"id": "img", "daemon_version": null},
        "host": null,
        "classic": false,
        "created_at": 0,
        "last_active_at": null,
        "idle_policy": {"idle_seconds": 0},
        "error": null,
        "revision": revision
    }))
    .expect("CloudMachine record")
}

#[test]
fn relay_completion_distinguishes_accepted_from_completed() {
    for status in ["pausing", "paused"] {
        let ObservedMachine::Running(vm) = observe(&scope(), record("running", "7")).unwrap()
        else {
            panic!()
        };
        let request = vm.prepare_pause("key");
        let observed =
            request.complete(json!({"machine":record(status, "8")}), "8".into()).unwrap();
        assert!(matches!(
            (&observed, status),
            (ObservedMachine::Pausing(_), "pausing") | (ObservedMachine::Paused(_), "paused")
        ));
    }
    for status in ["starting", "running"] {
        let ObservedMachine::Paused(vm) = observe(&scope(), record("paused", "7")).unwrap() else {
            panic!()
        };
        let observed = vm
            .prepare_resume("key")
            .complete(json!({"machine":record(status, "8")}), "8".into())
            .unwrap();
        assert!(matches!(
            (&observed, status),
            (ObservedMachine::Starting(_), "starting") | (ObservedMachine::Running(_), "running")
        ));
    }
}

#[test]
fn relay_bad_revision_retains_the_consumed_unknown_request() {
    for revision in ["6", "", "future"] {
        let ObservedMachine::Running(vm) = observe(&scope(), record("running", "7")).unwrap()
        else {
            panic!()
        };
        let (request, _) = *vm
            .prepare_pause("original")
            .complete(json!({"machine":record("pausing", revision)}), revision.into())
            .unwrap_err();
        assert_eq!(request.key(), "original");
        assert_eq!(request.revision(), "7");
        assert_eq!(request.op(), "cloud.machine.pause");
        assert_eq!(request.params(), json!({"machine":"vm_test"}));
    }
}

#[test]
fn an_old_observation_cannot_restore_running_after_an_uncertain_pause() {
    let ObservedMachine::Running(vm) = observe(&scope(), record("running", "7")).unwrap() else {
        panic!()
    };
    let pending = Pending::new(vm, Intent::Pause, "same-key".into()).into_unknown();
    let (pending, error) = *pending.reconcile(record("running", "7")).unwrap_err();
    assert_eq!(error, ObserveError::InvalidRevision);
    assert_eq!(pending.key(), "same-key");
    assert_eq!(pending.revision(), "7");
}

#[test]
fn provider_status_is_strict_at_the_capability_boundary() {
    let mut future = record("running", "7");
    future.status = CloudMachineStatus::Unknown("ready".to_owned());
    assert!(matches!(observe(&scope(), future), Err(ObserveError::InvalidStatus)));

    for word in ["stopped", "destroyed", "deleted", "unknown"] {
        let mut extra = record("running", "7");
        extra.status = CloudMachineStatus::Unknown(word.to_owned());
        assert!(matches!(observe(&scope(), extra), Err(ObserveError::InvalidStatus)), "{word}");
    }
}

#[test]
fn a_record_from_another_team_is_refused_before_any_operation() {
    let mut other = record("running", "7");
    other.team = "team_b".to_owned();
    assert!(matches!(observe(&scope(), other), Err(ObserveError::TeamMismatch { .. })));
}

#[tokio::test]
async fn a_foreign_capability_is_refused_before_the_request_is_sent() {
    let owner = scope();
    let other = Scope::new("https://cloud-api.cmux.dev", Some("team_b")).expect("scope");
    let client = LifecycleClient::new(other, "token", "test").expect("client");
    let ObservedMachine::Running(capability) =
        observe(&owner, record("running", "7")).expect("running")
    else {
        panic!("running status")
    };
    let error = capability.pause(&client, "ck_foreign").await.expect_err("foreign handle");
    let MutationErrorParts::Api { source, .. } = error.into_parts() else {
        panic!("a foreign handle is a local refusal")
    };
    assert_eq!(source.code.as_deref(), Some("cloud.client.unreadable"));
    assert!(source.status.is_none(), "the foreign handle was rejected locally");
}

#[test]
fn a_mutation_answer_must_name_the_mutated_machine() {
    let ObservedMachine::Running(expected) = observe(&scope(), record("running", "7")).unwrap()
    else {
        panic!("running")
    };
    let mut other = record("pausing", "8");
    other.id = "vm_other".to_owned();
    let error = pause_response(&scope(), expected.payload(), other, "8".to_owned())
        .expect_err("identity mismatch");
    assert!(error.message.contains("another machine"));
}

#[tokio::test]
async fn a_lost_mutation_answer_keeps_the_same_key_and_revision() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let origin = format!("http://{}", listener.local_addr().expect("address"));
    let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        if let Ok((mut stream, _)) = listener.accept().await {
            use tokio::io::AsyncReadExt;
            let mut request = Vec::new();
            let mut chunk = [0; 4096];
            loop {
                let length = stream.read(&mut chunk).await.unwrap_or(0);
                if length == 0 {
                    break;
                }
                request.extend_from_slice(&chunk[..length]);
                let lower = String::from_utf8_lossy(&request).to_ascii_lowercase();
                let complete = lower.find("\r\n\r\n").is_some_and(|headers_end| {
                    let body_length = lower[..headers_end]
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length: "))
                        .and_then(|value| value.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    request.len() >= headers_end + 4 + body_length
                });
                if complete {
                    break;
                }
            }
            let _ = seen_tx.send(String::from_utf8_lossy(&request).into_owned());
            drop(stream);
        }
    });
    let scope = Scope::new(&origin, Some("team_a")).expect("scope");
    let client = LifecycleClient::new(scope.clone(), "token", "test").expect("client");
    let observed = observe(&scope, record("running", "7")).expect("running");
    let ObservedMachine::Running(capability) = observed else { panic!("running status") };
    let error = capability.pause(&client, "ck_lost").await.expect_err("lost answer");
    let MutationErrorParts::Uncertain { pending, source } = error.into_parts() else {
        panic!("a lost answer must consume the stable capability")
    };
    assert_eq!(pending.key(), "ck_lost");
    assert_eq!(pending.revision(), "7");
    assert_eq!(pending.intent(), Intent::Pause);
    assert!(source.retryable, "a missing answer is safe to retry");
    let request = seen_rx.await.expect("request captured");
    assert!(request.contains("\"idempotency_key\":\"ck_lost\""));
    assert!(request.contains("\"expected_revision\":\"7\""));

    let (reconciled, intent, key) = pending.reconcile(record("pausing", "8")).unwrap().into_parts();
    assert_eq!(intent, Intent::Pause);
    assert_eq!(key, "ck_lost");
    assert!(matches!(reconciled, ObservedMachine::Pausing(_)));
}

fn unresolved(scope: &Scope) -> Pending<Unknown> {
    let ObservedMachine::Running(state) = observe(scope, record("running", "7")).unwrap() else {
        panic!("running")
    };
    Pending::new(state, Intent::Pause, "ck_same".into()).into_unknown()
}

#[test]
fn reconciliation_rejects_foreign_records_without_losing_the_pending_intent() {
    // Machine credentials carry no team header; the original record still binds its team.
    let scope = Scope::new("https://cloud-api.cmux.dev", None).unwrap();
    let mut pending = unresolved(&scope);
    for kind in ["machine", "team", "status"] {
        let mut wrong = record("paused", "8");
        match kind {
            "machine" => wrong.id = "vm_other".into(),
            "team" => wrong.team = "team_other".into(),
            _ => wrong.status = CloudMachineStatus::Unknown("ready".into()),
        }
        let (kept, error) = *pending.reconcile(wrong).unwrap_err();
        match kind {
            "machine" => assert!(matches!(error, ObserveError::MachineMismatch)),
            "team" => assert!(matches!(error, ObserveError::TeamMismatch { .. })),
            _ => assert!(matches!(error, ObserveError::InvalidStatus)),
        }
        assert_eq!(kept.key(), "ck_same");
        assert_eq!(kept.revision(), "7");
        pending = kept;
    }
    let reconciled = pending.reconcile(record("paused", "8")).unwrap();
    assert_eq!(reconciled.original_revision(), "7");
    let (ObservedMachine::Paused(state), intent, key) = reconciled.into_parts() else {
        panic!("authoritative paused observation")
    };
    assert_eq!(state.machine().id(), "vm_test");
    assert_eq!(state.revision(), "8");
    assert_eq!(intent, Intent::Pause);
    assert_eq!(key, "ck_same");
}

#[test]
fn unscoped_credentials_do_not_accept_a_response_from_another_team() {
    let scope = Scope::new("https://cloud-api.cmux.dev", None).unwrap();
    let ObservedMachine::Running(state) = observe(&scope, record("running", "7")).unwrap() else {
        panic!("running")
    };
    let mut other = record("pausing", "8");
    other.team = "team_other".into();
    assert!(pause_response(&scope, state.payload(), other, "8".into()).is_err());
}

#[test]
fn indeterminate_refusal_is_unknown_even_with_http_200() {
    let ObservedMachine::Running(state) = observe(&scope(), record("running", "7")).unwrap() else {
        panic!("running")
    };
    let source = ApiError {
        status: Some(200),
        tag: None,
        code: Some("mutation.indeterminate".into()),
        message: "unknown outcome".into(),
        retryable: true,
        retry_after: None,
    };
    let error = mutation_error(Pending::new(state, Intent::Pause, "ck_same".into()), source);
    assert!(matches!(error, MutationError::Uncertain { .. }));
}

async fn request(stream: &mut tokio::net::TcpStream) -> String {
    use tokio::io::AsyncReadExt;
    let mut bytes = Vec::new();
    let mut chunk = [0; 4096];
    loop {
        let count = stream.read(&mut chunk).await.unwrap();
        assert!(count > 0, "connection ended before the request");
        bytes.extend_from_slice(&chunk[..count]);
        let lower = String::from_utf8_lossy(&bytes).to_ascii_lowercase();
        if let Some(end) = lower.find("\r\n\r\n") {
            let length: usize = lower[..end]
                .lines()
                .find_map(|line| line.strip_prefix("content-length: "))
                .unwrap()
                .parse()
                .unwrap();
            if bytes.len() >= end + 4 + length {
                return String::from_utf8(bytes).unwrap();
            }
        }
    }
}

async fn respond(stream: &mut tokio::net::TcpStream, op: &str, value: serde_json::Value) {
    use tokio::io::AsyncWriteExt;
    let body = json!({"ok":true,"op":op,"value":value,"transaction":"t",
        "idempotency_key": if op.ends_with("delete") { "ck_delete" } else { "ck_same" },"revision":"8","replayed":true,"stream":"s","sequence":2})
    .to_string();
    stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).as_bytes()).await.unwrap();
}

#[tokio::test]
async fn a_lost_answer_replays_the_exact_intent_without_regranting_running() {
    crate::test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let scope =
        Scope::new(&format!("http://{}", listener.local_addr().unwrap()), Some("team_a")).unwrap();
    let server = tokio::spawn(async move {
        let (mut first, _) = listener.accept().await.unwrap();
        let first_request = request(&mut first).await;
        drop(first);
        let (mut second, _) = listener.accept().await.unwrap();
        let second_request = request(&mut second).await;
        respond(&mut second, "cloud.machine.pause", json!({"machine":record("pausing", "8")}))
            .await;
        (first_request, second_request)
    });
    let client = LifecycleClient::new(scope.clone(), "token", "test").unwrap();
    let ObservedMachine::Running(state) = observe(&scope, record("running", "7")).unwrap() else {
        panic!("running")
    };
    let MutationError::Uncertain { pending, .. } =
        state.pause(&client, "ck_same").await.unwrap_err()
    else {
        panic!("uncertain")
    };
    let MutationOutcome::Pausing(state) = pending.retry(&client).await.unwrap() else {
        panic!("pausing")
    };
    assert_eq!(state.revision(), "8");
    let (first, second) = server.await.unwrap();
    let body = |request: &str| -> serde_json::Value {
        serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap()
    };
    assert_eq!(body(&first), body(&second));
    assert_eq!(body(&second)["expected_revision"], "7");
    assert_eq!(body(&second)["idempotency_key"], "ck_same");
    assert!(second.to_ascii_lowercase().contains("x-cmux-team: team_a"));
    assert!(second.to_ascii_lowercase().contains("authorization: bearer token"));
}

#[tokio::test]
async fn resume_and_delete_return_only_authoritatively_confirmed_states() {
    crate::test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let scope =
        Scope::new(&format!("http://{}", listener.local_addr().unwrap()), Some("team_a")).unwrap();
    let server = tokio::spawn(async move {
        for (op, value) in [
            ("cloud.machine.start", json!({"machine":record("starting", "8")})),
            ("cloud.machine.delete", json!({"deleted":true})),
        ] {
            let (mut stream, _) = listener.accept().await.unwrap();
            let seen = request(&mut stream).await;
            let body: serde_json::Value =
                serde_json::from_str(seen.split_once("\r\n\r\n").unwrap().1).unwrap();
            assert_eq!(body["op"], op);
            assert_eq!(body["params"]["machine"], "vm_test");
            assert_eq!(body["expected_revision"], if op.ends_with("start") { "7" } else { "8" });
            respond(&mut stream, op, value).await;
        }
    });
    let client = LifecycleClient::new(scope.clone(), "token", "test").unwrap();
    let ObservedMachine::Paused(state) = observe(&scope, record("paused", "7")).unwrap() else {
        panic!("paused")
    };
    let state = state.resume(&client, "ck_same").await.unwrap();
    assert_eq!(state.revision(), "8");
    let state = state.delete(&client, "ck_delete").await.unwrap();
    assert_eq!(state.machine().id(), "vm_test");
    assert_eq!(state.revision(), "8");
    server.await.unwrap();
}

#[tokio::test]
async fn backend_and_team_mismatch_refuse_every_mutation_before_io() {
    crate::test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let client =
        LifecycleClient::new(Scope::new(&origin, Some("team_a")).unwrap(), "token", "test")
            .unwrap();
    for owner in [
        Scope::new(&origin, Some("team_b")).unwrap(),
        Scope::new("http://127.0.0.1:1", Some("team_a")).unwrap(),
    ] {
        let mut running = record("running", "7");
        running.team = owner.team().unwrap().into();
        let ObservedMachine::Running(state) = observe(&owner, running.clone()).unwrap() else {
            panic!("running")
        };
        assert!(matches!(state.pause(&client, "key").await, Err(MutationError::Api { .. })));
        let ObservedMachine::Running(state) = observe(&owner, running).unwrap() else {
            panic!("running")
        };
        assert!(matches!(state.delete(&client, "key").await, Err(MutationError::Api { .. })));
        let mut paused = record("paused", "7");
        paused.team = owner.team().unwrap().into();
        let ObservedMachine::Paused(state) = observe(&owner, paused).unwrap() else {
            panic!("paused")
        };
        assert!(matches!(state.resume(&client, "key").await, Err(MutationError::Api { .. })));
    }
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(10), listener.accept())
            .await
            .is_err(),
        "no mutation should connect"
    );
}

#[tokio::test]
async fn an_answer_for_another_intent_cannot_complete_pause() {
    crate::test_tls();
    for wrong_op in [false, true] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let scope =
            Scope::new(&format!("http://{}", listener.local_addr().unwrap()), Some("team_a"))
                .unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            request(&mut stream).await;
            respond(
                &mut stream,
                if wrong_op { "cloud.machine.start" } else { "cloud.machine.pause" },
                json!({"machine":record("pausing", "8")}),
            )
            .await;
        });
        let client = LifecycleClient::new(scope.clone(), "token", "test").unwrap();
        let ObservedMachine::Running(state) = observe(&scope, record("running", "7")).unwrap()
        else {
            panic!("running")
        };
        let key = if wrong_op { "ck_same" } else { "ck_different" };
        let MutationError::Uncertain { pending, .. } = state.pause(&client, key).await.unwrap_err()
        else {
            panic!("wrong receipt must be uncertain")
        };
        assert_eq!(pending.key(), key);
        assert_eq!(pending.revision(), "7");
        server.await.unwrap();
    }
}
