//! Shared `cmux.protocol/2` request parsing and dispatch.
//!
//! Unix sockets and WebSockets both call this module. The operation catalog is
//! embedded as the one validation source so transport handlers cannot drift.

mod auxiliary;
mod content;
mod effects;
mod session;
mod topology;

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Map, Value, json};

use crate::resource::{
    NotificationPublicId, RequestEnvelope, RequestId, ResourceError, ResourceOperation,
    ResponseEnvelope, Selector, TerminalPublicId, WireDecimal,
};
use crate::resource_api::{ResourceMachineRequest, operation_failed, public_session_snapshot};
use crate::workspace_registry::{ResourceEffectOutcome, ResourceEffectPreparation};
use crate::{Mux, ResolvedResourcePath, ResourceSelectors, ResourceTarget};

const CATALOG_JSON: &str = include_str!("../../../spec/resource-operations-v2.json");

/// Resolve a live terminal path or an unscoped durable terminal receipt.
/// Nested selectors keep normal topology containment, so a detached receipt
/// cannot satisfy a stale workspace, screen, pane, or tab path.
pub(crate) fn resolve_terminal_wait_exit_id(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<TerminalPublicId, ResourceError> {
    match mux.resolve_resource_path(ResourceTarget::Terminal, selectors) {
        Ok(path) => path.terminal.ok_or_else(|| ResourceError::not_found("terminal", "<resolved>")),
        Err(error) => {
            if selectors.workspace.is_some()
                || selectors.screen.is_some()
                || selectors.pane.is_some()
                || selectors.tab.is_some()
            {
                return Err(error);
            }
            let Some(raw) = selectors.terminal.as_deref() else {
                return Err(error);
            };
            let Ok(terminal_id) = TerminalPublicId::parse(raw) else {
                return Err(error);
            };
            let session_selectors = ResourceSelectors {
                machine: selectors.machine.clone(),
                session: selectors.session.clone(),
                ..ResourceSelectors::default()
            };
            mux.resolve_resource_path(ResourceTarget::Session, &session_selectors)?;
            match mux.has_durable_terminal_receipt(&terminal_id) {
                Ok(true) => {}
                Ok(false) => return Err(error),
                Err(registry_error) => return Err(resource_operation_error(registry_error)),
            }
            Ok(terminal_id)
        }
    }
}

fn operation_catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(CATALOG_JSON).expect("the checked-in resource operation catalog")
    })
}

fn operation_descriptor(
    operation: ResourceOperation,
) -> Result<(String, &'static Map<String, Value>), ResourceError> {
    let operation_name = operation_name(operation);
    let descriptor = operation_catalog()["operations"]
        .get(&operation_name)
        .and_then(Value::as_object)
        .ok_or_else(|| {
            ResourceError::operation_failed(
                operation_name.clone(),
                "operation is absent from the embedded catalog",
                json!({}),
            )
        })?;
    Ok((operation_name, descriptor))
}

fn validate_catalog_params(
    operation: ResourceOperation,
    params: &Value,
) -> Result<(ResourceSelectors, Map<String, Value>), ResourceError> {
    let (operation_name, descriptor) = operation_descriptor(operation)?;
    let params_descriptor = descriptor["params"].as_object().ok_or_else(|| {
        ResourceError::operation_failed(
            operation_name.clone(),
            "operation catalog params are malformed",
            json!({}),
        )
    })?;
    let input = params.as_object().expect("request envelope validates params");
    let selector_descriptors = params_descriptor["selectors"]
        .as_object()
        .ok_or_else(|| malformed_catalog(&operation_name, "selectors"))?;
    let field_descriptors = params_descriptor["fields"]
        .as_object()
        .ok_or_else(|| malformed_catalog(&operation_name, "fields"))?;

    let allowed = selector_descriptors
        .keys()
        .chain(field_descriptors.keys())
        .map(String::as_str)
        .collect::<HashSet<_>>();
    if params_descriptor["extra"] == Value::Bool(false) {
        let mut unknown =
            input.keys().filter(|key| !allowed.contains(key.as_str())).cloned().collect::<Vec<_>>();
        unknown.sort();
        if !unknown.is_empty() {
            return Err(validation_error(
                "request contains unknown parameters",
                json!({"operation":operation_name,"parameters":unknown}),
            ));
        }
    }

    let mut selector_values = Map::new();
    for (name, requiredness) in selector_descriptors {
        match input.get(name) {
            Some(value) => {
                let raw = value.as_str().ok_or_else(|| {
                    validation_error(
                        "selector must be a string",
                        json!({"operation":operation_name,"parameter":name}),
                    )
                })?;
                Selector::parse(raw)?;
                selector_values.insert(name.clone(), value.clone());
            }
            None if requiredness == "required" => {
                return Err(validation_error(
                    "required selector is missing",
                    json!({"operation":operation_name,"parameter":name}),
                ));
            }
            None => {}
        }
    }

    let mut fields = Map::new();
    for (name, field) in field_descriptors {
        let field = field.as_object().ok_or_else(|| malformed_catalog(&operation_name, name))?;
        match input.get(name) {
            Some(value) => {
                validate_catalog_value(
                    value,
                    &field["type"],
                    &format!("{operation_name}.{name}"),
                    &HashMap::new(),
                )?;
                fields.insert(name.clone(), value.clone());
            }
            None if field["required"] == Value::Bool(true) => {
                return Err(validation_error(
                    "required parameter is missing",
                    json!({"operation":operation_name,"parameter":name}),
                ));
            }
            None => {
                if let Some(default) = field.get("default") {
                    fields.insert(name.clone(), default.clone());
                }
            }
        }
    }

    validate_param_alternatives(&operation_name, params_descriptor, input)?;
    validate_operation_constraints(operation, &fields, input)?;
    let selectors = serde_json::from_value(Value::Object(selector_values)).map_err(|error| {
        validation_error(
            "selectors could not be decoded",
            json!({"operation":operation_name,"error":error.to_string()}),
        )
    })?;
    Ok((selectors, fields))
}

fn contract_failure(
    operation_name: &str,
    contract: &str,
    violation: &ResourceError,
) -> ResourceError {
    ResourceError::operation_failed(
        operation_name,
        format!("operation {contract} violates the embedded catalog"),
        json!({
            "contract":contract,
            "violation_code":violation.code,
            "violation":violation.details,
        }),
    )
}

