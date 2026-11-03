//! `cmux space …`: the noun-first space verbs. Reads stay with the daemon's
//! room resource (`space list`, command.rs); mutations are app actions, so the
//! same action registry powers the CLI and MCP.

use super::{ActionName, AppCommand, run_action};
use crate::cli::UsageError;

/// The positional forms (`space rename <old> <new>`, …) as their catalog
/// action. Only the leading words that are not options are positional, as the
/// generic `<noun> <verb>` route reads them: `space rename --name Office`
/// names no space and keeps renaming the current one through that route.
/// Options after the positional words reach the action unchanged. `Ok(None)`
/// for anything else (`space list`, `space new-window`, flag forms).
pub(super) fn parse(rest: &[String]) -> Result<Option<AppCommand>, UsageError> {
    let positional = rest.iter().take_while(|word| !word.starts_with('-')).count();
    let (words, options) = rest.split_at(positional);
    let words = words.iter().map(String::as_str).collect::<Vec<_>>();
    let room = |name: &str| format!("room:{name}");
    let (action, mut args, route) = match words.as_slice() {
        ["new", name] => ("space.new", vec!["--name".into(), (*name).into()], ActionName::Any),
        ["switch", name] => ("space switch", vec!["--target".into(), room(name)], ActionName::Cli),
        ["rename", old, new] => (
            "space rename",
            vec!["--target".into(), room(old), "--name".into(), (*new).into()],
            ActionName::Cli,
        ),
        ["close", name] => (
            "space delete",
            vec!["--target".into(), room(name), "--confirm".into()],
            ActionName::Cli,
        ),
        ["move", kind, target, space] => {
            let action = match *kind {
                "workspace" => "workspace move-to-space",
                "tab" => "tab move-to-space",
                _ => return Err(UsageError::new("space move takes workspace or tab")),
            };
            let args = vec![
                "--target".into(),
                format!("{kind}:{target}"),
                "--space".into(),
                (*space).into(),
            ];
            (action, args, ActionName::Cli)
        }
        _ => return Ok(None),
    };
    args.extend(options.iter().cloned());
    run_action(action, &args, route).map(Some)
}
