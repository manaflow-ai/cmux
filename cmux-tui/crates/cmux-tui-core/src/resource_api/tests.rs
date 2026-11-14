use super::{machine_capabilities, machine_platform};

#[test]
fn machine_platform_is_non_secret_and_capabilities_are_stable() {
    let platform = machine_platform();
    assert!(platform["os"].as_str().is_some_and(|value| !value.is_empty()));
    assert!(platform["arch"].as_str().is_some_and(|value| !value.is_empty()));

    assert_eq!(
        machine_capabilities(),
        serde_json::json!(["terminal", "workspace", "agent_session"])
    );
}

#[test]
fn an_indeterminate_session_open_reports_its_cause_to_the_daemon_log() {
    use super::ResourceMachineService as _;

    let mux = crate::Mux::new_for_test("dev", crate::SurfaceOptions::default());
    let diagnostics = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let sink = diagnostics.clone();
    assert!(mux.set_diagnostic_reporter(std::sync::Arc::new(move |message| {
        sink.lock().unwrap().push(message.to_string());
    })));
    let context = mux.local_resource_context().unwrap();
    let service = super::LocalResourceMachineService::new(std::sync::Arc::downgrade(&mux));
    let request = super::ResourceMachineRequest {
        operation: crate::resource::ResourceOperation::SessionOpen,
        selectors: crate::ResourceSelectors {
            machine: Some(context.machine_id.to_string()),
            session: Some(context.session_id.to_string()),
            ..Default::default()
        },
        fields: serde_json::Map::new(),
        idempotency_key: Some("session-open-cause".to_string()),
        actor: crate::Actor::local_user(),
    };
    mux.reject_resource_effect_commits_for_test();

    assert_eq!(service.dispatch(&request).unwrap_err().code, "mutation.indeterminate");
    assert_eq!(service.dispatch(&request).unwrap_err().code, "mutation.indeterminate");

    let diagnostics = diagnostics.lock().unwrap().clone();
    let reports = |cause: &str| {
        diagnostics
            .iter()
            .filter(|message| {
                message.contains("session.open")
                    && message.contains("session-open-cause")
                    && message.contains(cause)
            })
            .count()
    };
    assert_eq!(
        reports("injected outcome commit failure"),
        1,
        "the daemon log has no cause for the indeterminate open: {diagnostics:?}"
    );
    assert_eq!(
        reports("an earlier attempt"),
        1,
        "the daemon log has no cause for the indeterminate replay: {diagnostics:?}"
    );
}