fn validate_operation_result(
    operation: ResourceOperation,
    result: &Value,
) -> Result<(), ResourceError> {
    let (operation_name, descriptor) = operation_descriptor(operation)?;
    validate_catalog_value(
        result,
        &descriptor["result"],
        &format!("{operation_name}.result"),
        &HashMap::new(),
    )
    .map_err(|violation| contract_failure(&operation_name, "result", &violation))
}

pub(crate) fn validate_operation_error(
    operation: ResourceOperation,
    error: ResourceError,
) -> ResourceError {
    let (operation_name, descriptor) = match operation_descriptor(operation) {
        Ok(descriptor) => descriptor,
        Err(violation) => return contract_failure("catalog.validate", "error", &violation),
    };
    let declared = descriptor["errors"]
        .as_array()
        .is_some_and(|errors| errors.iter().any(|code| code.as_str() == Some(&error.code)));
    if !declared {
        return ResourceError::operation_failed(
            operation_name,
            "operation emitted an error code absent from its catalog contract",
            json!({"contract":"error","emitted_code":error.code}),
        );
    }
    let Some(error_descriptor) = operation_catalog()["errors"].get(&error.code) else {
        return ResourceError::operation_failed(
            operation_name,
            "operation emitted an error absent from the catalog",
            json!({"contract":"error","emitted_code":error.code}),
        );
    };
    let retryable_matches = error_descriptor["retryable"].as_bool() == Some(error.retryable);
    let details = validate_catalog_value(
        &error.details,
        &error_descriptor["details"],
        &format!("{operation_name}.error.{}.details", error.code),
        &HashMap::new(),
    );
    if retryable_matches && details.is_ok() {
        error
    } else {
        let violation = details.err().unwrap_or_else(|| {
            ResourceError::validation_invalid(
                Some("retryable"),
                "error retryability differs from the catalog",
            )
        });
        contract_failure(&operation_name, "error", &violation)
    }
}

pub(crate) fn validate_operation_outcome(
    operation: ResourceOperation,
    outcome: Result<Value, ResourceError>,
) -> Result<Value, ResourceError> {
    match outcome {
        Ok(result) => {
            validate_operation_result(operation, &result)?;
            Ok(result)
        }
        Err(error) => Err(validate_operation_error(operation, error)),
    }
}

fn validate_catalog_value(
    value: &Value,
    descriptor: &Value,
    path: &str,
    parameters: &HashMap<String, Value>,
) -> Result<(), ResourceError> {
    let kind = descriptor["kind"].as_str().ok_or_else(|| {
        ResourceError::operation_failed(
            "catalog.validate",
            "catalog type omitted its kind",
            json!({"path":path}),
        )
    })?;
    match kind {
        "primitive" => validate_primitive(value, descriptor, path),
        "enum" => {
            let matches =
                descriptor["values"].as_array().is_some_and(|values| values.contains(value));
            matches
                .then_some(())
                .ok_or_else(|| invalid_value(path, "value is outside the allowed enum"))
        }
        "array" => {
            let values =
                value.as_array().ok_or_else(|| invalid_value(path, "value must be an array"))?;
            validate_length(values.len(), descriptor, path, "items")?;
            for (index, item) in values.iter().enumerate() {
                validate_catalog_value(
                    item,
                    &descriptor["items"],
                    &format!("{path}[{index}]"),
                    parameters,
                )?;
            }
            Ok(())
        }
        "map" => {
            let values = value
                .as_object()
                .ok_or_else(|| invalid_value(path, "value must be an object map"))?;
            for (name, item) in values {
                validate_catalog_value(
                    item,
                    &descriptor["values"],
                    &format!("{path}.{name}"),
                    parameters,
                )?;
            }
            Ok(())
        }
        "nullable" => {
            if value.is_null() {
                Ok(())
            } else {
                validate_catalog_value(value, &descriptor["value"], path, parameters)
            }
        }
        "object" => validate_catalog_object(value, descriptor, path, parameters),
        "ref" => {
            let name =
                descriptor["name"].as_str().ok_or_else(|| malformed_catalog(path, "ref.name"))?;
            let target = operation_catalog()["types"]
                .get(name)
                .ok_or_else(|| malformed_catalog(path, name))?;
            validate_catalog_value(value, target, path, parameters)
        }
        "apply" => {
            let name =
                descriptor["name"].as_str().ok_or_else(|| malformed_catalog(path, "apply.name"))?;
            let generic = operation_catalog()["generics"]
                .get(name)
                .ok_or_else(|| malformed_catalog(path, name))?;
            let names = generic["parameters"]
                .as_array()
                .ok_or_else(|| malformed_catalog(path, "generic.parameters"))?;
            let arguments = descriptor["arguments"]
                .as_array()
                .ok_or_else(|| malformed_catalog(path, "apply.arguments"))?;
            if names.len() != arguments.len() {
                return Err(malformed_catalog(path, "generic argument count"));
            }
            let mut bindings = parameters.clone();
            for (name, argument) in names.iter().zip(arguments) {
                let name =
                    name.as_str().ok_or_else(|| malformed_catalog(path, "generic parameter"))?;
                bindings.insert(name.to_string(), argument.clone());
            }
            validate_catalog_value(value, &generic["body"], path, &bindings)
        }
        "parameter" => {
            let name = descriptor["name"]
                .as_str()
                .ok_or_else(|| malformed_catalog(path, "parameter.name"))?;
            let target = parameters.get(name).ok_or_else(|| malformed_catalog(path, name))?;
            validate_catalog_value(value, target, path, parameters)
        }
        "selector" => {
            let raw =
                value.as_str().ok_or_else(|| invalid_value(path, "selector must be a string"))?;
            Selector::parse(raw).map(|_| ())
        }
        "resource_id" => validate_resource_id(value, descriptor, path),
        "union" => {
            let variants = descriptor["variants"]
                .as_array()
                .ok_or_else(|| malformed_catalog(path, "union.variants"))?;
            let successes = variants
                .iter()
                .filter(|variant| validate_catalog_value(value, variant, path, parameters).is_ok())
                .count();
            if successes == 1 {
                Ok(())
            } else {
                Err(invalid_value(path, "value must match exactly one union variant"))
            }
        }
        _ => Err(malformed_catalog(path, kind)),
    }
}

