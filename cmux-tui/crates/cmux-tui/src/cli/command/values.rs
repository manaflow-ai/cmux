//! Typed flag values: parse one flag's string as a bool, number, decimal, color,
//! JSON object, id or selector, validate it, and insert it into request params.

use cmux_tui_core::resource::{id_prefix_parts, is_bare_id};
use serde_json::Number;

use super::*;

pub(super) fn parse_bool(flag: &str, value: &str) -> Result<bool, UsageError> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(UsageError::new(format!("{flag} must be true or false"))),
    }
}

pub(super) fn insert_optional_string(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
    field: &str,
) {
    if let Some(value) = flags.take(flag) {
        params.insert(field.into(), Value::String(value));
    }
}

pub(super) fn insert_optional_clearable_string(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    name: &str,
) -> Result<(), UsageError> {
    let value = flags.take(name);
    let clear = flags.boolean(&format!("clear-{name}"));
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{name} and --clear-{name} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(name.into(), Value::String(value));
            Ok(())
        }
        (None, true) => {
            params.insert(name.into(), Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

pub(super) fn insert_optional_nullable_string(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
) -> Result<(), UsageError> {
    let field = flag.replace('-', "_");
    let value = flags.take(flag);
    let clear_flag = format!("clear-{flag}");
    let clear = flags.boolean(&clear_flag);
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --{clear_flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(field, Value::String(value));
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

pub(super) fn insert_optional_nullable_bool(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
) -> Result<(), UsageError> {
    let field = flag.replace('-', "_");
    let value = flags.take(flag);
    let clear_flag = format!("clear-{flag}");
    let clear = flags.boolean(&clear_flag);
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --{clear_flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(field, Value::Bool(parse_bool(&format!("--{flag}"), &value)?));
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

pub(super) fn insert_optional_nullable_json_object(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
) -> Result<(), UsageError> {
    let field = flag.replace('-', "_");
    let value = flags.take(flag);
    let clear_flag = format!("clear-{flag}");
    let clear = flags.boolean(&clear_flag);
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --{clear_flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            let parsed = parse_json_object(&format!("--{flag}"), &value)?;
            params.insert(field, parsed);
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

pub(super) fn parse_json_object(flag: &str, value: &str) -> Result<Value, UsageError> {
    let value: Value = serde_json::from_str(value)
        .map_err(|error| UsageError::new(format!("invalid {flag} JSON: {error}")))?;
    if value.is_object() {
        Ok(value)
    } else {
        Err(UsageError::new(format!("{flag} must be a JSON object")))
    }
}

pub(super) fn validate_base64(flag: &str, value: &str) -> Result<(), UsageError> {
    BASE64
        .decode(value)
        .map(|_| ())
        .map_err(|error| UsageError::new(format!("{flag} is not canonical base64: {error}")))
}

pub(super) fn validate_terminal_defaults(params: &Map<String, Value>) -> Result<(), UsageError> {
    for field in
        ["foreground", "background", "cursor", "selection_background", "selection_foreground"]
    {
        if let Some(color) = params.get(field).and_then(Value::as_str) {
            validate_color(&format!("--{}", field.replace('_', "-")), color)?;
        }
    }
    if let Some(style) = params.get("cursor_style").and_then(Value::as_str) {
        validate_one_of("--cursor-style", style, &["block", "bar", "underline"])?;
    }
    if let Some(palette) = params.get("palette").and_then(Value::as_object) {
        for (index, color) in palette {
            let valid_index = index == "0"
                || (!index.starts_with('0')
                    && index.parse::<u16>().is_ok_and(|value| value <= 255));
            if !valid_index {
                return Err(UsageError::new(
                    "--palette keys must be canonical decimal indexes from 0 to 255",
                ));
            }
            let color = color
                .as_str()
                .ok_or_else(|| UsageError::new("--palette values must be color strings"))?;
            validate_color("--palette", color)?;
        }
    }
    Ok(())
}

fn validate_color(flag: &str, value: &str) -> Result<(), UsageError> {
    if value.len() == 7
        && value.starts_with('#')
        && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        Ok(())
    } else {
        Err(UsageError::new(format!("{flag} must use #rrggbb")))
    }
}

pub(super) fn insert_optional_enum_list(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    name: &str,
    allowed: &[&str],
) -> Result<(), UsageError> {
    let Some(value) = flags.take(name) else { return Ok(()) };
    let values = if value.is_empty() {
        Vec::new()
    } else {
        value.split(',').map(str::to_owned).collect::<Vec<_>>()
    };
    for value in &values {
        validate_one_of(&format!("--{name}"), value, allowed)?;
    }
    params.insert(name.replace('-', "_"), json!(values));
    Ok(())
}

pub(super) fn add_size(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    let cols = flags.take("cols");
    let rows = flags.take("rows");
    match (cols, rows) {
        (None, None) => Ok(()),
        (Some(cols), Some(rows)) => {
            insert_positive_u16(params, "cols", "--cols", cols)?;
            insert_positive_u16(params, "rows", "--rows", rows)
        }
        _ => Err(UsageError::new("--cols and --rows must be supplied together")),
    }
}

pub(super) fn add_required_size(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    insert_positive_u16(params, "cols", "--cols", flags.required("cols")?)?;
    insert_positive_u16(params, "rows", "--rows", flags.required("rows")?)
}

pub(super) fn add_pixel_size(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    let width = flags.take("width-px");
    let height = flags.take("height-px");
    match (width, height) {
        (None, None) => Ok(()),
        (Some(width), Some(height)) => {
            insert_positive_u32(params, "width_px", "--width-px", width)?;
            insert_positive_u32(params, "height_px", "--height-px", height)
        }
        _ => Err(UsageError::new("--width-px and --height-px must be supplied together")),
    }
}

pub(super) fn comma_separated(flag: &str, value: &str) -> Result<Vec<String>, UsageError> {
    let values = value.split(',').map(str::to_string).collect::<Vec<_>>();
    if values.is_empty()
        || values.len() > 64
        || values.iter().any(|value| value.is_empty() || value.len() > 256)
    {
        return Err(UsageError::new(format!(
            "{flag} must contain 1 to 64 non-empty comma-separated values",
        )));
    }
    Ok(values)
}

pub(super) fn parse_json_flag(flags: &mut Flags, name: &str) -> Result<Value, UsageError> {
    let value = flags.required(name)?;
    serde_json::from_str(&value)
        .map_err(|error| UsageError::new(format!("invalid --{name} JSON: {error}")))
}

pub(super) fn insert_u16(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u16>()
        .map_err(|_| UsageError::new(format!("{flag} must be an unsigned 16-bit integer")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

pub(super) fn insert_positive_u16(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u16>()
        .ok()
        .filter(|number| *number > 0)
        .ok_or_else(|| UsageError::new(format!("{flag} must be an integer from 1 to 65535")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

pub(super) fn insert_u32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u32>()
        .map_err(|_| UsageError::new(format!("{flag} must be an unsigned 32-bit integer")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

pub(super) fn insert_positive_u32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    insert_bounded_u32(params, field, flag, value, 1, u32::MAX)
}

pub(super) fn insert_bounded_u32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
    minimum: u32,
    maximum: u32,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u32>()
        .ok()
        .filter(|number| (minimum..=maximum).contains(number))
        .ok_or_else(|| {
            UsageError::new(format!("{flag} must be an integer from {minimum} to {maximum}"))
        })?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

pub(super) fn insert_i32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<i32>()
        .map_err(|_| UsageError::new(format!("{flag} must be a signed 32-bit integer")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

pub(super) fn insert_decimal(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    validate_decimal(flag, &value)?;
    params.insert(field.into(), Value::String(value));
    Ok(())
}

pub(super) fn insert_float(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite())
        .and_then(Number::from_f64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be a finite number")))?;
    params.insert(field.into(), Value::Number(number));
    Ok(())
}

pub(super) fn insert_ratio(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite() && *number > 0.0 && *number < 1.0)
        .and_then(Number::from_f64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be greater than 0 and less than 1")))?;
    params.insert(field.into(), Value::Number(number));
    Ok(())
}

pub(super) fn insert_viewport_width(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite() && (0.1..=1.0).contains(number))
        .and_then(Number::from_f64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be from 0.1 through 1")))?;
    params.insert(field.into(), Value::Number(number));
    Ok(())
}

pub(super) fn validate_selector(scope: &str, prefix: &str, value: &str) -> Result<(), UsageError> {
    let selector = Selector::parse(value).map_err(|error| UsageError::new(error.message))?;
    if matches!(selector, Selector::Id(_)) && !is_expanded_id_form(scope, prefix, value) {
        validate_prefixed_id(scope, prefix, value)?;
    }
    Ok(())
}

/// Whether `value` is an id form the daemon expands for `scope` (W5-P): a
/// bare id (32 hex digits, or a terminal's host id), a unique prefix of
/// `prefix`'s ids (`pane_3f`), and for a terminal also a tab or pane id in
/// any form (the terminal that tab or pane shows).
fn is_expanded_id_form(scope: &str, prefix: &str, value: &str) -> bool {
    let views: &[&str] = if scope == "terminal" { &["tab", "pane"] } else { &[] };
    is_bare_id(value)
        || id_prefix_parts(value)
            .is_some_and(|(given, _)| given == prefix || views.contains(&given))
        || views.iter().any(|view| validate_prefixed_id(scope, view, value).is_ok())
}

pub(super) fn validate_prefixed_id(
    scope: &str,
    prefix: &str,
    value: &str,
) -> Result<(), UsageError> {
    let Some(payload) = value.strip_prefix(&format!("{prefix}_")) else {
        return Err(UsageError::new(format!("{scope} ID must start with {prefix}_")));
    };
    if payload.len() != 32
        || !payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(UsageError::new(format!(
            "{scope} ID must contain exactly 32 lowercase hexadecimal digits"
        )));
    }
    Ok(())
}

pub(super) fn validate_direction(value: &str) -> Result<(), UsageError> {
    if matches!(value, "left" | "right" | "up" | "down") {
        Ok(())
    } else {
        Err(UsageError::new("direction must be left, right, up, or down"))
    }
}

pub(super) fn validate_decimal(flag: &str, value: &str) -> Result<(), UsageError> {
    if value == "0"
        || (!value.starts_with('0')
            && value.len() <= 20
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value.parse::<u64>().is_ok())
    {
        Ok(())
    } else {
        Err(UsageError::new(format!("{flag} must be a canonical unsigned decimal string")))
    }
}

pub(super) fn validate_operation_name(value: &str) -> Result<(), UsageError> {
    let mut parts = value.split('.');
    let Some(first) = parts.next() else {
        return Err(UsageError::new("operation name is empty"));
    };
    let rest = parts.collect::<Vec<_>>();
    if rest.is_empty()
        || !std::iter::once(first).chain(rest).all(|part| {
            !part.is_empty()
                && part.as_bytes()[0].is_ascii_lowercase()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
    {
        return Err(UsageError::new("operation must be a lowercase dotted name"));
    }
    Ok(())
}
