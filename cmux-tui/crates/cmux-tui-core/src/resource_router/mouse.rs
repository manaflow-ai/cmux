//! Mouse input constraints the catalog types cannot express: which fields
//! each `kind` of a browser or terminal mouse event requires.

use super::*;

pub(super) fn validate_browser_mouse(fields: &Map<String, Value>) -> Result<(), ResourceError> {
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

pub(super) fn validate_terminal_mouse(fields: &Map<String, Value>) -> Result<(), ResourceError> {
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