fn validate_primitive(value: &Value, descriptor: &Value, path: &str) -> Result<(), ResourceError> {
    let name =
        descriptor["name"].as_str().ok_or_else(|| malformed_catalog(path, "primitive.name"))?;
    match name {
        "json" => Ok(()),
        "string" => {
            let raw =
                value.as_str().ok_or_else(|| invalid_value(path, "value must be a string"))?;
            validate_length(raw.len(), descriptor, path, "UTF-8 bytes")
        }
        "base64" => {
            let raw = value
                .as_str()
                .ok_or_else(|| invalid_value(path, "value must be a base64 string"))?;
            base64::engine::general_purpose::STANDARD
                .decode(raw)
                .map(|_| ())
                .map_err(|_| invalid_value(path, "value must use canonical base64"))
        }
        "boolean" => value
            .is_boolean()
            .then_some(())
            .ok_or_else(|| invalid_value(path, "value must be a boolean")),
        "decimal" => serde_json::from_value::<WireDecimal>(value.clone())
            .map(|_| ())
            .map_err(|_| invalid_value(path, "value must be an unsigned decimal string")),
        "float64" => {
            let number = value
                .as_f64()
                .filter(|number| number.is_finite())
                .ok_or_else(|| invalid_value(path, "value must be a finite number"))?;
            validate_number(number, descriptor, path)
        }
        "uint16" => {
            let number = value
                .as_u64()
                .filter(|number| *number <= u16::MAX.into())
                .ok_or_else(|| invalid_value(path, "value must be an unsigned 16-bit integer"))?;
            validate_number(number as f64, descriptor, path)
        }
        "uint32" => {
            let number = value
                .as_u64()
                .filter(|number| *number <= u32::MAX.into())
                .ok_or_else(|| invalid_value(path, "value must be an unsigned 32-bit integer"))?;
            validate_number(number as f64, descriptor, path)
        }
        "int32" => {
            let number = value
                .as_i64()
                .filter(|number| i32::try_from(*number).is_ok())
                .ok_or_else(|| invalid_value(path, "value must be a signed 32-bit integer"))?;
            validate_number(number as f64, descriptor, path)
        }
        _ => Err(malformed_catalog(path, name)),
    }
}

fn validate_catalog_object(
    value: &Value,
    descriptor: &Value,
    path: &str,
    parameters: &HashMap<String, Value>,
) -> Result<(), ResourceError> {
    let object = value.as_object().ok_or_else(|| invalid_value(path, "value must be an object"))?;
    let fields =
        descriptor["fields"].as_object().ok_or_else(|| malformed_catalog(path, "object.fields"))?;
    if descriptor["extra"] == Value::Bool(false) {
        let mut unknown =
            object.keys().filter(|name| !fields.contains_key(*name)).cloned().collect::<Vec<_>>();
        unknown.sort();
        if !unknown.is_empty() {
            return Err(validation_error(
                "object contains unknown fields",
                json!({"path":path,"fields":unknown}),
            ));
        }
    }
    for (name, field) in fields {
        let field = field.as_object().ok_or_else(|| malformed_catalog(path, name))?;
        match object.get(name) {
            Some(value) => validate_catalog_value(
                value,
                &field["type"],
                &format!("{path}.{name}"),
                parameters,
            )?,
            None if field["required"] == Value::Bool(true) => {
                return Err(validation_error(
                    "required object field is missing",
                    json!({"path":path,"field":name}),
                ));
            }
            None => {}
        }
    }
    Ok(())
}

fn validate_resource_id(
    value: &Value,
    descriptor: &Value,
    path: &str,
) -> Result<(), ResourceError> {
    let resource = descriptor["resource"]
        .as_str()
        .ok_or_else(|| malformed_catalog(path, "resource_id.resource"))?;
    let prefix = match resource {
        "workspace" => "ws",
        "terminal" => "term",
        "frontend_projection" => "projection",
        "pairing_request" => "pairing",
        other => other,
    };
    let raw = value.as_str().ok_or_else(|| invalid_value(path, "resource id must be a string"))?;
    let payload = raw
        .strip_prefix(&format!("{prefix}_"))
        .ok_or_else(|| invalid_value(path, "resource id has the wrong type prefix"))?;
    if payload.len() == 32
        && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(invalid_value(path, "resource id must contain 32 lowercase hex digits"))
    }
}

fn validate_length(
    length: usize,
    descriptor: &Value,
    path: &str,
    unit: &str,
) -> Result<(), ResourceError> {
    if descriptor["min_length"]
        .as_u64()
        .or_else(|| descriptor["min_items"].as_u64())
        .is_some_and(|minimum| length < minimum as usize)
    {
        return Err(invalid_value(path, &format!("value has too few {unit}")));
    }
    if descriptor["max_length"]
        .as_u64()
        .or_else(|| descriptor["max_items"].as_u64())
        .is_some_and(|maximum| length > maximum as usize)
    {
        return Err(invalid_value(path, &format!("value has too many {unit}")));
    }
    Ok(())
}

fn validate_number(number: f64, descriptor: &Value, path: &str) -> Result<(), ResourceError> {
    if descriptor["minimum"].as_f64().is_some_and(|minimum| number < minimum)
        || descriptor["maximum"].as_f64().is_some_and(|maximum| number > maximum)
    {
        return Err(invalid_value(path, "number is outside its allowed range"));
    }
    Ok(())
}

fn validate_param_alternatives(
    operation: &str,
    descriptor: &Map<String, Value>,
    input: &Map<String, Value>,
) -> Result<(), ResourceError> {
    let Some(alternatives) = descriptor.get("one_of").and_then(Value::as_array) else {
        return Ok(());
    };
    let matches = alternatives
        .iter()
        .filter(|alternative| {
            alternative["required"].as_array().is_none_or(|required| {
                required.iter().filter_map(Value::as_str).all(|name| input.contains_key(name))
            }) && alternative["forbidden"].as_array().is_none_or(|forbidden| {
                forbidden.iter().filter_map(Value::as_str).all(|name| !input.contains_key(name))
            })
        })
        .count();
    if matches == 1 {
        Ok(())
    } else {
        Err(validation_error(
            "request must match exactly one parameter alternative",
            json!({"operation":operation}),
        ))
    }
}

