//! `cmux agent open SESSION [--name NAME] [--key UUID] [--cwd DIR] [--host HOST] [--group GROUP]
//! [--placement top]`:
//! an existing acpmux session (one `cmux acp ensure` made) in a new workspace
//! of the app, the app action with the CLI name `agent open`
//! (`agent.openSessionWorkspace`). Scripts and coordinators make a session
//! they started from the CLI appear in the app this way.
//! `cmux agent open-tab SESSION [--target PANE_OR_TAB] [--host HOST] [--focus]`
//! opens it as a tab of a pane instead (`agent.openSessionTab`).

use super::{ActionName, AppCommand, run_action};
use crate::cli::UsageError;

/// The `agent open` and `agent open-tab` commands, `None` for any other words.
pub(super) fn parse(args: &[String]) -> Result<Option<AppCommand>, UsageError> {
    if args.first().is_none_or(|scope| scope != "agent") {
        return Ok(None);
    }
    let messages = &crate::localization::catalog().app_control;
    let (action, usage) = match args.get(1).map(String::as_str) {
        Some("open") => ("agent open", messages.agent_open_usage),
        Some("open-tab") => ("agent open-tab", messages.agent_open_tab_usage),
        _ => return Ok(None),
    };
    let Some((session, tail)) = args[2..].split_first().filter(|(id, _)| !id.starts_with('-'))
    else {
        return Err(UsageError::new(usage));
    };
    let args = ["--session".to_owned(), session.clone()].into_iter().chain(tail.iter().cloned());
    run_action(action, &args.collect::<Vec<_>>(), ActionName::Cli).map(Some)
}
