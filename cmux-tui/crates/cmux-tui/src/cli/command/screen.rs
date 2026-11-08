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
            add_optional_parent_selectors(selectors, flags, &["workspace"])?;
            let mut params = Map::new();
            insert_optional_string(&mut params, flags, "name", "name");
            // A new screen keeps the focus where it is (socket focus policy)
            // unless `--focus` asks; `--no-focus` is the default.
            let _ = flags.boolean("no-focus");
            if flags.boolean("focus") {
                params.insert("focus".into(), Value::Bool(true));
            }
            insert_creation_command(&mut params, argv, flags)?;
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
        [selector, "close"] => bulk_close::close("screen", selector, selectors, flags),
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
/// `column.update` (pin, unpin, or resize one viewport column; make a docked
/// column the pinned dock and choose whether it takes more tabs).
fn column_update(
    column: &str,
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    validate_prefixed_id("column", "split", column)?;
    let mut params = map_with("column", Value::String(column.to_string()));
    // pinned-dock-v1: --pinned true makes a docked column the pinned (Home)
    // dock, one way; --allow-tabs lets a pinned column take more tabs.
    for (flag, field) in [("dock", "dock"), ("pinned", "pinned"), ("allow-tabs", "allow_tabs")] {
        if let Some(value) = flags.take(flag) {
            params.insert(field.into(), Value::Bool(parse_bool(&format!("--{flag}"), &value)?));
        }
    }
    let choices: [(&str, &[&str], &str); 2] = [
        ("edge", &["left", "right", "top", "bottom"], "left, right, top, or bottom"),
        ("mode", &["docked", "overlay"], "docked or overlay"),
    ];
    for (flag, allowed, listed) in choices {
        if let Some(value) = flags.take(flag) {
            if !allowed.contains(&value.as_str()) {
                return Err(UsageError::new(format!("--{flag} must be {listed}")));
            }
            params.insert(flag.into(), Value::String(value));
        }
    }
    if let Some(width) = flags.take("width") {
        insert_viewport_width(&mut params, "width", "--width", width)?;
    }
    request(ResourceOperation::ColumnUpdate, selectors, flags, params)
}

#[cfg(test)]
mod tests {
    use super::super::{CommandPlan, parse as parse_command};

    fn params(args: &[&str]) -> serde_json::Value {
        let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
        match parse_command(&args, crate::cli::Surface::CmuxTui) {
            Ok(CommandPlan::Protocol(plan)) => plan.params,
            _ => panic!("{args:?} is not a protocol request"),
        }
    }

    /// `screen create` keeps the focus unless `--focus` (bench round 3,
    /// T8); `--workspace` places the screen in another workspace.
    #[test]
    fn w4j_screen_create_sends_focus_only_when_asked_and_takes_a_workspace() {
        let plain = params(&["screen", "create", "--name", "build"]);
        assert!(plain.get("focus").is_none(), "{plain}");
        let quiet = params(&["screen", "create", "--no-focus"]);
        assert!(quiet.get("focus").is_none(), "{quiet}");
        let focused = params(&["screen", "create", "--focus"]);
        assert_eq!(focused["focus"], true);
        let workspace = "ws_00000000000000000000000000000004";
        let placed = params(&["screen", "create", "--workspace", workspace]);
        assert_eq!(placed["workspace"], workspace);
    }
}