fn validate_operation_constraints(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
    supplied: &Map<String, Value>,
) -> Result<(), ResourceError> {
    if matches!(operation, ResourceOperation::PaneRun | ResourceOperation::WorkspaceRun)
        && let Some(argv) = fields.get("argv").and_then(Value::as_array)
        && argv.first().and_then(Value::as_str).is_none_or(str::is_empty)
    {
        return Err(invalid_value(
            &format!("{}.argv[0]", operation_name(operation)),
            "argv[0] must be non-empty",
        ));
    }
    if matches!(
        operation,
        ResourceOperation::BrowserAttach
            | ResourceOperation::TabCreateBrowser
            | ResourceOperation::PaneCreate
            | ResourceOperation::PaneRun
            | ResourceOperation::PaneSplit
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TerminalAttach
            | ResourceOperation::WorkspaceRun
    ) {
        let first = if matches!(
            operation,
            ResourceOperation::BrowserAttach | ResourceOperation::TabCreateBrowser
        ) {
            "width_px"
        } else {
            "cols"
        };
        let second = if first == "width_px" { "height_px" } else { "rows" };
        if fields.contains_key(first) != fields.contains_key(second) {
            return Err(validation_error(
                "paired size parameters must be sent together",
                json!({"operation":operation_name(operation),"parameters":[first,second]}),
            ));
        }
    }
    match operation {
        ResourceOperation::ClientMetadataUpdate => {
            require_any(supplied, operation, &["name", "kind"])?;
        }
        ResourceOperation::SessionTerminalDefaultsUpdate => {
            require_any(
                supplied,
                operation,
                &[
                    "foreground",
                    "background",
                    "cursor",
                    "selection_background",
                    "selection_foreground",
                    "palette",
                    "cursor_style",
                    "cursor_blink",
                    "complete",
                ],
            )?;
        }
        ResourceOperation::SessionJournalSubscribe
            if supplied.contains_key("cursor") && supplied.contains_key("start") =>
        {
            return Err(validation_error(
                "journal cursor and start are mutually exclusive",
                json!({"operation":operation_name(operation),"parameters":["cursor","start"]}),
            ));
        }
        ResourceOperation::PaneSplitRatioSet | ResourceOperation::PaneSplit => {
            if let Some(ratio) = fields.get("ratio").and_then(Value::as_f64)
                && !(0.0 < ratio && ratio < 1.0)
            {
                return Err(invalid_value(
                    &format!("{}.ratio", operation_name(operation)),
                    "ratio must be greater than zero and less than one",
                ));
            }
        }
        ResourceOperation::BrowserInputMouse => validate_browser_mouse(fields)?,
        ResourceOperation::TerminalInputMouse => validate_terminal_mouse(fields)?,
        _ => {}
    }
    Ok(())
}

fn require_any(
    fields: &Map<String, Value>,
    operation: ResourceOperation,
    names: &[&str],
) -> Result<(), ResourceError> {
    if names.iter().any(|name| fields.contains_key(*name)) {
        Ok(())
    } else {
        Err(validation_error(
            "at least one update parameter is required",
            json!({"operation":operation_name(operation),"parameters":names}),
        ))
    }
}

fn validate_browser_mouse(fields: &Map<String, Value>) -> Result<(), ResourceError> {
    let kind = fields["kind"].as_str().expect("catalog enum validation");
    let has_button = fields.contains_key("button");
    let has_click_count = fields.contains_key("click_count");
    if matches!(kind, "down" | "up") && !has_button {
        return Err(invalid_value(
            "browser.input.mouse.button",
            "button is required for down and up",
        ));
    }
    if kind == "move" && (has_button || has_click_count) {
        return Err(validation_error(
            "move forbids button and click_count",
            json!({"operation":"browser.input.mouse"}),
        ));
    }
    Ok(())
}

fn validate_terminal_mouse(fields: &Map<String, Value>) -> Result<(), ResourceError> {
    let kind = fields["kind"].as_str().expect("catalog enum validation");
    let has_button = fields.contains_key("button");
    let has_delta = fields.contains_key("delta_rows");
    let valid = match kind {
        "down" | "up" => has_button && !has_delta,
        "move" => !has_button && !has_delta,
        "wheel" => {
            !has_button
                && fields.get("delta_rows").and_then(Value::as_i64).is_some_and(|delta| delta != 0)
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(validation_error(
            "terminal mouse parameters do not match the input kind",
            json!({"operation":"terminal.input.mouse","kind":kind}),
        ))
    }
}

fn malformed_catalog(operation: &str, field: &str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        "embedded operation catalog is malformed",
        json!({"field":field}),
    )
}

fn invalid_value(path: &str, message: &str) -> ResourceError {
    validation_error(message, json!({"path":path}))
}

#[derive(Debug)]
pub(crate) struct ParsedResourceRequest {
    pub envelope: RequestEnvelope,
    pub selectors: ResourceSelectors,
    pub fields: Map<String, Value>,
}

pub(crate) fn is_resource_protocol_message(message: &str) -> bool {
    serde_json::from_str::<Value>(message)
        .ok()
        .and_then(|value| value.as_object().cloned())
        .is_some_and(|object| object.contains_key("protocol"))
}

#[cfg(test)]
pub(crate) fn handle_resource_message(
    mux: &Arc<Mux>,
    message: &str,
) -> Result<Value, ResourceError> {
    let request = parse_resource_request(message)?;
    handle_parsed_resource_request(mux, request)
}

pub(crate) fn handle_parsed_resource_request(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    let result = validate_operation_outcome(operation, dispatch_resource_request(mux, request));
    serde_json::to_value(match result {
        Ok(result) => ResponseEnvelope::success(id, result),
        Err(error) => ResponseEnvelope::failure(id, error),
    })
    .map_err(|error| {
        ResourceError::operation_failed(
            "response.encode",
            "could not encode protocol response",
            json!({"error":error.to_string()}),
        )
    })
}

pub(crate) fn commit_session_shutdown(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert_eq!(request.envelope.operation, ResourceOperation::SessionShutdown);
    session::commit_shutdown(mux, request)
}

pub(crate) fn handle_trusted_local_auxiliary(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    auxiliary::dispatch_trusted_local(mux, request)
}

pub(crate) fn malformed_resource_response(message: &str, error: ResourceError) -> Value {
    let request = serde_json::from_str::<Value>(message).ok();
    let id = request
        .as_ref()
        .and_then(|value| value.get("id").and_then(Value::as_str).map(str::to_string))
        .and_then(|id| RequestId::parse(id).ok())
        .unwrap_or_else(|| RequestId::parse("invalid").expect("static request id"));
    let error = request
        .as_ref()
        .and_then(|value| value.get("operation").cloned())
        .and_then(|operation| serde_json::from_value(operation).ok())
        .map_or(error.clone(), |operation| validate_operation_error(operation, error));
    serde_json::to_value(ResponseEnvelope::failure(id, error))
        .expect("resource failure envelopes are serializable")
}

