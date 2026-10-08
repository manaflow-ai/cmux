use super::*;
use crate::SurfaceOptions;

#[test]
fn terminal_host_launch_failures_keep_their_machine_readable_reason() {
    let failure = crate::terminal_host_protocol::HostLaunchFailure::bounded(
        crate::terminal_host_protocol::HostLaunchFailureKind::PtyCapacityExhausted,
        "terminal launch failed: PTY capacity exhausted".into(),
    );
    let error = resource_operation_error(anyhow::Error::new(failure));
    assert_eq!(error.code, "operation.failed");
    assert_eq!(error.details["operation"], "terminal.launch");
    assert_eq!(error.details["extra"]["reason_code"], "pty_capacity_exhausted");
}

fn catalog_fixture(descriptor: &Value, parameters: &HashMap<String, Value>) -> Value {
    match descriptor["kind"].as_str().expect("fixture descriptor kind") {
        "primitive" => match descriptor["name"].as_str().expect("fixture primitive name") {
            "json" => Value::Null,
            "string" => {
                Value::String("x".repeat(descriptor["min_length"].as_u64().unwrap_or(0) as usize))
            }
            "base64" => Value::String(String::new()),
            "boolean" => Value::Bool(false),
            "decimal" => Value::String("0".to_string()),
            "float64" => json!(descriptor["minimum"].as_f64().unwrap_or(0.0)),
            "uint16" | "uint32" => json!(descriptor["minimum"].as_u64().unwrap_or(0)),
            "int32" => json!(descriptor["minimum"].as_i64().unwrap_or(0)),
            name => panic!("unsupported fixture primitive {name}"),
        },
        "enum" => descriptor["values"]
            .as_array()
            .and_then(|values| values.first())
            .cloned()
            .expect("fixture enum value"),
        "array" => {
            let item = catalog_fixture(&descriptor["items"], parameters);
            Value::Array(vec![item; descriptor["min_items"].as_u64().unwrap_or(0) as usize])
        }
        "map" => Value::Object(Map::new()),
        "nullable" => Value::Null,
        "object" => {
            let mut object = Map::new();
            for (name, field) in descriptor["fields"].as_object().expect("fixture fields") {
                if field["required"] == Value::Bool(true) {
                    object.insert(name.clone(), catalog_fixture(&field["type"], parameters));
                }
            }
            Value::Object(object)
        }
        "ref" => {
            let name = descriptor["name"].as_str().expect("fixture ref name");
            catalog_fixture(&operation_catalog()["types"][name], parameters)
        }
        "apply" => {
            let name = descriptor["name"].as_str().expect("fixture generic name");
            let generic = &operation_catalog()["generics"][name];
            let mut bindings = parameters.clone();
            for (parameter, argument) in generic["parameters"]
                .as_array()
                .expect("fixture generic parameters")
                .iter()
                .zip(descriptor["arguments"].as_array().expect("fixture generic arguments"))
            {
                bindings.insert(
                    parameter.as_str().expect("fixture parameter name").to_string(),
                    argument.clone(),
                );
            }
            catalog_fixture(&generic["body"], &bindings)
        }
        "parameter" => {
            let name = descriptor["name"].as_str().expect("fixture parameter");
            catalog_fixture(parameters.get(name).expect("bound fixture parameter"), parameters)
        }
        "selector" => Value::String("current".to_string()),
        "resource_id" => {
            let resource = descriptor["resource"].as_str().expect("fixture resource");
            let prefix = match resource {
                "workspace" => "ws",
                "terminal" => "term",
                "frontend_projection" => "projection",
                "pairing_request" => "pairing",
                other => other,
            };
            Value::String(format!("{prefix}_{}", "0".repeat(32)))
        }
        "union" => catalog_fixture(
            descriptor["variants"]
                .as_array()
                .and_then(|variants| variants.first())
                .expect("fixture union variant"),
            parameters,
        ),
        kind => panic!("unsupported fixture kind {kind}"),
    }
}

fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("resource-router", SurfaceOptions::default())
}

#[test]
fn every_catalog_operation_has_one_concrete_owner() {
    let operations = operation_catalog()["operations"].as_object().unwrap();
    assert_eq!(operations.len(), 196);
    for name in operations.keys() {
        let operation: ResourceOperation =
            serde_json::from_value(Value::String(name.clone())).unwrap();
        assert_eq!(operation_name(operation), *name);
        match operation_owner(operation) {
            OperationOwner::Session => assert!(session::handles(operation)),
            OperationOwner::Content => assert!(content::handles(operation)),
            OperationOwner::Topology => assert!(topology::handles(operation)),
            OperationOwner::Auxiliary => assert!(auxiliary::handles(operation)),
            OperationOwner::State => assert!(crate::state::router::handles(operation)),
            OperationOwner::Git => assert!(crate::git_ops::handles(operation)),
            OperationOwner::Machine | OperationOwner::Snapshot | OperationOwner::Connection => {}
        }
    }
}

