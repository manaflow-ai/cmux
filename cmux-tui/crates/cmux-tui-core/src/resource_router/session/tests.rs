use super::*;
use crate::SurfaceOptions;

fn request(
    operation: ResourceOperation,
    idempotency_key: &str,
    fields: Value,
) -> ParsedResourceRequest {
    ParsedResourceRequest {
        envelope: crate::resource::RequestEnvelope {
            protocol: crate::resource::PROTOCOL.to_string(),
            envelope_type: crate::resource::EnvelopeType::Request,
            id: crate::resource::RequestId::parse("session-effect").unwrap(),
            operation,
            params: json!({}),
            idempotency_key: Some(idempotency_key.to_string()),
            origin: None,
            credential: None,
        },
        selectors: crate::ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..Default::default()
        },
        fields: fields.as_object().unwrap().clone(),
        actor: crate::Actor::local_user(),
    }
}

#[test]
fn window_title_effect_replays_without_reemitting() {
    let mux = Mux::new_for_test("session-effects", SurfaceOptions::default());
    let events = mux.subscribe();
    let first = dispatch(
        &mux,
        request(
            ResourceOperation::SessionWindowTitleSet,
            "window-title-once",
            json!({"title":"one"}),
        ),
    )
    .unwrap();
    assert_eq!(first["replayed"], false);
    assert!(matches!(
        events.recv_timeout(std::time::Duration::from_millis(50)),
        Ok(MuxEvent::WindowTitleRequested(title)) if title == "one"
    ));
    let replay = dispatch(
        &mux,
        request(
            ResourceOperation::SessionWindowTitleSet,
            "window-title-once",
            json!({"title":"one"}),
        ),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    assert!(events.recv_timeout(std::time::Duration::from_millis(10)).is_err());
}

#[test]
fn shutdown_receipt_commits_without_starting_process_shutdown() {
    let mux = Mux::new_for_test("session-shutdown", SurfaceOptions::default());
    let first = commit_shutdown(
        &mux,
        request(ResourceOperation::SessionShutdown, "shutdown-once", json!({"force":true})),
    )
    .unwrap();
    assert_eq!(first["value"]["accepted"], true);
    assert_eq!(first["replayed"], false);
    assert!(!mux.daemon_shutdown_requested());

    let replay = commit_shutdown(
        &mux,
        request(ResourceOperation::SessionShutdown, "shutdown-once", json!({"force":true})),
    )
    .unwrap();
    assert_eq!(replay["value"]["accepted"], true);
    assert_eq!(replay["replayed"], true);
    assert!(!mux.daemon_shutdown_requested());
}

#[test]
fn stopped_owner_reload_replays_its_known_failure_receipt() {
    let mux = Mux::new_for_test("session-reload-failure", SurfaceOptions::default());
    mux.shutdown();
    let reload = || {
        dispatch(&mux, request(ResourceOperation::SessionReloadConfig, "reload-failure", json!({})))
            .unwrap_err()
    };

    let first = reload();
    let replay = reload();
    assert_eq!(first.code, "operation.failed");
    assert_eq!(first.message, "owner_stopped");
    assert_eq!(first.details["operation"], "session.reload_config");
    assert_eq!(first.details["reason"], "owner_stopped");
    assert_eq!(replay, first);
}

#[test]
fn timed_out_reload_remains_indeterminate_after_late_owner_completion() {
    let mux = Mux::new_for_test("session-reload-timeout", SurfaceOptions::default());
    let events = mux.subscribe_config_reload();
    let worker_mux = mux.clone();
    let worker = std::thread::spawn(move || {
        dispatch(
            &worker_mux,
            request(ResourceOperation::SessionReloadConfig, "reload-timeout", json!({})),
        )
        .unwrap_err()
    });

    assert!(matches!(
        events.recv_timeout(std::time::Duration::from_secs(1)),
        Ok(MuxEvent::ConfigReloadRequested)
    ));
    let first = worker.join().unwrap();
    let target = mux.begin_config_reload_application();
    mux.complete_config_reload_application(target);
    let replay = dispatch(
        &mux,
        request(ResourceOperation::SessionReloadConfig, "reload-timeout", json!({})),
    )
    .unwrap_err();

    assert_eq!(first.code, "mutation.indeterminate");
    assert_eq!(replay, first);
    assert!(events.recv_timeout(std::time::Duration::from_millis(50)).is_err());
}

#[test]
fn creation_resolve_returns_unknown_and_typed_validation_states() {
    let mux = Mux::new_for_test("creation-resolve", SurfaceOptions::default());
    let unknown = dispatch(
        &mux,
        request(
            ResourceOperation::SessionCreationResolve,
            "unused",
            json!({"correlation_key":"unknown-correlation"}),
        ),
    )
    .unwrap();
    assert_eq!(
        unknown,
        json!({
            "correlation_key":"unknown-correlation",
            "state":"not_applied",
            "recovery":"retry_new_idempotency_key",
        })
    );
    let error = dispatch(
        &mux,
        request(ResourceOperation::SessionCreationResolve, "unused", json!({"correlation_key":""})),
    )
    .unwrap_err();
    assert_eq!(error.code, "validation.invalid");
    assert_eq!(error.details["field"], "correlation_key");
}