pub(crate) fn parse_resource_request(
    message: &str,
) -> Result<ParsedResourceRequest, ResourceError> {
    if message.len() > crate::resource::MAX_MESSAGE_BYTES {
        return Err(validation_error(
            "request exceeds the protocol message limit",
            json!({"bytes":message.len(),"maximum":crate::resource::MAX_MESSAGE_BYTES}),
        ));
    }
    let envelope = serde_json::from_str::<RequestEnvelope>(message).map_err(|error| {
        validation_error("invalid request envelope", json!({"error":error.to_string()}))
    })?;
    envelope.validate()?;
    let (selectors, fields) = validate_catalog_params(envelope.operation, &envelope.params)?;
    Ok(ParsedResourceRequest { envelope, selectors, fields })
}

fn dispatch_resource_request(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation;
    match operation_owner(operation) {
        OperationOwner::Session => session::dispatch(mux, request),
        OperationOwner::Content => content::dispatch(mux, request),
        OperationOwner::Topology => topology::dispatch(mux, request),
        OperationOwner::Auxiliary => auxiliary::dispatch(mux, request),
        OperationOwner::Machine => {
            mux.resource_machine_service().dispatch(&ResourceMachineRequest {
                operation,
                selectors: request.selectors,
                fields: request.fields,
                idempotency_key: request.envelope.idempotency_key,
            })
        }
        OperationOwner::Snapshot => match operation {
            ResourceOperation::SessionSnapshot => {
                ensure_session_route(mux, &request.selectors)?;
                public_session_snapshot(mux)
            }
            ResourceOperation::SessionPing => {
                ensure_session_route(mux, &request.selectors)?;
                let snapshot = public_session_snapshot(mux)?;
                Ok(json!({"alive":true,"cursor":snapshot["cursor"]}))
            }
            ResourceOperation::TerminalList => list_resources(mux, &request.selectors, "terminals"),
            ResourceOperation::BrowserList => list_resources(mux, &request.selectors, "browsers"),
            ResourceOperation::TerminalGet => {
                get_resource(mux, &request.selectors, ResourceTarget::Terminal, "terminals")
            }
            ResourceOperation::BrowserGet => {
                get_resource(mux, &request.selectors, ResourceTarget::Browser, "browsers")
            }
            ResourceOperation::NotificationList => {
                ensure_session_route(mux, &request.selectors)?;
                let limit =
                    request.fields.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
                let snapshot = public_session_snapshot(mux)?;
                Ok(Value::Array(
                    snapshot["notifications"]
                        .as_array()
                        .expect("public snapshot notifications are an array")
                        .iter()
                        .take(limit)
                        .cloned()
                        .collect(),
                ))
            }
            ResourceOperation::NotificationCreate => create_notification(mux, request),
            _ => unreachable!("operation_owner classifies snapshot operations exhaustively"),
        },
        OperationOwner::Connection => Err(ResourceError::operation_failed(
            operation_name(operation),
            "the operation requires a live control-connection context",
            json!({"required_context":"control_connection"}),
        )),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OperationOwner {
    Machine,
    Session,
    Snapshot,
    Topology,
    Content,
    Auxiliary,
    Connection,
}

const fn operation_owner(operation: ResourceOperation) -> OperationOwner {
    match operation {
        ResourceOperation::MachineList
        | ResourceOperation::MachineGet
        | ResourceOperation::SessionList
        | ResourceOperation::SessionOpen
        | ResourceOperation::SessionGet => OperationOwner::Machine,
        ResourceOperation::SessionCreationResolve
        | ResourceOperation::SessionReloadConfig
        | ResourceOperation::SessionTerminalDefaultsUpdate
        | ResourceOperation::SessionWindowTitleSet
        | ResourceOperation::SessionWindowTitleClear => OperationOwner::Session,
        ResourceOperation::SessionSnapshot
        | ResourceOperation::SessionPing
        | ResourceOperation::TerminalList
        | ResourceOperation::TerminalGet
        | ResourceOperation::BrowserList
        | ResourceOperation::BrowserGet
        | ResourceOperation::NotificationList
        | ResourceOperation::NotificationCreate => OperationOwner::Snapshot,
        ResourceOperation::WorkspaceList
        | ResourceOperation::WorkspaceGet
        | ResourceOperation::WorkspaceCreate
        | ResourceOperation::WorkspaceRename
        | ResourceOperation::WorkspaceMove
        | ResourceOperation::WorkspaceFocus
        | ResourceOperation::WorkspaceClose
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::WorkspaceLayoutApply
        | ResourceOperation::ScreenList
        | ResourceOperation::ScreenGet
        | ResourceOperation::ScreenCreate
        | ResourceOperation::ScreenRename
        | ResourceOperation::ScreenFocus
        | ResourceOperation::ScreenClose
        | ResourceOperation::ScreenLayoutExport
        | ResourceOperation::ScreenLayoutUndo
        | ResourceOperation::PaneList
        | ResourceOperation::PaneGet
        | ResourceOperation::PaneCreate
        | ResourceOperation::PaneSplit
        | ResourceOperation::PaneRename
        | ResourceOperation::PaneFocus
        | ResourceOperation::PaneFocusDirection
        | ResourceOperation::PaneNeighborGet
        | ResourceOperation::PaneSwap
        | ResourceOperation::PaneZoom
        | ResourceOperation::PaneSplitRatioSet
        | ResourceOperation::PaneViewportWidthSet
        | ResourceOperation::PaneClose
        | ResourceOperation::PaneRun
        | ResourceOperation::TabList
        | ResourceOperation::TabGet
        | ResourceOperation::TabCreateTerminal
        | ResourceOperation::TabCreateBrowser
        | ResourceOperation::TabRename
        | ResourceOperation::TabMove
        | ResourceOperation::TabFocus
        | ResourceOperation::TabClose => OperationOwner::Topology,
        ResourceOperation::TerminalInputWrite
        | ResourceOperation::TerminalInputKeys
        | ResourceOperation::TerminalInputMouse
        | ResourceOperation::TerminalInputFocus
        | ResourceOperation::TerminalScreenRead
        | ResourceOperation::TerminalStateRead
        | ResourceOperation::TerminalHistoryRead
        | ResourceOperation::TerminalHistoryClear
        | ResourceOperation::TerminalOutputRead
        | ResourceOperation::TerminalWait
        | ResourceOperation::TerminalWaitExit
        | ResourceOperation::TerminalCopy
        | ResourceOperation::TerminalProcessGet
        | ResourceOperation::TerminalViewportScroll
        | ResourceOperation::TerminalMove
        | ResourceOperation::TerminalProject
        | ResourceOperation::TerminalClose
        | ResourceOperation::BrowserNavigate
        | ResourceOperation::BrowserBack
        | ResourceOperation::BrowserForward
        | ResourceOperation::BrowserReload
        | ResourceOperation::BrowserActivate
        | ResourceOperation::BrowserInputKey
        | ResourceOperation::BrowserInputText
        | ResourceOperation::BrowserInputMouse
        | ResourceOperation::BrowserInputWheel
        | ResourceOperation::BrowserClose => OperationOwner::Content,
        ResourceOperation::AgentList
        | ResourceOperation::AgentReport
        | ResourceOperation::FrontendProjectionGet
        | ResourceOperation::FrontendProjectionPut
        | ResourceOperation::SidebarViewGet
        | ResourceOperation::SidebarViewEnsure
        | ResourceOperation::SidebarViewInput
        | ResourceOperation::SidebarViewResize
        | ResourceOperation::SidebarViewReload => OperationOwner::Auxiliary,
        ResourceOperation::SessionEvents
        | ResourceOperation::SessionJournalSubscribe
        | ResourceOperation::SessionJournalProducerList
        | ResourceOperation::SessionJournalProducerPut
        | ResourceOperation::SessionJournalAppend
        | ResourceOperation::SessionJournalHookList
        | ResourceOperation::SessionJournalHookPut
        | ResourceOperation::SessionJournalCheckpointCreate
        | ResourceOperation::SessionJournalCheckpointList
        | ResourceOperation::SessionJournalRestorePreview
        | ResourceOperation::SessionJournalSegmentList
        | ResourceOperation::SessionJournalSegmentSeal
        | ResourceOperation::SessionShutdown
        | ResourceOperation::PairingRequestList
        | ResourceOperation::PairingRequestResolve
        | ResourceOperation::RequestCancel
        | ResourceOperation::ClientList
        | ResourceOperation::ClientGet
        | ResourceOperation::ClientMetadataUpdate
        | ResourceOperation::ClientSizingSet
        | ResourceOperation::ClientSizingRelease
        | ResourceOperation::ClientCellPixelsSet
        | ResourceOperation::ClientDetach
        | ResourceOperation::TerminalRendererGrantCreate
        | ResourceOperation::TerminalViewerResize
        | ResourceOperation::TerminalViewerRelease
        | ResourceOperation::TerminalAttach
        | ResourceOperation::BrowserViewerResize
        | ResourceOperation::BrowserViewerRelease
        | ResourceOperation::BrowserAttach
        | ResourceOperation::SidebarViewAttach
        | ResourceOperation::StreamCancel => OperationOwner::Connection,
    }
}

pub(crate) const fn requires_connection_context(operation: ResourceOperation) -> bool {
    matches!(operation_owner(operation), OperationOwner::Connection)
}

fn ensure_session_route(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<ResolvedResourcePath, ResourceError> {
    mux.resolve_resource_path(ResourceTarget::Session, selectors)
}

fn list_resources(
    mux: &Mux,
    selectors: &ResourceSelectors,
    collection: &str,
) -> Result<Value, ResourceError> {
    let path = resolve_list_scope(mux, selectors)?;
    let snapshot = public_session_snapshot(mux)?;
    let values = snapshot[collection]
        .as_array()
        .ok_or_else(|| {
            ResourceError::operation_failed(
                "session.snapshot",
                "public snapshot collection is malformed",
                json!({"collection":collection}),
            )
        })?
        .iter()
        .filter(|value| resource_is_in_path(&snapshot, collection, value, &path))
        .cloned()
        .collect();
    Ok(Value::Array(values))
}

fn resolve_list_scope(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<ResolvedResourcePath, ResourceError> {
    let target = if selectors.tab.is_some() {
        ResourceTarget::Tab
    } else if selectors.pane.is_some() {
        ResourceTarget::Pane
    } else if selectors.screen.is_some() {
        ResourceTarget::Screen
    } else if selectors.workspace.is_some() {
        ResourceTarget::Workspace
    } else {
        ResourceTarget::Session
    };
    mux.resolve_resource_path(target, selectors)
}

fn resource_is_in_path(
    snapshot: &Value,
    collection: &str,
    value: &Value,
    path: &ResolvedResourcePath,
) -> bool {
    let workspaces = snapshot["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|screen| Some((screen["id"].as_str()?, screen["workspace_id"].as_str()?)))
        .collect::<HashMap<_, _>>();
    let screens = snapshot["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|pane| Some((pane["id"].as_str()?, pane["screen_id"].as_str()?)))
        .collect::<HashMap<_, _>>();
    let panes = snapshot["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| Some((tab["id"].as_str()?, tab["pane_id"].as_str()?)))
        .collect::<HashMap<_, _>>();
    let id = value["id"].as_str();
    let (workspace, screen, pane, tab) = match collection {
        "workspaces" => (id, None, None, None),
        "screens" => (value["workspace_id"].as_str(), id, None, None),
        "panes" => {
            let screen = value["screen_id"].as_str();
            (screen.and_then(|id| workspaces.get(id).copied()), screen, id, None)
        }
        "tabs" => {
            let pane = value["pane_id"].as_str();
            let screen = pane.and_then(|id| screens.get(id).copied());
            (screen.and_then(|id| workspaces.get(id).copied()), screen, pane, id)
        }
        "terminals" | "browsers" => {
            let tab = value["tab_id"].as_str();
            let pane = tab.and_then(|id| panes.get(id).copied());
            let screen = pane.and_then(|id| screens.get(id).copied());
            (screen.and_then(|id| workspaces.get(id).copied()), screen, pane, tab)
        }
        _ => return false,
    };
    path.workspace.as_ref().is_none_or(|id| workspace == Some(id.as_str()))
        && path.screen.as_ref().is_none_or(|id| screen == Some(id.as_str()))
        && path.pane.as_ref().is_none_or(|id| pane == Some(id.as_str()))
        && path.tab.as_ref().is_none_or(|id| tab == Some(id.as_str()))
        && match collection {
            "terminals" => path.terminal.as_ref().is_none_or(|target| id == Some(target.as_str())),
            "browsers" => path.browser.as_ref().is_none_or(|target| id == Some(target.as_str())),
            _ => true,
        }
}

fn get_resource(
    mux: &Mux,
    selectors: &ResourceSelectors,
    target: ResourceTarget,
    collection: &str,
) -> Result<Value, ResourceError> {
    let path = mux.resolve_resource_path(target, selectors)?;
    let public_id = match target {
        ResourceTarget::Workspace => path.workspace.as_ref().map(ToString::to_string),
        ResourceTarget::Screen => path.screen.as_ref().map(ToString::to_string),
        ResourceTarget::Pane => path.pane.as_ref().map(ToString::to_string),
        ResourceTarget::Tab => path.tab.as_ref().map(ToString::to_string),
        ResourceTarget::Terminal => path.terminal.as_ref().map(ToString::to_string),
        ResourceTarget::Browser => path.browser.as_ref().map(ToString::to_string),
        ResourceTarget::Machine | ResourceTarget::Session => None,
    }
    .ok_or_else(|| ResourceError::not_found(collection, "<resolved>"))?;
    public_session_snapshot(mux)?[collection]
        .as_array()
        .and_then(|values| values.iter().find(|value| value["id"] == public_id))
        .cloned()
        .ok_or_else(|| ResourceError::not_found(collection.trim_end_matches('s'), &public_id))
}

fn create_notification(mux: &Mux, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let operation = "notification.create";
    let idempotency_key = request
        .envelope
        .idempotency_key
        .as_deref()
        .expect("validated mutations have an idempotency key");
    let fingerprint = json!({
        "operation": operation,
        "selectors": request.selectors,
        "fields": request.fields,
    });
    if let Some(preparation) = mux
        .lookup_resource_effect(idempotency_key, operation, &fingerprint)
        .map_err(resource_operation_error)?
    {
        return finish_notification_effect(mux, idempotency_key, &fingerprint, preparation);
    }

    ensure_session_route(mux, &request.selectors)?;
    let terminal_id = request
        .fields
        .get("terminal_id")
        .map(|value| {
            TerminalPublicId::parse(
                value.as_str().expect("catalog resource-id validation").to_string(),
            )
        })
        .transpose()?;
    if let Some(terminal_id) = &terminal_id
        && mux.resource_surface_for_terminal(terminal_id).is_none()
    {
        return Err(ResourceError::not_found("terminal", terminal_id.as_str()));
    }
    let notification_id = NotificationPublicId::random()?;
    let created_at_ms: u64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "system clock is before the Unix epoch",
                json!({"error":error.to_string()}),
            )
        })?
        .as_millis()
        .try_into()
        .map_err(|_| {
            ResourceError::operation_failed(
                "notification.create",
                "notification timestamp exceeds uint64",
                json!({}),
            )
        })?;
    let intent = json!({
        "notification_id": notification_id,
        "title": required_string(&request.fields, "title")?,
        "body": required_string(&request.fields, "body")?,
        "level": required_string(&request.fields, "level")?,
        "terminal_id": terminal_id,
        "created_at_ms": created_at_ms,
    });
    let preparation = mux
        .prepare_resource_effect(
            idempotency_key,
            operation,
            &fingerprint,
            &intent,
            None,
            expected_revision(&request.fields)?,
        )
        .map_err(resource_operation_error)?;
    finish_notification_effect(mux, idempotency_key, &fingerprint, preparation)
}

fn finish_notification_effect(
    mux: &Mux,
    idempotency_key: &str,
    fingerprint: &Value,
    preparation: ResourceEffectPreparation,
) -> Result<Value, ResourceError> {
    match preparation {
        ResourceEffectPreparation::Committed { outcome, revision } => match outcome {
            ResourceEffectOutcome::Success(value) => mutation_result(mux, value, revision, true),
            ResourceEffectOutcome::Failure(error) => Err(error),
        },
        ResourceEffectPreparation::Indeterminate => {
            Err(indeterminate_error(idempotency_key, "notification.create"))
        }
        ResourceEffectPreparation::Execute { .. } => {
            let intent = mux
                .mark_resource_effect_executing(idempotency_key, "notification.create", fingerprint)
                .map_err(resource_operation_error)?;
            execute_notification_effect(mux, idempotency_key, fingerprint, &intent)
        }
    }
}

fn execute_notification_effect(
    mux: &Mux,
    idempotency_key: &str,
    fingerprint: &Value,
    intent: &Value,
) -> Result<Value, ResourceError> {
    let notification_id: NotificationPublicId =
        serde_json::from_value(intent["notification_id"].clone()).map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid identity",
                json!({"error":error.to_string()}),
            )
        })?;
    let terminal_id = intent
        .get("terminal_id")
        .filter(|value| !value.is_null())
        .map(|value| serde_json::from_value::<TerminalPublicId>(value.clone()))
        .transpose()
        .map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid terminal identity",
                json!({"error":error.to_string()}),
            )
        })?;
    let surface =
        terminal_id.as_ref().and_then(|terminal_id| mux.resource_surface_for_terminal(terminal_id));
    if let Some(terminal_id) = terminal_id.as_ref().filter(|_| surface.is_none()) {
        let error = ResourceError::not_found("terminal", terminal_id.as_str());
        let outcome = ResourceEffectOutcome::Failure(error.clone());
        if mux
            .commit_resource_effect(
                idempotency_key,
                "notification.create",
                fingerprint,
                &outcome,
                None,
            )
            .is_err()
        {
            let _ = mux.mark_resource_effect_indeterminate(idempotency_key);
            return Err(indeterminate_error(idempotency_key, "notification.create"));
        }
        return Err(error);
    }
    let level = match required_string(
        intent
            .as_object()
            .ok_or_else(|| validation_error("stored effect intent is not an object", json!({})))?,
        "level",
    )? {
        "info" => crate::NotificationLevel::Info,
        "warning" => crate::NotificationLevel::Warning,
        "error" => crate::NotificationLevel::Error,
        other => {
            return Err(ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid level",
                json!({"level":other}),
            ));
        }
    };
    let title = intent.get("title").and_then(Value::as_str).ok_or_else(|| {
        ResourceError::operation_failed(
            "notification.create",
            "stored notification intent has an invalid title",
            json!({}),
        )
    })?;
    let body = intent.get("body").and_then(Value::as_str).ok_or_else(|| {
        ResourceError::operation_failed(
            "notification.create",
            "stored notification intent has an invalid body",
            json!({}),
        )
    })?;
    let created_at_ms = intent.get("created_at_ms").and_then(Value::as_u64).ok_or_else(|| {
        ResourceError::operation_failed(
            "notification.create",
            "stored notification intent has an invalid timestamp",
            json!({}),
        )
    })?;
    let session_id = mux.local_resource_context().map_err(resource_operation_error)?.session_id;
    mux.post_resource_notification(
        notification_id.clone(),
        title.to_string(),
        body.to_string(),
        level,
        surface,
        terminal_id.clone(),
        created_at_ms,
    );
    let mut value = json!({
        "id":notification_id,
        "session_id":session_id,
        "title":title,
        "body":body,
        "level":level.as_str(),
        "created_at_ms":created_at_ms.to_string(),
        "unread":surface
            .and_then(|surface| mux.surface_notification(surface))
            .is_some_and(|notification| notification.unread),
    });
    if let Some(terminal_id) = terminal_id {
        value["terminal_id"] = json!(terminal_id);
    }
    let outcome = ResourceEffectOutcome::Success(value.clone());
    let deltas = json!([{
        "kind":"upsert",
        "sequence":0,
        "resource":"notification",
        "id":notification_id,
        "value":value,
    }]);
    let revision = match mux.commit_resource_effect(
        idempotency_key,
        "notification.create",
        fingerprint,
        &outcome,
        Some(&deltas),
    ) {
        Ok(revision) => revision,
        Err(_) => {
            let _ = mux.mark_resource_effect_indeterminate(idempotency_key);
            return Err(indeterminate_error(idempotency_key, "notification.create"));
        }
    };
    mutation_result(mux, value, revision, false)
}

