//! `cmux workspace group create --remote HOST [--name N]` and `cmux workspace
//! group create --parent GROUP --name N`: groups that live on the sidebar
//! document, so the app makes them (plans/cmux-next/remote-groups-DESIGN.md).
//! `--remote` runs New Remote Group (`remote.newGroup`): it connects HOST and
//! makes its machine a remote group, whose new workspaces run on HOST.
//! `--parent` runs New Subgroup (`workspaceGroup.newSubgroup`) inside GROUP.
//! A plain `workspace group create` stays the daemon's `workspace_group.create`.

use super::{ActionName, AppCommand, UsageError, run_action};

const REMOTE_USAGE: &str = "usage: cmux workspace group create --remote <host> [--name <value>]";
const PARENT_USAGE: &str = "usage: cmux workspace group create --parent <group> --name <value>";
const BOTH: &str = "cmux: --remote and --parent do not go together: a remote group is a machine's top-level group; make it, then add subgroups with --parent";

/// The app command for `args`, or `Ok(None)` when they are not a
/// `workspace group create` with `--remote` or `--parent`.
pub(super) fn parse(args: &[String]) -> Result<Option<AppCommand>, UsageError> {
    let words: Vec<&str> = args.iter().take(3).map(String::as_str).collect();
    if words != ["workspace", "group", "create"] {
        return Ok(None);
    }
    let rest = args.get(3..).unwrap_or_default();
    let mut remote = None;
    let mut parent = None;
    let mut name = None;
    let mut other = None;
    let mut index = 0;
    while let Some(arg) = rest.get(index) {
        let arg = arg.as_str();
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg, None),
        };
        let slot = match flag {
            "--remote" => &mut remote,
            "--parent" => &mut parent,
            "--name" => &mut name,
            _ => {
                other.get_or_insert_with(|| arg.to_owned());
                index += 1;
                continue;
            }
        };
        let value = match inline {
            Some(value) => Some(value),
            None => {
                let next = rest.get(index + 1).filter(|value| !value.starts_with("--")).cloned();
                if next.is_some() {
                    index += 1;
                }
                next
            }
        };
        *slot = Some(value.filter(|value| !value.is_empty()));
        index += 1;
    }
    match (remote, parent) {
        (None, None) => Ok(None),
        (Some(_), Some(_)) => Err(UsageError::new(BOTH)),
        (Some(host), None) => {
            let (Some(host), None) = (host, &other) else {
                return Err(UsageError::new(REMOTE_USAGE));
            };
            let mut action = vec!["--destination".to_owned(), host];
            match name {
                Some(Some(name)) => action.extend(["--name".to_owned(), name]),
                Some(None) => return Err(UsageError::new(REMOTE_USAGE)),
                None => {}
            }
            run_action("remote.newGroup", &action, ActionName::Any).map(Some)
        }
        (None, Some(group)) => {
            let (Some(group), Some(Some(name)), None) = (group, name, &other) else {
                return Err(UsageError::new(PARENT_USAGE));
            };
            let action = ["--group".to_owned(), group, "--name".to_owned(), name];
            run_action("workspaceGroup.newSubgroup", &action, ActionName::Any).map(Some)
        }
    }
}
