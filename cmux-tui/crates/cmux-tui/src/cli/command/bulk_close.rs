//! `<scope> <selector> close` with a bulk flag (cx-gzh.5): `--others`,
//! `--to-right`, `--to-left` or `--all` close the selected object's siblings
//! at that level (the pane's tabs, the screen's panes, the workspace's
//! screens, the session's workspaces) in one `layout.bulk` call: one closed
//! group, which `cmux closed reopen` restores whole. Pinned tabs and screens
//! stay unless `--include-pinned`. Without a bulk flag, the plain close.

use super::*;

/// The bulk flags and the `layout.bulk` selector each one sends.
const BULK_FLAGS: &[(&str, &str)] =
    &[("others", "others"), ("to-right", "to_right"), ("to-left", "to_left"), ("all", "all")];

/// `<level> <selector> close [FLAGS]` (`level`: tab, pane, screen or workspace).
pub(super) fn close(
    level: &'static str,
    selector: &str,
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let (prefix, plain) = match level {
        "tab" => ("tab", ResourceOperation::TabClose),
        "pane" => ("pane", ResourceOperation::PaneClose),
        "screen" => ("screen", ResourceOperation::ScreenClose),
        _ => ("ws", ResourceOperation::WorkspaceClose),
    };
    selectors.insert(level, prefix, selector)?;
    let chosen = BULK_FLAGS
        .iter()
        .filter(|(flag, _)| flags.boolean(flag))
        .map(|(_, selector)| *selector)
        .collect::<Vec<_>>();
    let include_pinned = flags.boolean("include-pinned");
    let Some(&bulk) = chosen.first() else {
        if include_pinned {
            return Err(UsageError::new(
                "--include-pinned needs --others, --to-right, --to-left or --all",
            ));
        }
        let mut params = Map::new();
        // A workspace close names the closed groups it stored when asked.
        if level == "workspace" && flags.boolean("report-closed-ids") {
            params.insert("report_closed_ids".into(), Value::Bool(true));
        }
        return request(plain, selectors, flags, params);
    };
    if chosen.len() > 1 {
        return Err(UsageError::new("use one of --others, --to-right, --to-left and --all"));
    }
    if level == "pane" && matches!(bulk, "to_right" | "to_left") {
        return Err(UsageError::new("panes have no order; use --others or --all"));
    }
    let mut params = Map::new();
    params.insert("verb".into(), Value::String("close".into()));
    params.insert("level".into(), Value::String(level.into()));
    params.insert("selector".into(), Value::String(bulk.into()));
    if include_pinned {
        params.insert("include_pinned".into(), Value::Bool(true));
    }
    if flags.boolean("end-terminals") {
        params.insert("end_terminals".into(), Value::Bool(true));
    }
    request(ResourceOperation::LayoutBulk, selectors, flags, params)
}