fn indeterminate_error(idempotency_key: &str, operation: &str) -> ResourceError {
    ResourceError::new(
        "mutation.indeterminate",
        "the external effect may have run before its outcome was recorded",
        json!({
            "idempotency_key":idempotency_key,
            "operation":operation,
            "recovery":"inspect_state_then_retry_with_new_key",
        }),
        false,
    )
}

pub(super) fn mutation_result(
    mux: &Mux,
    value: Value,
    revision: u64,
    replayed: bool,
) -> Result<Value, ResourceError> {
    let (_, generation) = mux.registry_identity();
    Ok(json!({
        "value": value,
        "generation": generation,
        "revision": revision.to_string(),
        "replayed": replayed,
    }))
}

pub(super) fn find_snapshot(
    snapshot: &Value,
    collection: &str,
    id: &str,
) -> Result<Value, ResourceError> {
    snapshot[collection]
        .as_array()
        .and_then(|values| values.iter().find(|value| value["id"] == id))
        .cloned()
        .ok_or_else(|| ResourceError::not_found(collection.trim_end_matches('s'), id))
}

pub(super) fn expected_revision(fields: &Map<String, Value>) -> Result<Option<u64>, ResourceError> {
    fields
        .get("expected_revision")
        .map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone()).map(WireDecimal::get).map_err(
                |error| {
                    validation_error(
                        "expected_revision must be an unsigned decimal string",
                        json!({"error":error.to_string()}),
                    )
                },
            )
        })
        .transpose()
}