#[test]
fn every_catalog_operation_accepts_its_result_and_declared_error_fixtures() {
    let operations = operation_catalog()["operations"].as_object().unwrap();
    assert_eq!(operations.len(), 196);
    for (name, descriptor) in operations {
        let operation: ResourceOperation =
            serde_json::from_value(Value::String(name.clone())).unwrap();
        let result = catalog_fixture(&descriptor["result"], &HashMap::new());
        assert_eq!(
            validate_operation_outcome(operation, Ok(result.clone())).unwrap(),
            result,
            "{name} rejected its catalog result fixture"
        );
        let errors = descriptor["errors"].as_array().expect("operation error list");
        assert!(errors.iter().any(|code| code == "operation.failed"), "{name} cannot fail closed");
        for (code, error_descriptor) in
            operation_catalog()["errors"].as_object().expect("catalog errors")
        {
            let error = ResourceError {
                code: code.to_string(),
                message: "fixture".to_string(),
                details: catalog_fixture(&error_descriptor["details"], &HashMap::new()),
                retryable: error_descriptor["retryable"].as_bool().expect("error retryability"),
            };
            let validated = validate_operation_outcome(operation, Err(error.clone())).unwrap_err();
            if errors.iter().any(|declared| declared == code) {
                assert_eq!(validated, error, "{name} rejected declared error {code}");
            } else {
                assert_eq!(
                    validated.code, "operation.failed",
                    "{name} emitted undeclared error {code}"
                );
                assert_eq!(validated.details["operation"], *name);
                assert_eq!(validated.details["extra"]["emitted_code"], *code);
            }
        }
    }
}

#[test]
fn operation_contract_validation_rejects_nested_results_and_undeclared_errors() {
    let (_, descriptor) = operation_descriptor(ResourceOperation::TabCreateTerminal).unwrap();
    let mut wrong_nested_id = catalog_fixture(&descriptor["result"], &HashMap::new());
    wrong_nested_id["value"]["terminal_id"] = json!(format!("browser_{}", "0".repeat(32)));
    let invalid_result =
        validate_operation_outcome(ResourceOperation::TabCreateTerminal, Ok(wrong_nested_id))
            .unwrap_err();
    assert_eq!(invalid_result.code, "operation.failed");
    assert_eq!(invalid_result.details["operation"], "tab.create_terminal");
    assert_eq!(invalid_result.details["extra"]["contract"], "result");
    assert_eq!(
        invalid_result.details["extra"]["violation"]["field"],
        "tab.create_terminal.result.value.terminal_id"
    );

    let undeclared = validate_operation_outcome(
        ResourceOperation::SessionPing,
        Err(ResourceError::revision_conflict(1, 2)),
    )
    .unwrap_err();
    assert_eq!(undeclared.code, "operation.failed");
    assert_eq!(undeclared.details["operation"], "session.ping");
    assert_eq!(undeclared.details["extra"]["contract"], "error");
    assert_eq!(undeclared.details["extra"]["emitted_code"], "revision.conflict");

    let malformed_declared_error = validate_operation_outcome(
        ResourceOperation::SessionPing,
        Err(ResourceError {
            code: "validation.invalid".to_string(),
            message: "malformed".to_string(),
            details: json!({}),
            retryable: false,
        }),
    )
    .unwrap_err();
    assert_eq!(malformed_declared_error.code, "operation.failed");
    assert_eq!(malformed_declared_error.details["extra"]["contract"], "error");
}

fn request(id: &str, operation: &str, params: Value, idempotency_key: Option<&str>) -> String {
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": operation,
        "params": params,
    });
    if let Some(key) = idempotency_key {
        envelope["idempotency_key"] = json!(key);
    }
    serde_json::to_string(&envelope).unwrap()
}

#[test]
fn catalog_validation_rejects_extra_and_malformed_parameters() {
    let mux = test_mux();
    let extra = handle_resource_message(
        &mux,
        &request(
            "extra",
            "session.ping",
            json!({"machine":"current","session":"current","slot":3}),
            None,
        ),
    )
    .unwrap_err();
    assert_eq!(extra.code, "validation.invalid");

    let bad_decimal = handle_resource_message(
        &mux,
        &request(
            "decimal",
            "workspace.rename",
            json!({
                "machine":"current",
                "session":"current",
                "workspace":"current",
                "name":"renamed",
                "expected_revision":7,
            }),
            Some("rename-invalid-decimal"),
        ),
    )
    .unwrap_err();
    assert_eq!(bad_decimal.code, "validation.invalid");
}

