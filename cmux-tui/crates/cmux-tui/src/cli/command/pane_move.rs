//! `cmux pane <pane> move`: move a whole pane (every tab in it, in order) to
//! another place, as tmux `join-pane` / `break-pane` and herdr `pane move`
//! do. It is one `pane.move` request (W5-P): the daemon moves the pane in one
//! journaled commit, so a crash leaves it before or after the move, and a
//! retry with the same key replays the result.
//!
//! - `--to-pane <pane> --split right|down|left|up`: the pane goes beside that
//!   pane. It keeps its id.
//! - `--new-screen` (or `--new-tab`, herdr's word for a screen), or
//!   `--to-workspace <ws>`: the pane becomes the only pane of a new screen
//!   in its own workspace or in that one. It keeps its id.
//! - `--to-pane <pane>` without `--split`, or `--to-tab <tab>`: the tabs go
//!   into that pane (at its end, or after that tab, or at `--index`) and the
//!   moved pane closes.
//! - With `--to-pane` or `--to-tab`, `--to-workspace <ws>` and
//!   `--to-screen <screen>` are that selector's parents (for a name in
//!   another workspace or screen).
//!
//! The focus stays where it is, unless `--focus` or the moved pane had it.
//! The daemon resolves every selector (W5-P's one resolver), so a name, a
//! unique id prefix, a bare id and `focused` select what they select in
//! every other command.

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::{CommandPlan, Flags, Selectors, UsageError, request, validate_selector};

const USAGE: &str = "pane move takes one of --to-pane <pane> [--split right|down|left|up], \
                     --to-tab <tab>, --to-workspace <ws> or --new-screen (--new-tab), and \
                     --name <screen name>, --index <n>, --to-screen <screen> and --focus";

/// `pane <selector> move [flags]` as one `pane.move` request.
pub(super) fn parse(
    selector: &str,
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    if selector.starts_with('-') {
        return Err(UsageError::new(format!("{USAGE}, after the pane: not {selector}")));
    }
    selectors.insert("pane", "pane", selector)?;
    let to_pane = non_empty(flags, "to-pane")?;
    let to_tab = non_empty(flags, "to-tab")?;
    let to_workspace = non_empty(flags, "to-workspace")?;
    let to_screen = non_empty(flags, "to-screen")?;
    let new_screen = flags.boolean("new-screen") | flags.boolean("new-tab");
    let split = non_empty(flags, "split")?;
    let name = non_empty(flags, "name")?;
    let index = non_empty(flags, "index")?;
    let focus = flags.boolean("focus");
    // Accepted and ignored: a move keeps the focus unless `--focus`.
    let _ = flags.boolean("no-focus");
    // With --to-pane or --to-tab, --to-workspace is that selector's parent;
    // alone it makes a new screen in that workspace.
    let into_existing = to_pane.is_some() || to_tab.is_some();
    let screen_in_workspace = to_workspace.is_some() && !into_existing;
    let chosen = [to_pane.is_some(), to_tab.is_some(), screen_in_workspace, new_screen];
    if chosen.iter().filter(|chosen| **chosen).count() != 1 {
        return Err(UsageError::new(format!("{USAGE}: give exactly one destination")));
    }
    if to_screen.is_some() && !into_existing {
        return Err(UsageError::new(
            "--to-screen names the screen of --to-pane or --to-tab: it goes with one of them",
        ));
    }
    if let Some(direction) = &split
        && !matches!(direction.as_str(), "right" | "down" | "left" | "up")
    {
        return Err(UsageError::new(format!(
            "--split takes right, down, left or up, not {direction:?}"
        )));
    }
    if split.is_some() && to_pane.is_none() {
        return Err(UsageError::new("--split goes with --to-pane <pane>"));
    }
    let makes_screen = new_screen || screen_in_workspace;
    if name.is_some() && !makes_screen {
        return Err(UsageError::new(
            "--name names a new screen: it goes with --to-workspace or --new-screen",
        ));
    }
    if index.is_some() && (makes_screen || split.is_some()) {
        return Err(UsageError::new(
            "--index places the tabs in a pane: it goes with --to-pane (no --split) or --to-tab",
        ));
    }
    let mut params = Map::new();
    for (field, scope, prefix, value) in [
        ("destination_pane", "pane", "pane", &to_pane),
        ("destination_tab", "tab", "tab", &to_tab),
        ("destination_workspace", "workspace", "ws", &to_workspace),
        ("destination_screen", "screen", "screen", &to_screen),
    ] {
        if let Some(value) = value {
            validate_selector(scope, prefix, value)?;
            params.insert(field.into(), Value::String(value.clone()));
        }
    }
    if makes_screen {
        params.insert("new_screen".into(), Value::Bool(true));
    }
    if let Some(split) = split {
        params.insert("split".into(), Value::String(split));
    }
    if let Some(name) = name {
        params.insert("name".into(), Value::String(name));
    }
    if let Some(index) = index {
        let index = index
            .parse::<u32>()
            .map_err(|_| UsageError::new("--index must be a tab position (0 or more)"))?;
        params.insert("index".into(), Value::from(index));
    }
    if focus {
        params.insert("focus".into(), Value::Bool(true));
    }
    request(ResourceOperation::PaneMove, selectors, flags, params)
}

/// The value of `--flag`, refused when it is given empty.
fn non_empty(flags: &mut Flags, flag: &str) -> Result<Option<String>, UsageError> {
    match flags.take(flag) {
        Some(value) if value.is_empty() => Err(UsageError::new(format!("--{flag} needs a value"))),
        value => Ok(value),
    }
}

#[cfg(test)]
#[path = "pane_move_tests.rs"]
mod tests;