pub(super) fn required_string<'a>(
    fields: &'a Map<String, Value>,
    field: &str,
) -> Result<&'a str, ResourceError> {
    fields
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| validation_error("required string field is missing", json!({"field":field})))
}

pub(super) fn optional_string(
    fields: &Map<String, Value>,
    field: &str,
) -> Result<Option<String>, ResourceError> {
    fields
        .get(field)
        .map(|value| {
            value
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| validation_error("field must be a string", json!({"field":field})))
        })
        .transpose()
}

pub(super) fn required_u64(fields: &Map<String, Value>, field: &str) -> Result<u64, ResourceError> {
    fields.get(field).and_then(Value::as_u64).ok_or_else(|| {
        validation_error("required unsigned integer field is missing", json!({"field":field}))
    })
}

pub(super) fn resource_operation_error(error: anyhow::Error) -> ResourceError {
    if let Some(resource) = error.downcast_ref::<ResourceError>() {
        return resource.clone();
    }
    if let Some(failure) = error.downcast_ref::<crate::terminal_host_protocol::HostLaunchFailure>()
    {
        return ResourceError::operation_failed(
            "terminal.launch",
            failure.message.clone(),
            json!({"reason_code":failure.kind.reason_code()}),
        );
    }
    let message = error.to_string();
    if message.starts_with("idempotency.conflict:") {
        let fields = message.split_whitespace().collect::<Vec<_>>();
        if let (Some(key), Some(operation)) = (fields.get(2), fields.get(4)) {
            return ResourceError::idempotency_conflict(key, operation);
        }
    }
    if let Some(conflict) = message.strip_prefix("resource revision conflict: expected ") {
        let mut values = conflict.split(", current ");
        if let (Some(expected), Some(actual)) = (values.next(), values.next())
            && let (Ok(expected), Ok(actual)) = (expected.parse(), actual.parse())
        {
            return ResourceError::revision_conflict(expected, actual);
        }
    }
    ResourceError::operation_failed("resource.runtime", message, json!({}))
}

