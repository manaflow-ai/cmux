//! `cmux agent open SESSION [--name NAME] [--key UUID] [--cwd DIR] [--host HOST] [--group GROUP]`:
//! an existing acpmux session (one `cmux acp ensure` made) in a new workspace
//! of the app, the app action with the CLI name `agent open`
//! (`agent.openSessionWorkspace`). Scripts and coordinators make a session
//! they started from the CLI appear in the app this way.

use super::{ActionName, AppCommand, run_action};
use crate::cli::UsageError;

/// The `agent open` command, `None` for any other words.
pub(super) fn parse(args: &[String]) -> Result<Option<AppCommand>, UsageError> {
    if args.first().is_none_or(|scope| scope != "agent")
        || args.get(1).is_none_or(|verb| verb != "open")
    {
        return Ok(None);
    }
    let usage = crate::localization::catalog().app_control.agent_open_usage;
    let Some((session, tail)) = args[2..].split_first().filter(|(id, _)| !id.starts_with('-'))
    else {
        return Err(UsageError::new(usage));
    };
    let args = ["--session".to_owned(), session.clone()].into_iter().chain(tail.iter().cloned());
    run_action("agent open", &args.collect::<Vec<_>>(), ActionName::Cli).map(Some)
}
