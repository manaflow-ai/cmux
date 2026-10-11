//! Validation of v2 request params, results and errors against the operation catalog.

use super::*;

pub(super) fn operation_catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(CATALOG_JSON).expect("the checked-in resource operation catalog")
    })
}

pub(super) fn operation_descriptor(
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

pub(super) fn validate_catalog_params(
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

pub(super) fn contract_failure(
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

pub(super) fn validate_operation_result(
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

pub(super) fn validate_catalog_value(
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

pub(super) fn validate_primitive(
    value: &Value,
    descriptor: &Value,
    path: &str,
) -> Result<(), ResourceError> {
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

pub(super) fn validate_catalog_object(
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

pub(super) fn validate_resource_id(
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

pub(super) fn validate_length(
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

pub(super) fn validate_number(
    number: f64,
    descriptor: &Value,
    path: &str,
) -> Result<(), ResourceError> {
    if descriptor["minimum"].as_f64().is_some_and(|minimum| number < minimum)
        || descriptor["maximum"].as_f64().is_some_and(|maximum| number > maximum)
    {
        return Err(invalid_value(path, "number is outside its allowed range"));
    }
    Ok(())
}

pub(super) fn validate_param_alternatives(
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

pub(super) fn validate_operation_constraints(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
    supplied: &Map<String, Value>,
) -> Result<(), ResourceError> {
    if operation == ResourceOperation::TabRename {
        crate::resource_name::TabNameUpdate::parse(fields).map_err(resource_operation_error)?;
    }
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
            require_any(supplied, operation, &["name", "kind", "capabilities"])?;
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

pub(super) fn require_any(
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

pub(super) fn malformed_catalog(operation: &str, field: &str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        "embedded operation catalog is malformed",
        json!({"field":field}),
    )
}

pub(super) fn invalid_value(path: &str, message: &str) -> ResourceError {
    validation_error(message, json!({"path":path}))
}