pub(super) fn operation_name(operation: ResourceOperation) -> String {
    serde_json::to_value(operation)
        .expect("resource operations serialize")
        .as_str()
        .expect("resource operations serialize as strings")
        .to_string()
}

pub(super) fn validation_error(message: &str, details: Value) -> ResourceError {
    let field = details
        .get("field")
        .or_else(|| details.get("path"))
        .or_else(|| details.get("parameter"))
        .and_then(Value::as_str);
    ResourceError::validation_invalid(field, message)
}

#[cfg(test)]
mod tests {
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
                "string" => Value::String(
                    "x".repeat(descriptor["min_length"].as_u64().unwrap_or(0) as usize),
                ),
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
        assert_eq!(operations.len(), 125);
        for name in operations.keys() {
            let operation: ResourceOperation =
                serde_json::from_value(Value::String(name.clone())).unwrap();
            assert_eq!(operation_name(operation), *name);
            match operation_owner(operation) {
                OperationOwner::Session => assert!(session::handles(operation)),
                OperationOwner::Content => assert!(content::handles(operation)),
                OperationOwner::Topology => assert!(topology::handles(operation)),
                OperationOwner::Auxiliary => assert!(auxiliary::handles(operation)),
                OperationOwner::Machine | OperationOwner::Snapshot | OperationOwner::Connection => {
                }
            }
        }
    }

    #[test]
    fn every_catalog_operation_accepts_its_result_and_declared_error_fixtures() {
        let operations = operation_catalog()["operations"].as_object().unwrap();
        assert_eq!(operations.len(), 125);
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
            assert!(
                errors.iter().any(|code| code == "operation.failed"),
                "{name} cannot fail closed"
            );
            for (code, error_descriptor) in
                operation_catalog()["errors"].as_object().expect("catalog errors")
            {
                let error = ResourceError {
                    code: code.to_string(),
                    message: "fixture".to_string(),
                    details: catalog_fixture(&error_descriptor["details"], &HashMap::new()),
                    retryable: error_descriptor["retryable"].as_bool().expect("error retryability"),
                };
                let validated =
                    validate_operation_outcome(operation, Err(error.clone())).unwrap_err();
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
            &request(
                "notification-2",
                "notification.create",
                params,
                Some("notification-effect-key"),
            ),
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
}