#[test]
fn empty_workspace_create_and_rename_replay_through_public_ids() {
    let mux = test_mux();
    let create_message = request(
        "create-1",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "name":"first",
            "initial_content":"empty",
        }),
        Some("create-empty-workspace"),
    );
    let created = handle_resource_message(&mux, &create_message).unwrap();
    assert_eq!(created["ok"], true);
    let workspace_id = created["result"]["value"]["workspace_id"].as_str().unwrap().to_string();
    assert!(workspace_id.starts_with("ws_"));
    assert_eq!(created["result"]["replayed"], false);

    let replay = handle_resource_message(
        &mux,
        &request(
            "create-2",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"first",
                "initial_content":"empty",
            }),
            Some("create-empty-workspace"),
        ),
    )
    .unwrap();
    assert_eq!(replay["result"]["value"]["workspace_id"], workspace_id);
    assert_eq!(replay["result"]["replayed"], true);

    let renamed = handle_resource_message(
        &mux,
        &request(
            "rename-1",
            "workspace.rename",
            json!({
                "machine":"current",
                "session":"current",
                "workspace":workspace_id,
                "name":"renamed",
            }),
            Some("rename-empty-workspace"),
        ),
    )
    .unwrap();
    assert_eq!(renamed["ok"], true);
    assert_eq!(renamed["result"]["value"]["name"], "renamed");
    assert_eq!(renamed["result"]["value"]["id"], workspace_id);
    assert_eq!(renamed["result"]["replayed"], false);
}

#[test]
fn notification_effect_commits_once_and_replays_without_reposting() {
    let mux = test_mux();
    let params = json!({
        "machine":"current",
        "session":"current",
        "title":"Build finished",
        "body":"All checks passed",
        "level":"info",
    });
    let created = handle_resource_message(
        &mux,
        &request(
            "notification-1",
            "notification.create",
            params.clone(),
            Some("notification-effect-key"),
        ),
    )
    .unwrap();
    assert_eq!(created["ok"], true);
    assert_eq!(created["result"]["value"]["title"], "Build finished");
    assert_eq!(created["result"]["revision"], "1");
    assert_eq!(created["result"]["replayed"], false);
    let notification_id = created["result"]["value"]["id"].as_str().unwrap().to_string();
    let snapshot = public_session_snapshot(&mux).unwrap();
    assert_eq!(snapshot["cursor"]["revision"], created["result"]["revision"]);
    assert_eq!(snapshot["notifications"], json!([created["result"]["value"].clone()]));
    let events = mux.resource_events_after(0).unwrap();
    assert_eq!(events.head_revision.to_string(), created["result"]["revision"]);
    assert_eq!(events.batches.len(), 1);
    assert_eq!(events.batches[0].revision.to_string(), created["result"]["revision"]);
    assert_eq!(events.batches[0].changes[0]["resource"], "notification");
    assert_eq!(events.batches[0].changes[0]["id"], notification_id);
    assert_eq!(events.batches[0].changes[0]["value"], created["result"]["value"]);

    let replayed = handle_resource_message(
        &mux,
        &request("notification-2", "notification.create", params, Some("notification-effect-key")),
    )
    .unwrap();
    assert_eq!(replayed["ok"], true);
    assert_eq!(replayed["result"]["value"]["id"], notification_id);
    assert_eq!(replayed["result"]["revision"], "1");
    assert_eq!(replayed["result"]["replayed"], true);
    assert_eq!(mux.resource_notifications(256).len(), 1);
}

#[test]
fn run_validation_preserves_exact_argv_and_rejects_empty_executable() {
    let valid = parse_resource_request(&request(
        "run-valid",
        "workspace.run",
        json!({
            "machine":"current",
            "session":"current",
            "workspace":"current",
            "argv":["printf","","$HOME"],
        }),
        Some("run-valid-key"),
    ))
    .unwrap();
    assert_eq!(valid.fields["argv"], json!(["printf", "", "$HOME"]));

    let invalid = parse_resource_request(&request(
        "run-invalid",
        "workspace.run",
        json!({
            "machine":"current",
            "session":"current",
            "workspace":"current",
            "argv":[""],
        }),
        Some("run-invalid-key"),
    ))
    .unwrap_err();
    assert_eq!(invalid.code, "validation.invalid");
}
