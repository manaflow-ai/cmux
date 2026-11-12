//! `<scope> <selector> close` with a bulk flag (cx-gzh.5): `--others`,
//! `--to-right`, `--to-left` or `--all` close the selected object's siblings
//! at that level (the pane's tabs, the screen's panes, the workspace's
//! screens, the session's workspaces) in one `layout.bulk` call: one closed
//! group, which `cmux closed reopen` restores whole. Pinned tabs and screens
//! stay unless `--include-pinned`. Without a bulk flag, the plain close.
//!
//! Either close follows one model for the terminals it leaves with no tab
//! (W7-C): with a reaper they stay until its grace (30 s) ends them, and
//! `closed reopen` in that window shows them again; with no reaper they end
//! at once. A kept one and one with an attached viewer stay running, and the
//! caller's own is never ended at once. `--now` (or `--end-terminals`) ends
//! them at once; `--keep-terminals` keeps them and marks them `keep` (the
//! reaper leaves them). Both closes name
//! the ended, ending and still-running ones.

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
    let keep_terminals = flags.boolean("keep-terminals");
    // `--end-terminals` (the bulk close's older flag) is `--now`.
    let now = flags.boolean("now") | flags.boolean("end-terminals");
    if now && keep_terminals {
        return Err(UsageError::new("use one of --now and --keep-terminals"));
    }
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
        let terminals = match (now, keep_terminals) {
            (true, _) => "end",
            (false, true) => "keep",
            (false, false) => "grace",
        };
        params.insert("terminals".into(), Value::String(terminals.into()));
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
    // Without either flag the daemon's default: the grace, as a plain close.
    if now {
        params.insert("end_terminals".into(), Value::Bool(true));
    }
    if keep_terminals {
        params.insert("keep_terminals".into(), Value::Bool(true));
    }
    request(ResourceOperation::LayoutBulk, selectors, flags, params)
}
