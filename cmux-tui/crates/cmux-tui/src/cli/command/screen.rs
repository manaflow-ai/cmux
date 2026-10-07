//! The `screen` noun: list, create, show, rename, focus, update, close,
//! layout export and undo, viewport columns, and the panes inside a screen.

use super::*;

pub(super) fn parse_screen(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    parse_screen_strings(&refs, selectors, flags, argv)
}

pub(super) fn parse_screen_strings(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    match words {
        ["group", rest @ ..] => state::parse_screen_group(rest, selectors, flags),
        ["list"] => request(ResourceOperation::ScreenList, selectors, flags, Map::new()),
        ["create"] => {
            let mut params = Map::new();
            insert_optional_string(&mut params, flags, "name", "name");
            request(ResourceOperation::ScreenCreate, selectors, flags, params)
        }
        [selector, "show"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenGet, selectors, flags, Map::new())
        }
        [selector, "rename"] => {
            selectors.insert("screen", "screen", selector)?;
            request_with_required_name(ResourceOperation::ScreenRename, selectors, flags)
        }
        [selector, "focus"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenFocus, selectors, flags, Map::new())
        }
        [selector, action @ ("update" | "pin" | "unpin" | "move")] => {
            selectors.insert("screen", "screen", selector)?;
            state::screen_change(action, selectors, flags)
        }
        [selector, "close"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenClose, selectors, flags, Map::new())
        }
        [selector, "layout", "export"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenLayoutExport, selectors, flags, Map::new())
        }
        [selector, "layout", "undo"] => {
            selectors.insert("screen", "screen", selector)?;
            let mut params = Map::new();
            if flags.boolean("confirm-close") {
                params.insert("confirm_close".into(), Value::Bool(true));
            }
            if let Some(token) = flags.take("confirmation-token") {
                validate_bounded_text("--confirmation-token", &token)?;
                params.insert("confirmation_token".into(), Value::String(token));
            }
            request(ResourceOperation::ScreenLayoutUndo, selectors, flags, params)
        }
        [selector, "column", column, "update"] => {
            selectors.insert("screen", "screen", selector)?;
            column_update(column, selectors, flags)
        }
        [selector, "pane", tail @ ..] => {
            selectors.insert("screen", "screen", selector)?;
            parse_pane_strings(tail, selectors, flags, argv)
        }
        _ => usage("screen action"),
    }
}

/// `screen <selector> column <split_id> update`: the resource op
/// `column.update` (pin, unpin, or resize one viewport column).
fn column_update(
    column: &str,
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    validate_prefixed_id("column", "split", column)?;
    let mut params = map_with("column", Value::String(column.to_string()));
    if let Some(dock) = flags.take("dock") {
        params.insert("dock".into(), Value::Bool(parse_bool("--dock", &dock)?));
    }
    for (flag, allowed) in [("edge", ["left", "right"]), ("mode", ["docked", "overlay"])] {
        if let Some(value) = flags.take(flag) {
            if !allowed.contains(&value.as_str()) {
                let [first, second] = allowed;
                return Err(UsageError::new(format!("--{flag} must be {first} or {second}")));
            }
            params.insert(flag.into(), Value::String(value));
        }
    }
    if let Some(width) = flags.take("width") {
        insert_viewport_width(&mut params, "width", "--width", width)?;
    }
    request(ResourceOperation::ColumnUpdate, selectors, flags, params)
}
